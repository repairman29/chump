#!/usr/bin/env bash
# INFRA-1307: ZERO-WASTE lint gate against new inline `printf '{"kind":...}'
# >> ambient.jsonl` emits. New emit sites must use the `chump ambient emit`
# helper (shipped via INFRA-1048, lives in src/ambient_emit.rs).
#
# Today there are 17 production inline-emit sites — each one duplicates
# the same printf-with-timestamp-and-fields pattern, none validate against
# EVENT_REGISTRY.yaml, none auto-fill session/worktree/harness. The
# `chump ambient emit` helper does all three. Migrating each existing
# site reduces shell + improves observability.
#
# What it does:
#   1. Detect `*.sh` / `*.py` / `*.rs` files in production paths
#      (scripts/coord|dispatch|ops/, src/, crates/) that contain
#      `>> .*ambient.jsonl` redirects (write pattern).
#   2. Skip scripts/coord/lib/ (helpers may stay), test-* (test fixtures),
#      and the existing 17 sites listed in scripts/ci/ambient-emit-allowlist.txt
#   3. Fail when a NEW file with that pattern appears (vs origin/main)
#      AND it's not in the allowlist.
#   4. Failure message points at `chump ambient emit --help` + the
#      CODEBASE_DRY_UP.md policy doc.
#
# Modes (CHUMP_NEW_AMBIENT_PRINTF_MODE):
#   strict (default in CI) — fail on net-new inline emits
#   warn               — print violations, exit 0
#   report             — diagnostic only
#
# Companion gates (Phase-1 dry-up):
#   - INFRA-1223 test-no-direct-auto-merge-arm.sh
#   - INFRA-1274 test-no-raw-gh-in-hot-paths.sh
#   - INFRA-1305 test-no-new-coord-shell.sh
#   - INFRA-1306 test-no-new-shell-tests-for-rust.sh

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${REPO_ROOT}"

MODE="${CHUMP_NEW_AMBIENT_PRINTF_MODE:-strict}"
ALLOWLIST="scripts/ci/ambient-emit-allowlist.txt"
POLICY_DOC="docs/process/CODEBASE_DRY_UP.md"

BASE_REF="${BASE_REF:-origin/main}"
if ! git rev-parse --verify --quiet "${BASE_REF}" >/dev/null; then
    BASE_REF="$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)"
fi

# Portable bash 3.2 allowlist lookup.
ALLOWED_TMP=""
if [[ -f "$ALLOWLIST" ]]; then
    ALLOWED_TMP="$(mktemp)"
    while IFS= read -r ln; do
        s="${ln#"${ln%%[![:space:]]*}"}"
        [[ -z "$s" || "$s" == "#"* ]] && continue
        path="${s%%#*}"
        path="${path%"${path##*[![:space:]]}"}"
        [[ -n "$path" ]] && printf '%s\n' "$path" >> "$ALLOWED_TMP"
    done < "$ALLOWLIST"
fi
is_allowed() {
    [[ -z "$ALLOWED_TMP" ]] && return 1
    grep -qxF -- "$1" "$ALLOWED_TMP" 2>/dev/null
}
trap '[[ -n "$ALLOWED_TMP" ]] && rm -f "$ALLOWED_TMP"' EXIT

# Find all production files that currently contain a `>> *.ambient.jsonl`
# pattern (writes). We then filter to NET-NEW files only.
WRITE_PATTERN='>>[[:space:]]*"?[^"#]*ambient\.jsonl|writeln!\([^,]+,[^)]+ambient'

# All current writers (full file list, not just new)
all_writers="$(mktemp)"
trap '[[ -n "$ALLOWED_TMP" ]] && rm -f "$ALLOWED_TMP"; rm -f "$all_writers"' EXIT
grep -rlE "$WRITE_PATTERN" scripts/coord/ scripts/dispatch/ scripts/ops/ src/ crates/ \
    --include='*.sh' --include='*.py' --include='*.rs' 2>/dev/null | \
    grep -v '/lib/' | grep -v 'test-' | sed 's|^./||' | sort -u > "$all_writers" || true

# Files added in this PR vs base
added_in_pr="$(mktemp)"
git diff --name-only --diff-filter=A "${BASE_REF}"...HEAD 2>/dev/null | sort -u > "$added_in_pr" || true

# Intersection: writers that are also new in this PR.
VIOLATIONS=0
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # Only act on files actually in the writer set
    grep -qxF "$f" "$all_writers" || continue
    if is_allowed "$f"; then
        continue
    fi
    echo "[ambient-emit-lint] FAIL: ${f} is a NEW file that writes inline to ambient.jsonl" >&2
    echo "[ambient-emit-lint]   Rust-native policy: new emit sites should use the existing helper:" >&2
    echo "[ambient-emit-lint]     chump ambient emit <kind> [--gap GAP-ID] [--field key=value]..." >&2
    echo "[ambient-emit-lint]   This auto-fills ts/session/worktree/harness, respects EVENT_REGISTRY," >&2
    echo "[ambient-emit-lint]   and avoids duplicating the printf-redirect pattern in 17+ scripts." >&2
    echo "[ambient-emit-lint]   See ${POLICY_DOC} and \`chump ambient emit --help\`." >&2
    echo "[ambient-emit-lint]   If this site genuinely cannot use the helper, add ${f} to" >&2
    echo "[ambient-emit-lint]     ${ALLOWLIST}" >&2
    echo "[ambient-emit-lint]   with a # reason: comment." >&2
    VIOLATIONS=$((VIOLATIONS + 1))
done < "$added_in_pr"
rm -f "$added_in_pr"

if [[ $VIOLATIONS -gt 0 ]]; then
    case "$MODE" in
        warn|report)
            echo "[ambient-emit-lint] $VIOLATIONS new inline-emit file(s); mode=$MODE so NOT failing." >&2
            exit 0
            ;;
        *)
            echo "" >&2
            echo "[ambient-emit-lint] $VIOLATIONS new inline-emit violation(s). Fix above." >&2
            exit 1
            ;;
    esac
fi

echo "[ambient-emit-lint] OK — no NEW files write inline to ambient.jsonl outside the allowlist"
exit 0
