#!/usr/bin/env bash
# scripts/ci/test-refresh-runner-binary-worktree-path.sh — RESILIENT-348
#
# Verifies scripts/setup/refresh-runner-binary.sh no longer hardcodes its
# build worktree to /tmp. On small-/tmp nodes (e.g. CJ: 3.6G tmpfs, 753M
# free) `git worktree add` checking out the full tree into /tmp fails with
# "unable to write file / Could not reset index", freezing self-deploy every
# cycle. The fix defaults the worktree parent to CHUMP_STATE_DIR (durable
# disk) and auto-picks the roomiest known candidate if that volume is tight.
#
# This test proves the behavior WITHOUT running a real cargo build: it sources
# the pick_build_worktree_parent() function definition out of the script into
# a fresh shell and drives it directly against synthetic free-space fixtures.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RS="$REPO_ROOT/scripts/setup/refresh-runner-binary.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$RS" ]] || fail "refresh-runner-binary.sh missing or not executable"
grep -q 'RESILIENT-348' "$RS" || fail "RESILIENT-348 banner missing"
grep -q 'pick_build_worktree_parent' "$RS" || fail "pick_build_worktree_parent() missing"

# Guard against regressing back to a hardcoded /tmp default: the ONLY
# occurrence of a literal /tmp default for BUILD_WORKTREE must be inside the
# candidate list, not as the unconditional fallback.
grep -q 'BUILD_WORKTREE="\${CHUMP_BINARY_REFRESH_WORKTREE:-/tmp/chump-binary-refresh-\$\$}"' "$RS" \
    && fail "BUILD_WORKTREE still hardcodes /tmp as the unconditional default"
ok "no hardcoded /tmp default for BUILD_WORKTREE"

# ── Functional: drive pick_build_worktree_parent() directly ────────────────
# Extract just the function body so we can call it standalone with a fake
# `df` on PATH that reports synthetic free-space numbers per mount, instead
# of depending on the real filesystem layout of the CI runner.
FUNC_FILE="$TMP/func.sh"
awk '/^pick_build_worktree_parent\(\) \{/,/^\}/' "$RS" > "$FUNC_FILE"
[[ -s "$FUNC_FILE" ]] || fail "could not extract pick_build_worktree_parent() body"

mkdir -p "$TMP/state" "$TMP/repo" "$TMP/tmp-mount"

# Fake `df -Pk <path>` — routes by which fixture dir is passed, so we can
# simulate: state dir has plenty of room -> state dir wins even though /tmp
# is a candidate.
cat > "$TMP/df" <<EOF
#!/usr/bin/env bash
# args: -Pk <path>
path="\$2"
case "\$path" in
  "$TMP/state") echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "fake 100000000 1000000 5000000 1% $TMP/state" ;;
  "$TMP/repo")  echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "fake 100000000 1000000 4000000 1% $TMP/repo" ;;
  "$TMP/tmp-mount") echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "fake 3600000 3400000 700000 95% $TMP/tmp-mount" ;;
  "/tmp") echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "fake 3600000 3400000 700000 95% /tmp" ;;
  *) echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "fake 100000000 1000000 5000000 1% \$path" ;;
esac
EOF
chmod +x "$TMP/df"

# Case 1: state dir has >= min free -> picked immediately (even though repo
# has more absolute space in this fixture — state dir short-circuits).
(
    PATH="$TMP:$PATH"
    CHUMP_STATE_DIR="$TMP/state"
    REPO_ROOT="$TMP/repo"
    BUILD_WORKTREE_MIN_FREE_KB=2097152
    export CHUMP_STATE_DIR REPO_ROOT BUILD_WORKTREE_MIN_FREE_KB
    source "$FUNC_FILE"
    RESULT="$(pick_build_worktree_parent)"
    [[ "$RESULT" == "$TMP/state" ]] || { echo "got '$RESULT', want '$TMP/state'"; exit 1; }
) || fail "roomy CHUMP_STATE_DIR should be picked directly"
ok "roomy CHUMP_STATE_DIR is picked as the worktree parent"

# Case 2: state dir is tight (simulate by pointing CHUMP_STATE_DIR at the
# tmpfs-like fixture) -> falls back to whichever candidate has the MOST free
# space (repo, in this fixture), never silently landing on the tightest /tmp.
(
    PATH="$TMP:$PATH"
    CHUMP_STATE_DIR="$TMP/tmp-mount"
    REPO_ROOT="$TMP/repo"
    BUILD_WORKTREE_MIN_FREE_KB=2097152
    export CHUMP_STATE_DIR REPO_ROOT BUILD_WORKTREE_MIN_FREE_KB
    source "$FUNC_FILE"
    RESULT="$(pick_build_worktree_parent)"
    [[ "$RESULT" == "$TMP/repo" ]] || { echo "got '$RESULT', want '$TMP/repo' (roomiest candidate)"; exit 1; }
) || fail "tight CHUMP_STATE_DIR should fall back to the roomiest candidate, not /tmp"
ok "tight CHUMP_STATE_DIR falls back to the roomiest known candidate"

echo
echo "All RESILIENT-348 refresh-runner-binary worktree-path tests passed."
