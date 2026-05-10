#!/usr/bin/env bash
# check-path-filter-coverage.sh — INFRA-682: structural guard for the 'code:'
# paths-filter allowlist in .github/workflows/ci.yml.
#
# Fails if any top-level directory (or key top-level file) in the repo is NOT
# listed under the 'code:' filter.  A PR whose sole diff touches an uncovered
# path will have all required CI checks SKIPPED — branch protection counts
# skipped != passing and permanently blocks the merge (INFRA-272).
#
# Emits ::warning:: GitHub Actions annotations when GITHUB_ACTIONS=true.
#
# Usage (both forms respect REPO_ROOT override for testing):
#   bash check-path-filter-coverage.sh
#   REPO_ROOT=/tmp/fake-repo bash check-path-filter-coverage.sh
#
# Exit codes:
#   0 — all top-level paths are covered
#   1 — one or more paths are missing from the code: allowlist
#   2 — ci.yml not found

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

if [[ ! -f "$CI_YML" ]]; then
    echo "[check-path-filter-coverage] ERROR: ci.yml not found at $CI_YML" >&2
    exit 2
fi

# ── Extract 'code:' patterns from the filters: | block ───────────────────
# Anchors to 'filters: |' to skip the job 'outputs:' section above it, which
# has the same key names (code:, e2e:, tauri:) and would confuse a naive grep.
extract_code_patterns() {
    awk "
        /filters: \|/ { start=NR }
        start && NR>start && /^[[:space:]]+code:/ { found=1; next }
        found && /^[[:space:]]+-[[:space:]]/ {
            line=\$0
            gsub(/[[:space:]]*-[[:space:]]+|'/, \"\", line)
            print line; next
        }
        found && /^[[:space:]]+[a-z]/ { exit }
    " "$CI_YML"
}

code_patterns="$(extract_code_patterns)"

# Returns 0 if 'name' is covered by any code: pattern.
# Handles patterns like 'src/**', 'Cargo.toml', '.github/workflows/**'.
is_covered() {
    local name="$1"
    # First path segment match: 'src/**' covers 'src', '.github/workflows/**' covers '.github/workflows'
    echo "$code_patterns" | grep -qE "^${name}(/|$)" && return 0
    # Substring match for exact filenames like 'Cargo.toml', '.release-plz.toml'
    echo "$code_patterns" | grep -qF "$name" && return 0
    return 1
}

FAIL=0
declare -a missing=()

emit_failure() {
    local path="$1"
    missing+=("$path")
    FAIL=1
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        echo "::warning file=.github/workflows/ci.yml::Path '$path' is not in the 'code:' paths-filter allowlist. A PR whose sole diff is under '$path' will have required CI checks SKIPPED (skipped != passing under branch protection) and will block merge permanently. Add \"- '$path/**'\" to the code: section. See INFRA-272/INFRA-682."
    fi
    echo "[FAIL] '$path' — missing from code: paths-filter allowlist" >&2
}

echo "[check-path-filter-coverage] scanning $REPO_ROOT against $CI_YML ..."

# ── 1. Every non-hidden top-level directory (skip gitignored) ────────────
while IFS= read -r -d '' dir; do
    name="$(basename "$dir")"
    [[ "$name" == .* ]] && continue
    git -C "$REPO_ROOT" check-ignore -q "$name" 2>/dev/null && continue
    is_covered "$name" || emit_failure "$name"
done < <(find "$REPO_ROOT" -maxdepth 1 -mindepth 1 -type d -print0 | sort -z)

# ── 2. Key top-level files that can be the sole diff of a real PR ─────────
for f in Cargo.toml Cargo.lock .release-plz.toml; do
    [[ -e "$REPO_ROOT/$f" ]] || continue
    is_covered "$f" || emit_failure "$f"
done

# ── 3. .github/workflows explicitly (hidden parent; workflows change solo) ─
is_covered ".github/workflows" || emit_failure ".github/workflows"

# ── Report ────────────────────────────────────────────────────────────────
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "[check-path-filter-coverage] OK — all top-level paths are covered by code: allowlist."
    exit 0
fi

echo "[check-path-filter-coverage] FAIL: ${#missing[@]} path(s) not in code: allowlist:" >&2
for m in "${missing[@]}"; do
    echo "  - $m" >&2
done
echo "" >&2
echo "Fix: add the missing path(s) to the 'code:' section in .github/workflows/ci.yml" >&2
echo "     (each entry: \"- 'path/**'\").  See INFRA-272 / INFRA-682." >&2
exit 1
