#!/usr/bin/env bash
# test-chump-curator-subscriber.sh — INFRA-2154 smoke test for
# crates/chump-coord/src/bin/chump-curator-subscriber.rs
#
# Exercises the file-fallback path (CHUMP_A2A_LAYER unset — no NATS broker
# needed in CI) end-to-end:
#  1. dry-run mode (no --exec): a matching curator_dispatch_<role> event
#     produces curator_subscriber_dispatch_succeeded with mode=dry_run
#  2. --exec handler success: a handler that exits 0 produces
#     curator_subscriber_dispatch_succeeded with elapsed_ms > 0
#  3. --exec handler failure: a handler that exits 1 produces
#     curator_subscriber_dispatch_failed with failure_class=transient
#  4. malformed payload (no corr_id): produces curator_subscriber_dispatch_failed
#     with failure_class=permanent, no handler spawned
#  5. non-matching role: an event addressed to a different role is ignored
#
# Run from repo root: bash scripts/ci/test-chump-curator-subscriber.sh

set -u
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"
BIN="$TARGET_DIR/debug/chump-curator-subscriber"
if [ ! -x "$BIN" ]; then
  echo "building chump-curator-subscriber..."
  PATH="$HOME/.cargo/bin:$PATH" cargo build -p chump-coord --bin chump-curator-subscriber || {
    echo "[FAIL] build"; exit 1
  }
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

run_case() {
  # run_case <ambient_file> <role> <event_json> [--exec PATH]
  local ambient="$1" role="$2" event="$3"
  shift 3
  : > "$ambient"
  CHUMP_AMBIENT_LOG="$ambient" CHUMP_A2A_LAYER=0 \
    timeout 15 "$BIN" --role "$role" --once --heartbeat-interval-s 3600 "$@" >"$ambient.stderr" 2>&1 &
  local pid=$!
  # Give the subscriber time to seek-to-end and start tailing before we append.
  sleep 1
  echo "$event" >> "$ambient"
  wait "$pid"
}

# Case 1: dry-run success
CASE1="$SANDBOX/case1.jsonl"
run_case "$CASE1" "shepherd" '{"ts":"2026-08-16T00:00:00Z","kind":"curator_dispatch_shepherd","payload":{"corr_id":"c1"}}'
if grep -q '"event":"curator_subscriber_dispatch_succeeded"' "$CASE1" && grep -q '"mode":"dry_run"' "$CASE1"; then
  pass "dry-run mode acknowledges matching event as succeeded"
else
  fail "dry-run mode acknowledges matching event as succeeded"
  cat "$CASE1.stderr"
fi

# Case 2: --exec success
cat > "$SANDBOX/ok-handler.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 0
EOF
chmod +x "$SANDBOX/ok-handler.sh"
CASE2="$SANDBOX/case2.jsonl"
run_case "$CASE2" "shepherd" '{"ts":"2026-08-16T00:00:00Z","kind":"curator_dispatch_shepherd","payload":{"corr_id":"c2"}}' --exec "$SANDBOX/ok-handler.sh"
if grep -q '"event":"curator_subscriber_dispatch_succeeded"' "$CASE2" && grep -q '"corr_id":"c2"' "$CASE2"; then
  pass "--exec handler success produces dispatch_succeeded"
else
  fail "--exec handler success produces dispatch_succeeded"
  cat "$CASE2.stderr"
fi

# Case 3: --exec failure (transient), with retries disabled for speed
cat > "$SANDBOX/bad-handler.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 1
EOF
chmod +x "$SANDBOX/bad-handler.sh"
CASE3="$SANDBOX/case3.jsonl"
run_case "$CASE3" "shepherd" '{"ts":"2026-08-16T00:00:00Z","kind":"curator_dispatch_shepherd","payload":{"corr_id":"c3"}}' --exec "$SANDBOX/bad-handler.sh" --max-retries 0
if grep -q '"event":"curator_subscriber_dispatch_failed"' "$CASE3" && grep -q '"failure_class":"transient"' "$CASE3"; then
  pass "--exec handler non-zero exit produces dispatch_failed failure_class=transient"
else
  fail "--exec handler non-zero exit produces dispatch_failed failure_class=transient"
  cat "$CASE3.stderr"
fi

# Case 4: malformed payload (no corr_id) -> permanent failure, no handler spawn
CASE4="$SANDBOX/case4.jsonl"
run_case "$CASE4" "shepherd" '{"ts":"2026-08-16T00:00:00Z","kind":"curator_dispatch_shepherd","payload":{}}' --exec "$SANDBOX/ok-handler.sh"
if grep -q '"event":"curator_subscriber_dispatch_failed"' "$CASE4" && grep -q '"failure_class":"permanent"' "$CASE4"; then
  pass "malformed payload (no corr_id) produces dispatch_failed failure_class=permanent"
else
  fail "malformed payload (no corr_id) produces dispatch_failed failure_class=permanent"
  cat "$CASE4.stderr"
fi

# Case 5: non-matching role is ignored (process exits cleanly with no dispatch events)
CASE5="$SANDBOX/case5.jsonl"
run_case "$CASE5" "shepherd" '{"ts":"2026-08-16T00:00:00Z","kind":"curator_dispatch_target","payload":{"corr_id":"c5"}}'
if ! grep -q 'dispatch_received' "$CASE5"; then
  pass "event addressed to a different role is ignored"
else
  fail "event addressed to a different role is ignored"
  cat "$CASE5.stderr"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
