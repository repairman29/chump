#!/usr/bin/env bash
# test-resilient-1563-merge-pipeline-driver.sh — RESILIENT-1563.
#
# Proves the two halves of "exactly-one merge-mutation driver":
#   1. the shared merge-pipeline-driver.lock gives mutual exclusion — a second
#      driver CANNOT acquire the lock while a first holds it (the regression
#      AC: "double-driver cannot arm");
#   2. scripts/coord/merge-mutation-roster-lint.sh correctly PASSes at 0/1
#      enabled organs and FAILs at 2+ (using fixture manifests, never the
#      live organ-manifest.txt, so this test's verdict doesn't ride on
#      whatever the real node's current enablement happens to be);
#   3. every one of the four named merge-mutation organs sources the shared
#      lock lib (static wiring check — catches a future organ added without
#      the lock).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
LOCK_LIB="$REPO_ROOT/scripts/coord/lib/merge-pipeline-driver-lock.sh"
ROSTER_LINT="$REPO_ROOT/scripts/coord/merge-mutation-roster-lint.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-1563: merge-pipeline-driver lock + roster-lint ==="

[[ -f "$LOCK_LIB" ]] && ok "lock lib present" || { bad "missing $LOCK_LIB"; echo "$PASS ok / $FAIL fail"; exit 1; }
bash -n "$LOCK_LIB" && ok "lock lib bash -n clean" || bad "lock lib syntax error"
[[ -x "$ROSTER_LINT" ]] && ok "roster-lint executable" || bad "roster-lint not executable"
bash -n "$ROSTER_LINT" && ok "roster-lint bash -n clean" || bad "roster-lint syntax error"

# ── AC1/AC3: double-driver cannot arm — mutual exclusion on the real file ───
echo
echo "[mutual exclusion: second driver cannot acquire while first holds it]"
TMP="$(mktemp -d -t chump-rl1563-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export CHUMP_MERGE_PIPELINE_DRIVER_LOCK_DIR="$TMP"

# Driver A acquires and holds the lock for 2s in the background.
(
    source "$LOCK_LIB"
    if merge_pipeline_driver_lock_acquire 5; then
        echo "driver_a_acquired" > "$TMP/a.result"
        sleep 2
        merge_pipeline_driver_lock_release
    else
        echo "driver_a_failed" > "$TMP/a.result"
    fi
) &
A_PID=$!
sleep 0.3  # let driver A win the race

# Driver B tries immediately with a short wait — must be contended (fail fast).
(
    source "$LOCK_LIB"
    if merge_pipeline_driver_lock_acquire 1; then
        echo "driver_b_acquired" > "$TMP/b.result"
        merge_pipeline_driver_lock_release
    else
        echo "driver_b_contended" > "$TMP/b.result"
    fi
)
wait "$A_PID"

a_result="$(cat "$TMP/a.result" 2>/dev/null || echo missing)"
b_result="$(cat "$TMP/b.result" 2>/dev/null || echo missing)"
[[ "$a_result" == "driver_a_acquired" ]] && ok "driver A acquired the shared lock" || bad "driver A did not acquire (got: $a_result)"
[[ "$b_result" == "driver_b_contended" ]] && ok "driver B could NOT arm while A held the lock (double-driver cannot arm)" || bad "driver B should have been contended (got: $b_result)"

# After A releases (sleep 2 elapses), a fresh acquire must succeed again —
# proves this is mutual exclusion, not a permanently wedged lock.
(
    source "$LOCK_LIB"
    if merge_pipeline_driver_lock_acquire 5; then
        echo "driver_c_acquired" > "$TMP/c.result"
        merge_pipeline_driver_lock_release
    else
        echo "driver_c_failed" > "$TMP/c.result"
    fi
)
c_result="$(cat "$TMP/c.result" 2>/dev/null || echo missing)"
[[ "$c_result" == "driver_c_acquired" ]] && ok "lock released after holder exits — not permanently wedged" || bad "lock did not release (got: $c_result)"

unset CHUMP_MERGE_PIPELINE_DRIVER_LOCK_DIR

# ── AC2: roster-lint PASS at 0/1 enabled, FAIL at 2+ ────────────────────────
echo
echo "[roster-lint: 0/1 enabled organs passes]"
cat > "$TMP/manifest-zero.txt" <<'EOF'
disabled    chump-pr-shepherd.timer  role=brain
disabled    chump-merge-serializer.timer  role=brain
disabled    chump-armed-rebaser.timer  role=muscle
EOF
if CHUMP_ROSTER_LINT_KEEP_MERGEABLE_STATE=disabled bash "$ROSTER_LINT" --manifest "$TMP/manifest-zero.txt" >/dev/null 2>&1; then
    ok "0 enabled organs → exit 0"
else
    bad "0 enabled organs should exit 0"
fi

cat > "$TMP/manifest-one.txt" <<'EOF'
enabled     chump-pr-shepherd.timer  role=brain
disabled    chump-merge-serializer.timer  role=brain
disabled    chump-armed-rebaser.timer  role=muscle
EOF
if CHUMP_ROSTER_LINT_KEEP_MERGEABLE_STATE=disabled bash "$ROSTER_LINT" --manifest "$TMP/manifest-one.txt" >/dev/null 2>&1; then
    ok "1 enabled organ → exit 0"
else
    bad "1 enabled organ should exit 0"
fi

echo
echo "[roster-lint: 2+ enabled organs fails (the double-driver hazard)]"
cat > "$TMP/manifest-two.txt" <<'EOF'
enabled     chump-pr-shepherd.timer  role=brain
enabled     chump-merge-serializer.timer  role=brain
disabled    chump-armed-rebaser.timer  role=muscle
EOF
if CHUMP_ROSTER_LINT_KEEP_MERGEABLE_STATE=disabled bash "$ROSTER_LINT" --manifest "$TMP/manifest-two.txt" >/dev/null 2>&1; then
    bad "2 enabled organs should exit non-zero"
else
    ok "2 enabled organs (shepherd-with-merge + serializer) → exit 1"
fi

cat > "$TMP/manifest-four.txt" <<'EOF'
enabled     chump-pr-shepherd.timer  role=brain
enabled     chump-merge-serializer.timer  role=brain
enabled     chump-armed-rebaser.timer  role=muscle
EOF
if CHUMP_ROSTER_LINT_KEEP_MERGEABLE_STATE=enabled bash "$ROSTER_LINT" --manifest "$TMP/manifest-four.txt" >/dev/null 2>&1; then
    bad "4 enabled organs should exit non-zero"
else
    ok "all 4 organs enabled → exit 1 (worst case still caught)"
fi

echo
echo "[roster-lint --json shape]"
json_out="$(CHUMP_ROSTER_LINT_KEEP_MERGEABLE_STATE=disabled bash "$ROSTER_LINT" --manifest "$TMP/manifest-one.txt" --json 2>/dev/null)"
echo "$json_out" | grep -q '"enabled_count":1' && ok "json output reports enabled_count" || bad "json output missing enabled_count (got: $json_out)"

# ── AC1: every named merge-mutation organ sources the shared lock lib ───────
echo
echo "[every named merge-mutation organ wires the shared lock]"
for organ in \
    "scripts/coord/pr-shepherd-daemon.sh" \
    "scripts/coord/merge-serializer.sh" \
    "scripts/coord/armed-pr-rebaser.sh" \
    "scripts/coord/keep-mergeable-organ.sh" \
    "scripts/coord/bot-merge.sh"
do
    f="$REPO_ROOT/$organ"
    [[ -f "$f" ]] || { bad "missing organ: $organ"; continue; }
    if grep -q "merge-pipeline-driver" "$f"; then
        ok "$organ references merge-pipeline-driver(.lock/-lock.sh)"
    else
        bad "$organ does not reference the shared merge-pipeline-driver lock"
    fi
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
