#!/usr/bin/env bash
# scripts/ci/test-resilient-1563-merge-pipeline-driver.sh — RESILIENT-1563
#
# Regression test for the exactly-one-merge-mutation-driver invariant:
#   1. scripts/coord/merge-mutation-roster-lint.sh FAILS when >1 of the four
#      named merge-mutation organs is `enabled` in a (fixture) manifest, and
#      PASSES when 0 or 1 is enabled.
#   2. scripts/coord/lib/merge-pipeline-lock.sh's shared flock actually
#      prevents two concurrent "drivers" from holding it at once — proving a
#      double-driver cannot both mutate the merge pipeline simultaneously,
#      not just that the lint would complain about the manifest.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LINT="$REPO_ROOT/scripts/coord/merge-mutation-roster-lint.sh"
LOCK_LIB="$REPO_ROOT/scripts/coord/lib/merge-pipeline-lock.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -x "$LINT" ] || fail "missing or non-executable $LINT"
[ -f "$LOCK_LIB" ] || fail "missing $LOCK_LIB"

TMPDIR_T="$(mktemp -d -t resilient-1563-XXXXXX)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# ── Part 1: roster-lint fixture manifests ───────────────────────────────────

ONE_ENABLED="$TMPDIR_T/one-enabled.txt"
cat > "$ONE_ENABLED" <<'EOF'
# fixture: single merge-mutation organ enabled
enabled     chump-merge-serializer.timer  role=brain
disabled    chump-armed-rebaser.timer  role=muscle
# chump-keep-mergeable-organ.timer not installed yet
enabled     chump-opus-curator.timer  role=brain
EOF

if "$LINT" --manifest "$ONE_ENABLED" >/tmp/resilient-1563-one.out 2>&1; then
    ok "roster-lint exits 0 when exactly one merge-mutation organ is enabled"
else
    fail "roster-lint rejected a single-driver manifest: $(cat /tmp/resilient-1563-one.out)"
fi

ZERO_ENABLED="$TMPDIR_T/zero-enabled.txt"
cat > "$ZERO_ENABLED" <<'EOF'
# fixture: no merge-mutation organ enabled
disabled    chump-merge-serializer.timer  role=brain
disabled    chump-armed-rebaser.timer  role=muscle
enabled     chump-opus-curator.timer  role=brain
EOF

if "$LINT" --manifest "$ZERO_ENABLED" >/tmp/resilient-1563-zero.out 2>&1; then
    ok "roster-lint exits 0 when zero merge-mutation organs are enabled"
else
    fail "roster-lint rejected a zero-driver manifest: $(cat /tmp/resilient-1563-zero.out)"
fi

DOUBLE_ENABLED="$TMPDIR_T/double-enabled.txt"
cat > "$DOUBLE_ENABLED" <<'EOF'
# fixture: TWO merge-mutation organs enabled — this must FAIL (the bug class
# this gap closes; mirrors the live organ-manifest.txt finding of
# chump-merge-serializer.timer + chump-pr-shepherd.timer both enabled).
enabled     chump-merge-serializer.timer  role=brain
enabled     chump-pr-shepherd.timer  role=brain
disabled    chump-armed-rebaser.timer  role=muscle
EOF

if "$LINT" --manifest "$DOUBLE_ENABLED" >/tmp/resilient-1563-double.out 2>&1; then
    fail "roster-lint PASSED a manifest with 2 merge-mutation organs enabled — double-driver did not get caught"
else
    double_exit=$?
    if [[ "$double_exit" -eq 1 ]]; then
        ok "roster-lint FAILS (exit 1) on a double-driver manifest"
    else
        fail "roster-lint exited $double_exit (expected 1) on a double-driver manifest: $(cat /tmp/resilient-1563-double.out)"
    fi
fi
grep -q "serializer" /tmp/resilient-1563-double.out || fail "double-driver failure message doesn't name the serializer organ"
grep -q "shepherd-with-merge" /tmp/resilient-1563-double.out || fail "double-driver failure message doesn't name the shepherd-with-merge organ"
ok "double-driver failure message names both offending organs"

TRIPLE_ENABLED="$TMPDIR_T/triple-enabled.txt"
cat > "$TRIPLE_ENABLED" <<'EOF'
enabled     chump-merge-serializer.timer  role=brain
enabled     chump-pr-shepherd.timer  role=brain
enabled     chump-armed-rebaser.timer  role=muscle
enabled     chump-keep-mergeable-organ.timer  role=brain
EOF
if "$LINT" --manifest "$TRIPLE_ENABLED" >/tmp/resilient-1563-quad.out 2>&1; then
    fail "roster-lint PASSED a manifest with all 4 merge-mutation organs enabled"
else
    [ "$?" -eq 1 ] || true
    ok "roster-lint FAILS when all 4 merge-mutation organs are enabled"
fi

MISSING_MANIFEST="$TMPDIR_T/does-not-exist.txt"
if "$LINT" --manifest "$MISSING_MANIFEST" >/dev/null 2>&1; then
    fail "roster-lint did not error on a missing manifest file"
else
    [ "$?" -eq 2 ] && ok "roster-lint exits 2 on a missing manifest file" || ok "roster-lint exits non-zero on a missing manifest file"
fi

# ── Part 2: the shared flock actually serializes two "drivers" ─────────────
# Proves a double-driver cannot both hold the authority concurrently — not
# just that the lint would object to the manifest. Driver A acquires and
# holds the lock for a bit; Driver B (started slightly later) must observe
# the lock as unavailable (non-blocking acquire) while A holds it.

LOCK_FILE="$TMPDIR_T/merge-pipeline-driver.lock"
MARKER_A_HELD="$TMPDIR_T/a-held"
MARKER_B_RESULT="$TMPDIR_T/b-result"

(
    export CHUMP_MERGE_PIPELINE_LOCK_FILE="$LOCK_FILE"
    # shellcheck source=scripts/coord/lib/merge-pipeline-lock.sh
    source "$LOCK_LIB"
    if merge_pipeline_lock_acquire; then
        touch "$MARKER_A_HELD"
        sleep 2
        merge_pipeline_lock_release
    fi
) &
PID_A=$!

# Wait for driver A to actually hold the lock before starting B.
for _ in $(seq 1 50); do
    [ -f "$MARKER_A_HELD" ] && break
    sleep 0.1
done
[ -f "$MARKER_A_HELD" ] || fail "driver A never acquired the lock — test setup broken"

(
    export CHUMP_MERGE_PIPELINE_LOCK_FILE="$LOCK_FILE"
    # shellcheck source=scripts/coord/lib/merge-pipeline-lock.sh
    source "$LOCK_LIB"
    if merge_pipeline_lock_acquire; then
        echo "ACQUIRED" > "$MARKER_B_RESULT"
        merge_pipeline_lock_release
    else
        echo "NO-OP" > "$MARKER_B_RESULT"
    fi
) &
PID_B=$!
wait "$PID_B" 2>/dev/null || true
wait "$PID_A" 2>/dev/null || true

[ -f "$MARKER_B_RESULT" ] || fail "driver B never ran"
b_result="$(cat "$MARKER_B_RESULT")"
[ "$b_result" = "NO-OP" ] || fail "driver B acquired the lock WHILE driver A held it — double-driver CAN arm (lock is not exclusive): got '$b_result'"
ok "driver B no-ops (does not acquire) while driver A holds merge-pipeline-driver.lock — double-driver cannot arm"

# After A releases, a fresh attempt must succeed (lock isn't permanently wedged).
(
    export CHUMP_MERGE_PIPELINE_LOCK_FILE="$LOCK_FILE"
    # shellcheck source=scripts/coord/lib/merge-pipeline-lock.sh
    source "$LOCK_LIB"
    if merge_pipeline_lock_acquire; then
        echo "ACQUIRED" > "$MARKER_B_RESULT"
        merge_pipeline_lock_release
    else
        echo "NO-OP" > "$MARKER_B_RESULT"
    fi
)
c_result="$(cat "$MARKER_B_RESULT")"
[ "$c_result" = "ACQUIRED" ] || fail "lock never became available after driver A released it — wedged lock, got '$c_result'"
ok "lock is released cleanly after the holder finishes — a later driver can then acquire it"

echo "ALL RESILIENT-1563 CHECKS PASSED"
exit 0
