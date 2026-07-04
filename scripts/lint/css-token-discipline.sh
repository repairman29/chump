#!/usr/bin/env bash
# scripts/lint/css-token-discipline.sh — INFRA-1590
#
# CSS design-token discipline gate. Scans staged web/**/*.{js,html,css} files
# and rejects token violations before they reach main.
#
# Rules enforced:
#  1. Raw hex/rgb/hsl color literals in CSS property values (not token defs)
#  2. Non-canonical CSS variable definitions (--*-primary or --*-secondary
#     except --text-secondary which is the sole canonical *-secondary token)
#  3. var(--token, FALLBACK) where FALLBACK doesn't match the :root value
#  4. A non-canonical hex color literal appearing in >3 web files (drift)
#
# Canonical tokens: --text, --text-secondary, --bg, --bg-surface, --bg-elevated,
#   --accent, --accent-dim, --success, --warn, --error, --border,
#   --radius, --radius-sm
# See docs/process/CSS_TOKEN_DISCIPLINE.md for the full token reference.
#
# Bypass: 'Token-Discipline-Bypass: <reason>' in the commit message body.
#   Emits kind=token_discipline_bypass to ambient.jsonl for audit.
# Env bypass (rare): CHUMP_CSS_TOKEN_CHECK=0
# Baseline exemptions: .css-discipline-baseline.txt (one file path per line)

set -uo pipefail

if [[ "${CHUMP_CSS_TOKEN_CHECK:-1}" == "0" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BASELINE_FILE="$REPO_ROOT/.css-discipline-baseline.txt"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

# Helper: check if a file path appears in the baseline (grep-based, no assoc arrays)
_is_baselined() {
    local f="$1"
    [[ -f "$BASELINE_FILE" ]] || return 1
    grep -qxF "$f" "$BASELINE_FILE" 2>/dev/null
}

# Helper: look up a token's :root value from index.html
# Returns empty string if token not found. Reads only the first :root block.
_root_token_value() {
    local tok="$1"
    [[ -f "$INDEX_HTML" ]] || return 0
    awk -v tok="$tok" '
        /^\s*:root\s*\{/ { in_root=1; next }
        in_root && /^\s*\}/ { exit }
        in_root {
            # Match --token-name: value;
            if (match($0, /^\s*--([a-zA-Z-]+)\s*:\s*/, arr)) {
                name = arr[1]
                if (name == tok) {
                    # Extract value (everything after the colon, before semicolon)
                    sub(/^\s*--[a-zA-Z-]+\s*:\s*/, "")
                    sub(/\s*;.*/, "")
                    # Normalize: lowercase, no spaces
                    gsub(/ /, "")
                    print tolower($0)
                    exit
                }
            }
        }
    ' "$INDEX_HTML"
}

# Find staged web files (html, js, css)
STAGED_WEB="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
    | grep -E '^web/.*\.(js|html|css)$' || true)"

if [[ -z "$STAGED_WEB" ]]; then
    exit 0
fi

# Filter out baselined files
CHECK_FILES=()
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! _is_baselined "$f"; then
        CHECK_FILES+=("$f")
    fi
done <<< "$STAGED_WEB"

if (( ${#CHECK_FILES[@]} == 0 )); then
    exit 0
fi

VIOLATIONS=()

# ── Rule 1: Raw hex/rgb/hsl in CSS property values ───────────────────────────
# Flags lines with a CSS color property using a bare color literal (not var()).
# Token definition lines (--name: ...) are allowed.
for f in "${CHECK_FILES[@]}"; do
    abs="$REPO_ROOT/$f"
    [[ -f "$abs" ]] || continue
    lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # Allow CSS variable definition lines (--token-name: ...)
        if echo "$line" | grep -qE '^\s*--[a-zA-Z-]+\s*:'; then
            continue
        fi
        # Skip lines where the property value uses var()
        if echo "$line" | grep -qE '(color|background)[^:]*:\s*var\('; then
            continue
        fi
        if echo "$line" | grep -qE '(border|outline|fill|stroke)[^:]*:\s*[^;]*var\('; then
            continue
        fi
        # Flag raw color literal in a CSS property value
        if echo "$line" | grep -qE '(color|background(-color)?|border(-color)?|fill|stroke|outline(-color)?)\s*:\s*(#[0-9a-fA-F]{3,8}|rgb[a]?\(|hsl[a]?\()'; then
            literal="$(echo "$line" | grep -oE '#[0-9a-fA-F]{3,8}|rgb[a]?\([^)]+\)|hsl[a]?\([^)]+\)' | head -1)"
            VIOLATIONS+=("$f:$lineno: Rule-1 raw color '${literal:-?}' in CSS property — use var(--token) instead")
        fi
    done < "$abs"
done

# ── Rule 2: Non-canonical --*-primary or --*-secondary DEFINITIONS ─────────
# Flags variable definitions ending in -primary (none canonical) or
# -secondary (only --text-secondary is canonical).
for f in "${CHECK_FILES[@]}"; do
    abs="$REPO_ROOT/$f"
    [[ -f "$abs" ]] || continue
    lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        if echo "$line" | grep -qE '^\s*--[a-zA-Z]+-primary\s*:'; then
            varname="$(echo "$line" | grep -oE '--[a-zA-Z]+-primary' | head -1)"
            VIOLATIONS+=("$f:$lineno: Rule-2 non-canonical '$varname' — no --*-primary tokens are canonical; use --accent, --bg, --text, etc.")
        elif echo "$line" | grep -qE '^\s*--[a-zA-Z]+-secondary\s*:'; then
            if ! echo "$line" | grep -qE '^\s*--text-secondary\s*:'; then
                varname="$(echo "$line" | grep -oE '--[a-zA-Z]+-secondary' | head -1)"
                VIOLATIONS+=("$f:$lineno: Rule-2 non-canonical '$varname' — only --text-secondary is canonical; use --bg-surface or --bg-elevated instead")
            fi
        fi
    done < "$abs"
done

# ── Rule 3: var(--token, FALLBACK) where FALLBACK ≠ :root value ─────────────
# Only checks tokens that are defined in the :root block of index.html.
if [[ -f "$INDEX_HTML" ]]; then
    for f in "${CHECK_FILES[@]}"; do
        abs="$REPO_ROOT/$f"
        [[ -f "$abs" ]] || continue
        lineno=0
        while IFS= read -r line; do
            lineno=$((lineno + 1))
            # Find var(--token, #hex) or var(--token, rgb...) patterns
            if ! echo "$line" | grep -qE 'var\(--[a-zA-Z-]+,\s*(#[0-9a-fA-F]{3,8}|rgb[a]?\(|hsl[a]?\()'; then
                continue
            fi
            # Extract each var(--token, fallback) on this line
            while IFS= read -r vmatch; do
                [[ -z "$vmatch" ]] && continue
                tok="$(echo "$vmatch" | sed 's/var(--//; s/,.*//')"
                fallback="$(echo "$vmatch" | sed 's/var(--[a-zA-Z-]*,\s*//; s/).*//' \
                    | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
                root_val="$(_root_token_value "$tok")"
                if [[ -n "$root_val" && "$fallback" != "$root_val" ]]; then
                    VIOLATIONS+=("$f:$lineno: Rule-3 var(--$tok, $fallback) fallback mismatches :root '$root_val' — fix or remove fallback")
                fi
            done < <(echo "$line" | grep -oE 'var\(--[a-zA-Z-]+,[^)]+\)' || true)
        done < "$abs"
    done
fi

# ── Rule 4: Non-canonical hex appearing in >3 web files (drift detector) ────
# Skip hex values that match canonical :root token values.
if [[ -f "$INDEX_HTML" ]]; then
    for f in "${CHECK_FILES[@]}"; do
        abs="$REPO_ROOT/$f"
        [[ -f "$abs" ]] || continue
        # Extract unique 6-digit hex values from this staged file
        while IFS= read -r hex; do
            [[ -z "$hex" ]] && continue
            hex_lc="$(echo "$hex" | tr '[:upper:]' '[:lower:]')"
            # Check if this hex is a canonical :root value
            if grep -qE ":\s*${hex}[^0-9a-fA-F]" "$INDEX_HTML" 2>/dev/null; then
                continue
            fi
            # Count how many web files contain this hex
            file_count=0
            while IFS= read -r webf; do
                grep -qiF "$hex" "$webf" 2>/dev/null && file_count=$((file_count + 1))
            done < <(find "$REPO_ROOT/web" \( -name "*.js" -o -name "*.html" -o -name "*.css" \) 2>/dev/null)
            if (( file_count > 3 )); then
                VIOLATIONS+=("$f: Rule-4 drift: non-canonical hex '$hex_lc' in $file_count web files — use var(--token) instead of spreading a hardcode")
                break
            fi
        done < <(grep -oiE '#[0-9a-fA-F]{6}\b' "$abs" 2>/dev/null | sort -u || true)
    done
fi

# ── Exit early if no violations ──────────────────────────────────────────────
if (( ${#VIOLATIONS[@]} == 0 )); then
    exit 0
fi

# ── Check for bypass trailer ─────────────────────────────────────────────────
# INFRA-1309: use --git-common-dir so bypass works in linked worktrees.
MSG_FILE="$(git rev-parse --git-common-dir 2>/dev/null)/COMMIT_EDITMSG"
HAS_BYPASS=0
if [[ -f "$MSG_FILE" ]] && grep -qE '^Token-Discipline-Bypass:' "$MSG_FILE" 2>/dev/null; then
    HAS_BYPASS=1
fi

if [[ "$HAS_BYPASS" == "1" ]]; then
    reason="$(grep -E '^Token-Discipline-Bypass:' "$MSG_FILE" | head -1 \
        | sed 's/^Token-Discipline-Bypass:[[:space:]]*//')"
    staged_csv="$(IFS=,; echo "${CHECK_FILES[*]}")"
    commit_sha="$(git rev-parse --short HEAD 2>/dev/null || echo 'pre-commit')"

    if [[ -d "$(dirname "$AMBIENT")" ]]; then
        printf '{"ts":"%s","kind":"token_discipline_bypass","commit_sha":"%s","reason":%s,"files":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$commit_sha" \
            "$(printf '%s' "$reason" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo '"unparseable"')" \
            "$staged_csv" \
            >> "$AMBIENT" 2>/dev/null || true
    fi
    exit 0
fi

# ── Block commit ─────────────────────────────────────────────────────────────
printf '\033[0;31m\n❌ CSS token discipline gate (INFRA-1590) blocked this commit.\033[0m\n\n' >&2
echo "Design token violations in staged web files:" >&2
for v in "${VIOLATIONS[@]}"; do
    echo "  - $v" >&2
done
echo "" >&2
echo "Fix: use canonical CSS tokens via var(--token). Canonical token list:" >&2
echo "  --text  --text-secondary  --bg  --bg-surface  --bg-elevated" >&2
echo "  --accent  --accent-dim  --success  --warn  --error  --border" >&2
echo "  --radius  --radius-sm" >&2
echo "" >&2
echo "Bypass (with reason): add this trailer to the commit message body:" >&2
echo "  Token-Discipline-Bypass: <one-sentence reason>" >&2
echo "" >&2
echo "Disable (rare): CHUMP_CSS_TOKEN_CHECK=0 git commit ..." >&2
echo "Docs: docs/process/CSS_TOKEN_DISCIPLINE.md" >&2
exit 1
