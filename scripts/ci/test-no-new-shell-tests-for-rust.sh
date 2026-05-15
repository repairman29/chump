#!/usr/bin/env bash
# INFRA-1306: ZERO-WASTE lint gate against new `scripts/ci/test-*.sh` files
# that primarily exercise Rust-backed `chump <subcommand>` logic.
#
# 595 shell test scripts ship today (78k LOC, the single largest chunk of
# fleet shell). They were the right tool when most fleet logic was bash,
# but every new gap-ship cycle adds 1-2 more — the test-shell count
# outgrows the production-shell count. New tests for Rust-backed code
# should be Rust integration tests (`tests/*.rs` invoked via `cargo test`),
# not yet-another `test-foo.sh` that boots the binary, curls, greps.
#
# What it does:
#   1. Detect `scripts/ci/test-*.sh` files added in this PR (vs origin/main)
#   2. Heuristic: if the new test invokes `target/debug/chump`,
#      `target/release/chump`, `cargo run`, or simply runs `chump <verb>`,
#      it's a Rust-backed test that should be `cargo test` instead.
#   3. Skip files in scripts/ci/shell-test-allowlist.txt with required
#      `# reason:` comment (the 595 existing tests don't need entries —
#      this checks NET-NEW only).
#   4. Fail with a pointer to docs/process/CODEBASE_DRY_UP.md + a sample
#      Rust integration-test template path.
#
# Modes (CHUMP_NEW_SHELL_TEST_MODE):
#   strict (default in CI) — fail on any new shell test for Rust-backed code
#   warn               — print violations, exit 0 (rollout buffer)
#   report             — print + exit 0, diagnostic only
#
# Companion gates:
#   - INFRA-1223 test-no-direct-auto-merge-arm.sh (shipped)
#   - INFRA-1274 test-no-raw-gh-in-hot-paths.sh   (shipped)
#   - INFRA-1305 test-no-new-coord-shell.sh       (shipped, PR #1971)
#   - INFRA-1307 test-no-inline-ambient-printf.sh (pending)

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${REPO_ROOT}"

MODE="${CHUMP_NEW_SHELL_TEST_MODE:-strict}"
ALLOWLIST="scripts/ci/shell-test-allowlist.txt"
POLICY_DOC="docs/process/CODEBASE_DRY_UP.md"

BASE_REF="${BASE_REF:-origin/main}"
if ! git rev-parse --verify --quiet "${BASE_REF}" >/dev/null; then
    BASE_REF="$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)"
fi

# Allowlist (portable bash 3.2 lookup).
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

# Net-new scripts/ci/test-*.sh
added=()
while IFS= read -r line; do
    [[ -n "$line" ]] && added+=("$line")
done < <(
    git diff --name-only --diff-filter=A "${BASE_REF}"...HEAD -- 'scripts/ci/test-*.sh' 2>/dev/null || true
)

# Patterns that indicate the test is exercising Rust-backed `chump` logic.
# Conservative — only flag when at least one of these patterns appears.
is_rust_backed() {
    local f="$1"
    [[ ! -f "$f" ]] && return 1
    # Look for explicit binary invocations.
    grep -qE 'target/(debug|release)/chump\b' "$f" 2>/dev/null && return 0
    grep -qE '\bcargo\s+run\s+(--release\s+)?(-p\s+chump\b|--bin\s+chump\b)' "$f" 2>/dev/null && return 0
    # Look for `chump <verb>` style invocations (positional verb after `chump`).
    # Excludes `chump-coord`, `chump_gh`, `chump-plan` (separate binaries OK).
    grep -qE '(^|[[:space:]"$])chump[[:space:]]+(--web|gap|claim|fleet|ship|--briefing|--execute-gap|--release|emit-ambient|pr|health)\b' "$f" 2>/dev/null && return 0
    return 1
}

VIOLATIONS=0
for f in "${added[@]:-}"; do
    [[ -z "$f" ]] && continue
    if is_allowed "$f"; then
        continue
    fi
    if ! is_rust_backed "$f"; then
        # Pure shell test (no chump binary involvement) — fine.
        continue
    fi
    echo "[shell-test-lint] FAIL: ${f} is a NEW shell test exercising chump (Rust) logic" >&2
    echo "[shell-test-lint]   Rust-native policy: new tests for chump subcommands belong in tests/*.rs" >&2
    echo "[shell-test-lint]   (or per-crate tests/, exercised by cargo test). See:" >&2
    echo "[shell-test-lint]     ${POLICY_DOC}" >&2
    echo "[shell-test-lint]   Example Rust integration test layout:" >&2
    echo "[shell-test-lint]     tests/<feature>.rs  (top-level — exercises the chump binary)" >&2
    echo "[shell-test-lint]     crates/chump-planner/tests/<feature>.rs  (per-crate)" >&2
    echo "[shell-test-lint]   If shell really is the right tool (e.g. CLI ergonomics test, multi-process race):" >&2
    echo "[shell-test-lint]     - add ${f} to ${ALLOWLIST} with a # reason: comment" >&2
    VIOLATIONS=$((VIOLATIONS + 1))
done

if [[ $VIOLATIONS -gt 0 ]]; then
    case "$MODE" in
        warn|report)
            echo "[shell-test-lint] $VIOLATIONS new shell-test violation(s); mode=$MODE so NOT failing build." >&2
            exit 0
            ;;
        *)
            echo "" >&2
            echo "[shell-test-lint] $VIOLATIONS new shell-test violation(s). Fix above." >&2
            exit 1
            ;;
    esac
fi

echo "[shell-test-lint] OK — no new shell tests exercise Rust-backed chump logic in this PR"
exit 0
