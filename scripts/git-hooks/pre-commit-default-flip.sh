#!/usr/bin/env bash
# pre-commit-default-flip.sh — INFRA-762
#
# Catches the "flipped a default but didn't update parallel tests"
# failure mode (EVAL-026 #1349 was the canonical case: flipped
# `chump_bypass_neuromod()` default, updated test in env_flags.rs, but
# missed `neuromod_enabled_default_on()` in neuromodulation.rs which
# transitively asserted the old default through `neuromod_enabled()`'s
# short-circuit).
#
# What it detects
#   In staged diffs of `*_flags*.rs` / `*_config*.rs` / files matching
#   `flag.rs|config.rs`, look for line-level FLIPS of:
#       unwrap_or(false) ↔ unwrap_or(true)
#       unwrap_or_default()  on bool fields (advisory only)
#       const FOO: bool = true  ↔  const FOO: bool = false
#
#   For each detected flip, identify the enclosing `pub fn <name>(...)`,
#   then grep all *.rs test files for assertions referencing <name>.
#   Warn (do NOT block) listing stale-test candidates so the author can
#   review before commit.
#
# Why warn-not-block
#   False-positive risk. Some flips legitimately don't have parallel
#   tests; some "stale" tests may already be updated in the same diff.
#   The guard's value is the **prompt**, not the enforcement. INFRA-761
#   (cargo-test gate) is the actual block; this is the diagnostic
#   that points at the right test files when the gate trips.
#
# Bypass
#   CHUMP_DEFAULT_FLIP_CHECK=0  — skip silently. No trailer required
#   since this is advisory.

set -uo pipefail

if [[ "${CHUMP_DEFAULT_FLIP_CHECK:-1}" == "0" ]]; then
    exit 0
fi

# Stage diff scoped to flag/config-shaped files.
DIFF=$(git diff --cached --no-color --diff-filter=ACM -U3 -- \
    '*flags*.rs' '*config*.rs' '*_flag.rs' '*_config.rs' '*Flags.rs' '*Config.rs' \
    2>/dev/null || true)

if [[ -z "$DIFF" ]]; then
    exit 0
fi

# INFRA-1658: materialize DIFF once to a tempfile to dodge the
# printf|grep -q pipefail race (grep -q early-closes stdin → printf
# SIGPIPE → pipeline non-zero under set -o pipefail even on a match).
_DIFF_TMP=$(mktemp)
trap 'rm -f "$_DIFF_TMP"' EXIT
printf '%s\n' "$DIFF" > "$_DIFF_TMP"

# Find pairs of (-line, +line) where unwrap_or arg flipped.
# Approach: walk the diff, track the last `-` line; when the next line
# is `+` with the same prefix but opposite literal, record the function.
FLIPPED_FNS=()
CUR_FILE=""
CUR_FN=""

# Helper: extract `fn name` from a line like "fn pub_or_priv_fn_name<...>(...)..."
fn_name_from_line() {
    sed -nE 's/.*\bfn[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*).*/\1/p' <<< "$1" | head -1
}

while IFS= read -r line; do
    case "$line" in
        "+++ b/"*)
            CUR_FILE="${line#+++ b/}"
            CUR_FN=""
            continue
            ;;
        "@@"*)
            # Hunk header may contain context after @@ — capture it for fn lookup
            HEADER_CTX="${line#*@@}"
            HEADER_CTX="${HEADER_CTX#*@@}"
            if [[ "$HEADER_CTX" == *"fn "* ]]; then
                fn=$(fn_name_from_line "$HEADER_CTX")
                [[ -n "$fn" ]] && CUR_FN="$fn"
            fi
            continue
            ;;
    esac

    # Track the most recently seen `fn` in the unified-diff context lines.
    if [[ "$line" == " "*"fn "* || "$line" == "+ "*"fn "* || "$line" == "- "*"fn "* ]]; then
        fn=$(fn_name_from_line "$line")
        [[ -n "$fn" ]] && CUR_FN="$fn"
    fi
    # Also catch context lines starting with "+" / "-" / " " followed by `pub fn`
    if [[ "$line" =~ ^[+\ -][[:space:]]*(pub[[:space:]]+)?fn[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*) ]]; then
        CUR_FN="${BASH_REMATCH[2]}"
    fi

    # Detect flip: this line is `+` with unwrap_or(<X>) where prior `-` had unwrap_or(<!X>).
    # Use grep with -- separator since the opposite-pattern starts with `-`.
    if echo "$line" | grep -qE '^\+.*unwrap_or\(true\)'; then
        if grep -qE -- '^-.*unwrap_or\(false\)' "$_DIFF_TMP"; then
            FLIPPED_FNS+=("$CUR_FILE::${CUR_FN:-?}")
        fi
    elif echo "$line" | grep -qE '^\+.*unwrap_or\(false\)'; then
        if grep -qE -- '^-.*unwrap_or\(true\)' "$_DIFF_TMP"; then
            FLIPPED_FNS+=("$CUR_FILE::${CUR_FN:-?}")
        fi
    fi

    # Detect flip on `const FOO: bool = X`. Use grep so the leading `+` doesn't
    # confuse bash glob matchers; extract const name from the matched line.
    if echo "$line" | grep -qE '^\+.*\bconst[[:space:]]+[A-Z_][A-Z0-9_]*:[[:space:]]*bool[[:space:]]*=[[:space:]]*(true|false)'; then
        const_name=$(echo "$line" | sed -nE 's/.*const[[:space:]]+([A-Z_][A-Z0-9_]*):[[:space:]]*bool.*/\1/p')
        new_val=$(echo "$line" | sed -nE 's/.*=[[:space:]]*(true|false).*/\1/p')
        if [[ -n "$const_name" && -n "$new_val" ]]; then
            if [[ "$new_val" == "true" ]]; then
                opp="false"
            else
                opp="true"
            fi
            if grep -qE -- "^-.*\bconst[[:space:]]+${const_name}:[[:space:]]*bool[[:space:]]*=[[:space:]]*${opp}" "$_DIFF_TMP"; then
                FLIPPED_FNS+=("$CUR_FILE::$const_name")
            fi
        fi
    fi
done <<< "$DIFF"

# Dedupe.
if [[ "${#FLIPPED_FNS[@]}" -eq 0 ]]; then
    exit 0
fi
FLIPPED_FNS=($(printf '%s\n' "${FLIPPED_FNS[@]}" | sort -u))

# For each flipped (file::fn), find candidate stale tests.
echo "" >&2
echo "──────────────────────────────────────────────────────────────────────" >&2
echo "⚠ INFRA-762 default-flip detected — review parallel tests before commit." >&2
echo "" >&2

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

for entry in "${FLIPPED_FNS[@]}"; do
    file="${entry%%::*}"
    fn="${entry##*::}"
    echo "  Flipped: $file → $fn" >&2

    if [[ "$fn" == "?" ]]; then
        echo "    (couldn't determine enclosing fn — manual review recommended)" >&2
        continue
    fi

    # Search test sites: any *.rs in src/ that contains the fn name AND a
    # test marker (#[test] or fn *_test* or assert! / assert_eq!).
    # Skip the file itself (the author updated it; we're warning about
    # OTHER files that still reference the old behavior).
    candidates=$(grep -rln "$fn" --include="*.rs" "$REPO_ROOT/src" 2>/dev/null \
        | grep -v "^$REPO_ROOT/$file$" || true)

    stale=()
    while IFS= read -r cand; do
        [[ -z "$cand" ]] && continue
        # Only flag files that contain BOTH the fn name AND a test-shape line.
        if grep -qE "(#\[test\]|assert!|assert_eq!|assert_ne!)" "$cand" 2>/dev/null; then
            # Heuristic: the assertion mentions our fn, OR the file contains
            # a test name that includes "default" + the fn name.
            if grep -qE "(${fn}\(|fn[[:space:]]+[a-zA-Z_]*${fn}[a-zA-Z_]*default[a-zA-Z_]*|fn[[:space:]]+[a-zA-Z_]*default[a-zA-Z_]*${fn})" "$cand" 2>/dev/null; then
                rel="${cand#$REPO_ROOT/}"
                stale+=("$rel")
            fi
        fi
    done <<< "$candidates"

    if [[ "${#stale[@]}" -gt 0 ]]; then
        echo "    Candidate stale tests (each references $fn):" >&2
        for s in "${stale[@]}"; do
            echo "      - $s" >&2
            grep -nE "(${fn}\(|fn[[:space:]]+[a-zA-Z_]*default)" "$REPO_ROOT/$s" 2>/dev/null \
                | head -3 \
                | sed 's/^/          /' >&2
        done
    else
        echo "    (no candidate stale tests found — but verify the test suite)" >&2
    fi
    echo "" >&2
done

echo "Action: review the listed test files; if any assertion still depends on" >&2
echo "the OLD default value, update it in this commit. INFRA-761 (full-suite" >&2
echo "cargo-test gate) will catch the failure at push time, but reviewing now" >&2
echo "saves the cycle. Bypass this advisory: CHUMP_DEFAULT_FLIP_CHECK=0" >&2
echo "──────────────────────────────────────────────────────────────────────" >&2

# Advisory only — exit 0 to allow the commit. The author has been warned.
exit 0
