#!/usr/bin/env bash
# INFRA-1305: ZERO-WASTE lint gate against new `scripts/coord/*.sh` files.
#
# Today the fleet coordination layer is ~47% shell by LOC. Every new
# failure mode tends to spawn a new bash script in scripts/coord/; the
# trend goes one way. This gate freezes growth so the Rust-port effort
# (INFRA-1229/1225/1227 et al.) can actually catch up.
#
# What it does:
#   1. Detect `scripts/coord/*.sh` files added in this PR (not in origin/main)
#   2. Filter: skip scripts/coord/lib/ (helper libs can stay shell-native
#      for now) and test-* (covered by INFRA-1306)
#   3. Skip files explicitly allowlisted in scripts/ci/coord-shell-allowlist.txt
#      with a required `# reason:` comment
#   4. Fail with a pointer to docs/process/CODEBASE_DRY_UP.md (the
#      operator-facing policy doc)
#
# Modes (CHUMP_NEW_COORD_SHELL_MODE):
#   strict (default in CI) — fail on any new coord shell
#   warn               — print violations, exit 0 (rollout buffer)
#   report             — print + exit 0, diagnostic only
#
# Companion gates:
#   - INFRA-1223 test-no-direct-auto-merge-arm.sh (specific `--auto` callers)
#   - INFRA-1274 test-no-raw-gh-in-hot-paths.sh   (raw gh in coord/dispatch/ops)
#   - INFRA-1306 test-no-new-shell-tests-for-rust.sh  (filing follows)
#   - INFRA-1307 test-no-inline-ambient-printf.sh     (filing follows)

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${REPO_ROOT}"

MODE="${CHUMP_NEW_COORD_SHELL_MODE:-strict}"
ALLOWLIST="scripts/ci/coord-shell-allowlist.txt"
POLICY_DOC="docs/process/CODEBASE_DRY_UP.md"

# Determine the base ref. CI passes BASE_REF=origin/main; local invocations
# default to origin/main and fall back to merge-base with HEAD.
BASE_REF="${BASE_REF:-origin/main}"
if ! git rev-parse --verify --quiet "${BASE_REF}" >/dev/null; then
    BASE_REF="$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)"
fi

# Allowlist of *.sh files that pre-date this lint and stay allowed until
# their migration gap lands. Comments + blanks ignored. Portable to bash 3.2
# (macOS ships old bash) — newline-delimited file scanned linearly.
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

# New (Added) shell files under scripts/coord/. Portable to bash 3.2:
# read into an array via while-read instead of mapfile.
added=()
while IFS= read -r line; do
    [[ -n "$line" ]] && added+=("$line")
done < <(
    git diff --name-only --diff-filter=A "${BASE_REF}"...HEAD -- 'scripts/coord/*.sh' 2>/dev/null || true
)

VIOLATIONS=0
for f in "${added[@]:-}"; do
    [[ -z "$f" ]] && continue
    case "$f" in
        scripts/coord/lib/*)            continue ;;
        scripts/coord/test-*|scripts/coord/*/test-*)  continue ;;
    esac
    base="$(basename "$f")"
    if [[ "$base" == test-* ]]; then
        continue
    fi
    if is_allowed "$f"; then
        continue
    fi
    echo "[coord-shell-lint] FAIL: ${f} is a NEW shell script under scripts/coord/" >&2
    echo "[coord-shell-lint]   Rust-native policy: new fleet coordination logic should be a chump subcommand," >&2
    echo "[coord-shell-lint]   not a bash script. See:" >&2
    echo "[coord-shell-lint]     ${POLICY_DOC}" >&2
    echo "[coord-shell-lint]   If genuinely needed as shell (e.g. one-shot operator recovery tool):" >&2
    echo "[coord-shell-lint]     - file a migration gap referencing INFRA-1229 (the umbrella)" >&2
    echo "[coord-shell-lint]     - add the path to ${ALLOWLIST} with a # reason: comment" >&2
    VIOLATIONS=$((VIOLATIONS + 1))
done

if [[ $VIOLATIONS -gt 0 ]]; then
    case "$MODE" in
        warn|report)
            echo "[coord-shell-lint] $VIOLATIONS new coord shell file(s); mode=$MODE so NOT failing build." >&2
            exit 0
            ;;
        *)
            echo "" >&2
            echo "[coord-shell-lint] $VIOLATIONS new coord shell violation(s). Fix above." >&2
            exit 1
            ;;
    esac
fi

echo "[coord-shell-lint] OK — no new scripts/coord/*.sh files added in this PR"
exit 0
