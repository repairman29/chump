#!/usr/bin/env bash
# css-token-discipline.sh — INFRA-1590
#
# Design-token discipline lint for PWA web/ files.
# Mirrors the Rust-First-Bypass pattern (pre-commit-rust-first.sh, META-064).
#
# Rules enforced on staged .html / .js / .css files:
#   Rule 1: Raw hex (#rrggbb) or rgb()/rgba()/hsl() literals OUTSIDE :root or
#            [data-theme] blocks must be inside a var(--token, fallback) call.
#   Rule 2: New CSS variable DEFINITIONS ending in -primary or -secondary are
#            rejected (canonical aliases: see docs/process/CSS_TOKEN_DISCIPLINE.md).
#   Rule 3: var(--token, FALLBACK) where FALLBACK does not match the :root value.
#   Rule 4: A hex literal appearing in >3 web/ files is drift — add it to :root.
#
# Bypass: add 'Token-Discipline-Bypass: <reason>' trailer to the commit body.
#         Bypass is logged to ambient.jsonl (kind=token_discipline_bypass).
#
# Override: CHUMP_TOKEN_DISCIPLINE_CHECK=0  — disables the gate entirely.
# Test mode: CHUMP_TOKEN_DISCIPLINE_FILES="file1\nfile2" — scans those files
#            instead of git diff --cached (newline-separated, REPO_ROOT-relative
#            or absolute paths).

set -uo pipefail

[[ "${CHUMP_TOKEN_DISCIPLINE_CHECK:-1}" == "0" ]] && exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BASELINE="${REPO_ROOT}/.css-discipline-baseline.txt"
AMBIENT="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
INDEX_HTML="${REPO_ROOT}/web/v2/index.html"

# ------------------------------------------------------------------
# File selection: git staged OR test-mode override
# ------------------------------------------------------------------
if [[ -n "${CHUMP_TOKEN_DISCIPLINE_FILES:-}" ]]; then
    # Test mode: files passed directly (newline-separated)
    STAGED="$(printf '%s' "${CHUMP_TOKEN_DISCIPLINE_FILES}" \
        | tr ',' '\n' \
        | grep -E '\.(html|js|css)$' || true)"
else
    STAGED="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
        | grep -E '\.(html|js|css)$' \
        | grep -E '^web/' || true)"
fi

[[ -z "$STAGED" ]] && exit 0

# ------------------------------------------------------------------
# Baseline: suppress known existing violations at install time.
# Format: one pattern per line; '#' lines are comments.
# Matching: violation context is checked for substring containment.
# ------------------------------------------------------------------
_baseline_patterns=()
if [[ -f "$BASELINE" ]]; then
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        _baseline_patterns+=("$line")
    done < "$BASELINE"
fi

_is_baseline() {
    local ctx="$1"
    for pat in "${_baseline_patterns[@]:-}"; do
        [[ -z "$pat" ]] && continue
        [[ "$ctx" == *"$pat"* ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------------
# Parse :root token values from index.html (first :root block only)
# ------------------------------------------------------------------
declare -A ROOT_TOKENS
if [[ -f "$INDEX_HTML" ]]; then
    in_root=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s*:root\s*\{'; then
            in_root=1; continue
        fi
        if [[ $in_root -eq 1 ]] && echo "$line" | grep -qE '^\s*\}'; then
            in_root=0; continue
        fi
        if [[ $in_root -eq 1 ]]; then
            if [[ "$line" =~ --([a-zA-Z][a-zA-Z0-9-]*)[[:space:]]*:[[:space:]]*([^;]+) ]]; then
                tok="${BASH_REMATCH[1]}"
                val="$(echo "${BASH_REMATCH[2]}" | sed 's/[[:space:]]*$//')"
                ROOT_TOKENS["$tok"]="$val"
            fi
        fi
    done < "$INDEX_HTML"
fi

VIOLATIONS=()

# ------------------------------------------------------------------
# Rule 2: new --*-primary or --*-secondary variable DEFINITIONS
# Canonical exempt: --text-secondary (defined in :root)
# ------------------------------------------------------------------
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    abs_f="${REPO_ROOT}/${f}"
    # Allow absolute paths passed directly in test mode
    [[ "${f}" == /* ]] && abs_f="${f}" && f="${f#${REPO_ROOT}/}"
    [[ ! -f "$abs_f" ]] && continue
    while IFS= read -r line; do
        echo "$line" | grep -qE '\-\-[a-zA-Z][a-zA-Z0-9-]*-primary[[:space:]]*:|\-\-[a-zA-Z][a-zA-Z0-9-]*-secondary[[:space:]]*:' || continue
        # Exempt canonical --text-secondary in :root
        echo "$line" | grep -qE '^[[:space:]]*\-\-text-secondary[[:space:]]*:' && continue
        ctx="${f}:${line}"
        _is_baseline "$ctx" && continue
        VIOLATIONS+=("${f}: defines banned alias variable: $(echo "$line" | sed 's/^[[:space:]]*//' | cut -c1-80)")
    done < "$abs_f"
done <<< "$STAGED"

# ------------------------------------------------------------------
# Rule 3: var(--token, FALLBACK) fallback mismatch with :root
# Only checked for tokens known in :root.
# ------------------------------------------------------------------
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    abs_f="${REPO_ROOT}/${f}"
    [[ "${f}" == /* ]] && abs_f="${f}" && f="${f#${REPO_ROOT}/}"
    [[ ! -f "$abs_f" ]] && continue
    while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        # Extract token name and fallback from var(--name, fallback)
        tok="$(echo "$match" | sed -E 's/var\(--([a-zA-Z][a-zA-Z0-9-]*).*/\1/')"
        fallback="$(echo "$match" | sed -E 's/var\(--[a-zA-Z][a-zA-Z0-9-]*,[[:space:]]*//' | sed 's/)[[:space:]]*.*//' | sed 's/[[:space:]]*$//')"
        [[ -z "${ROOT_TOKENS[$tok]+x}" ]] && continue
        root_val="${ROOT_TOKENS[$tok]}"
        # Normalize: strip trailing whitespace
        fallback_norm="$(echo "$fallback" | tr -d ' ')"
        root_norm="$(echo "$root_val" | tr -d ' ')"
        [[ "$fallback_norm" == "$root_norm" ]] && continue
        ctx="${f}:${match}"
        _is_baseline "$ctx" && continue
        VIOLATIONS+=("${f}: var(--${tok}, ${fallback}) fallback mismatch — :root declares '${root_val}'")
    done < <(grep -oE 'var\(--[a-zA-Z][a-zA-Z0-9-]*,[^)]+\)' "$abs_f" 2>/dev/null || true)
done <<< "$STAGED"

# ------------------------------------------------------------------
# Rule 1: raw hex outside :root / [data-theme] / var() context
# Strategy per file type:
#   .html / .css  — track :root/data-theme blocks line by line
#   .js           — strip var(--x, #hex) occurrences, then check remaining hex
# ------------------------------------------------------------------
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    abs_f="${REPO_ROOT}/${f}"
    [[ "${f}" == /* ]] && abs_f="${f}" && f="${f#${REPO_ROOT}/}"
    [[ ! -f "$abs_f" ]] && continue

    in_root_block=0
    lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # Skip comment lines
        echo "$line" | grep -qE '^\s*(//)' && continue

        # Track :root and [data-theme] block entry/exit in HTML/CSS
        if echo "$line" | grep -qE ':root\s*\{|\[data-theme'; then
            in_root_block=1
        fi
        if [[ $in_root_block -eq 1 ]] && echo "$line" | grep -qE '^\s*\}'; then
            in_root_block=0
            continue
        fi
        [[ $in_root_block -eq 1 ]] && continue

        # Strip var(--x, value) occurrences (rule 3 handles those)
        cleaned="$(echo "$line" | sed -E 's/var\(--[a-zA-Z][a-zA-Z0-9-]*,[^)]*\)/__VAR__/g')"

        # Look for raw hex color literals remaining after stripping var()
        if echo "$cleaned" | grep -qE '#[0-9a-fA-F]{3}([0-9a-fA-F]{3}([0-9a-fA-F]{2})?)?\b'; then
            raw_hex="$(echo "$cleaned" | grep -oE '#[0-9a-fA-F]{3}([0-9a-fA-F]{3}([0-9a-fA-F]{2})?)?\b' | head -1)"
            ctx="${f}:${raw_hex}"
            _is_baseline "$ctx" && continue
            _is_baseline "${f}:" && continue
            VIOLATIONS+=("${f}:${lineno}: raw hex '${raw_hex}' outside :root/var() — use var(--token) from canonical list")
        fi
        # Also detect rgb()/rgba()/hsl() outside var() context
        if echo "$cleaned" | grep -qE 'rgba?\s*\(|hsl\s*\('; then
            ctx="${f}:rgba/hsl"
            _is_baseline "${f}:" && continue
            raw_col="$(echo "$cleaned" | grep -oE '(rgba?|hsl)\s*\([^)]+\)' | head -1)"
            VIOLATIONS+=("${f}:${lineno}: raw color function '${raw_col}' outside :root/var() — use var(--token)")
        fi
    done < "$abs_f"
done <<< "$STAGED"

# ------------------------------------------------------------------
# Rule 4: color literal drift — hex in >3 web/ files
# ------------------------------------------------------------------
declare -A _drift_checked
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    abs_f="${REPO_ROOT}/${f}"
    [[ "${f}" == /* ]] && abs_f="${f}" && f="${f#${REPO_ROOT}/}"
    [[ ! -f "$abs_f" ]] && continue
    while IFS= read -r raw_hex; do
        [[ -z "$raw_hex" ]] && continue
        lc_hex="${raw_hex,,}"
        [[ -n "${_drift_checked[$lc_hex]+x}" ]] && continue
        _drift_checked["$lc_hex"]=1
        _is_baseline "drift:${lc_hex}" && continue
        _is_baseline "drift:${raw_hex}" && continue
        count="$(grep -rlE "${raw_hex}" "${REPO_ROOT}/web/" 2>/dev/null \
            | grep -vE '\.min\.|node_modules|__pycache__' | wc -l | tr -d ' ')"
        if [[ "${count:-0}" -gt 3 ]]; then
            VIOLATIONS+=("drift: '${raw_hex}' in ${count} web/ files — consider promoting to :root token (Rule 4)")
        fi
    done < <(grep -oE '#[0-9a-fA-F]{3}([0-9a-fA-F]{3}([0-9a-fA-F]{2})?)?\b' "$abs_f" 2>/dev/null || true)
done <<< "$STAGED"

# ------------------------------------------------------------------
# All clean?
# ------------------------------------------------------------------
if (( ${#VIOLATIONS[@]} == 0 )); then
    exit 0
fi

# ------------------------------------------------------------------
# Check for bypass trailer
# ------------------------------------------------------------------
MSG_FILE="$(git rev-parse --git-common-dir 2>/dev/null)/COMMIT_EDITMSG"
if [[ -f "$MSG_FILE" ]] && grep -qE '^Token-Discipline-Bypass:' "$MSG_FILE" 2>/dev/null; then
    reason="$(grep -E '^Token-Discipline-Bypass:' "$MSG_FILE" | head -1 \
        | sed 's/^Token-Discipline-Bypass:[[:space:]]*//')"
    files_csv="$(echo "$STAGED" | tr '\n' ',' | sed 's/,$//')"
    sha="$(git rev-parse --verify HEAD 2>/dev/null || echo 'pre-commit')"
    if [[ -d "$(dirname "$AMBIENT")" ]]; then
        printf '{"ts":"%s","kind":"token_discipline_bypass","commit_sha":"%s","reason":%s,"files":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$sha" \
            "$(printf '%s' "$reason" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo '"(unparseable)"')" \
            "$files_csv" \
            >> "$AMBIENT" 2>/dev/null || true
    fi
    exit 0
fi

# ------------------------------------------------------------------
# Block: print violations
# ------------------------------------------------------------------
red='\033[0;31m'; nc='\033[0m'
printf '\n' >&2
printf "${red}❌ INFRA-1590 CSS token-discipline gate blocked this commit.${nc}\n" >&2
printf '\n' >&2
for v in "${VIOLATIONS[@]}"; do
    printf '  • %s\n' "$v" >&2
done
printf '\n' >&2
printf 'Canonical token list:  web/v2/index.html :root {} block\n' >&2
printf 'Full rules + bypass:   docs/process/CSS_TOKEN_DISCIPLINE.md\n' >&2
printf 'Bypass this commit:    add Token-Discipline-Bypass: <reason> to commit body\n' >&2
printf 'Disable gate:          CHUMP_TOKEN_DISCIPLINE_CHECK=0 git commit ...\n' >&2
exit 1
