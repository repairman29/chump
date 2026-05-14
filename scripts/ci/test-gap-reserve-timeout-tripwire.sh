#!/usr/bin/env bash
# test-gap-reserve-timeout-tripwire.sh — INFRA-301
#
# Verifies scripts/coord/gap-reserve.sh fails loudly with the chump-doctor
# banner when `chump gap reserve` times out, instead of returning empty
# and letting the caller invent a YAML-write fallback.
#
# Test technique: prepend a fake `chump` to PATH that just `sleep 999`s,
# set CHUMP_GAP_RESERVE_TIMEOUT_S=2, run gap-reserve.sh and assert (a) it
# exits non-zero, (b) the banner mentions chump-binary-unwedge.sh, (c) the banner
# warns against direct YAML writes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESERVE="$REPO_ROOT/scripts/coord/gap-reserve.sh"

if [[ ! -x "$RESERVE" ]]; then
    echo "FAIL: $RESERVE not executable" >&2
    exit 1
fi

# Build a fake repo so gap-reserve has somewhere to write its lease.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/repo"
cd "$SANDBOX/repo"
git init -q -b main
git config user.email "test@test.com"
git config user.name "Test"
mkdir -p docs/gaps
echo "init" > .gitkeep
git add .gitkeep
git commit -q -m init

# Add a worktree off this so gap-reserve doesn't refuse the main-worktree guard.
git worktree add "$SANDBOX/wt" -b test/branch >/dev/null 2>&1

# Fake chump that hangs forever. PATH-prepend this shim.
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/chump" <<'EOF'
#!/usr/bin/env bash
# Fake chump for INFRA-301 timeout test. Pretend to be a wedged binary —
# accept any args, sleep forever.
exec sleep 999
EOF
chmod +x "$SANDBOX/bin/chump"

# Stub flock(1) for environments without util-linux (default macOS). The
# real script's lock is defense-in-depth around the chump SQLite counter;
# the timeout behavior we're testing doesn't depend on the lock semantics.
if ! command -v flock >/dev/null 2>&1; then
    cat > "$SANDBOX/bin/flock" <<'EOF'
#!/usr/bin/env bash
# Test-only flock stub. Real flock is defense-in-depth; the production
# correctness invariant is enforced by `chump gap reserve` itself
# (BEGIN IMMEDIATE on the SQLite store). For this test we just exit 0.
exit 0
EOF
    chmod +x "$SANDBOX/bin/flock"
fi

# Run gap-reserve with the shim in PATH and a tight timeout. Capture both
# streams, verify exit code + stderr content.
cd "$SANDBOX/wt"
output_file="$SANDBOX/output.txt"
error_file="$SANDBOX/error.txt"

set +e
PATH="$SANDBOX/bin:$PATH" \
CHUMP_GAP_RESERVE_TIMEOUT_S=2 \
CHUMP_LOCK_DIR="$SANDBOX/locks" \
CHUMP_SESSION_ID="test-session" \
    "$RESERVE" INFRA "test title" \
        > "$output_file" 2> "$error_file"
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
    echo "FAIL: expected non-zero exit code, got 0" >&2
    cat "$output_file" "$error_file" >&2
    exit 1
fi

if ! grep -q "timed out after 2s" "$error_file"; then
    echo "FAIL: stderr missing 'timed out after 2s' message" >&2
    cat "$error_file" >&2
    exit 1
fi

if ! grep -q "scripts/dev/chump-binary-unwedge.sh" "$error_file"; then
    echo "FAIL: stderr missing chump-binary-unwedge.sh remediation pointer" >&2
    cat "$error_file" >&2
    exit 1
fi

if ! grep -q "DO NOT fall back" "$error_file"; then
    echo "FAIL: stderr missing 'DO NOT fall back' warning against YAML writes" >&2
    cat "$error_file" >&2
    exit 1
fi

# Verify the lease file was NOT written with a fake gap ID — the failure
# mode this test guards against is gap-reserve appearing-to-succeed and
# leaving stale state behind.
if [[ -d "$SANDBOX/locks" ]]; then
    if find "$SANDBOX/locks" -name '*.json' | xargs grep -l 'pending_new_gap' 2>/dev/null | head -1 | grep -q .; then
        echo "FAIL: gap-reserve wrote pending_new_gap to lease despite timeout" >&2
        exit 1
    fi
fi

echo "PASS: gap-reserve timeout produces chump-doctor banner + non-zero exit + no stale lease"
