#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-chump-fleet-daemon.sh — INFRA-964
#
# Asserts `chump fleet daemon --once`:
#   1. runs each declared task once and exits 0
#   2. emits a kind=daemon_started event with the task list
#   3. emits one kind=daemon_tick per task with required fields
#   4. each daemon_tick has exit_code + elapsed_ms fields
#
# Builds chump from the worktree to ensure the test exercises this PR's
# binary, not whatever's on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

# Build the binary if we don't already have one.
CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -x "$CHUMP_BIN" ]]; then
  echo "[test] building chump …"
  ( cd "$REPO_ROOT" && cargo build --bin chump --quiet ) || fail "cargo build failed"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"
AMB="$LOCK_DIR/ambient.jsonl"

# The daemon resolves .chump-locks via repo_path::repo_root(); for the test
# we redirect by changing CWD to a fake repo that has the YAML symlinked in.
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/scripts/coord" "$FAKE_REPO/.chump-locks"
ln -sf "$REPO_ROOT/scripts/coord/system-gap-frequencies.yaml" \
  "$FAKE_REPO/scripts/coord/system-gap-frequencies.yaml"
# Provide minimal stubs for the scripts the YAML names — each prints OK + exits 0.
for s in opus-curator.sh emergency-fast-path.sh; do
  cat > "$FAKE_REPO/scripts/coord/$s" <<'EOF'
#!/usr/bin/env bash
echo "stub: $0 ran"
exit 0
EOF
  chmod +x "$FAKE_REPO/scripts/coord/$s"
done

# Run the daemon in --once mode from the fake repo.
( cd "$FAKE_REPO" && "$CHUMP_BIN" fleet daemon --once ) || fail "daemon --once exited non-zero"
ok "daemon --once exits 0"

# Ambient should now contain daemon_started + one daemon_tick per task.
AMB_FAKE="$FAKE_REPO/.chump-locks/ambient.jsonl"
[[ -s "$AMB_FAKE" ]] || fail "ambient.jsonl was not written"

grep -q '"kind":"daemon_started"' "$AMB_FAKE" \
  || fail "daemon_started event not emitted"
ok "daemon_started emitted"

# Count daemon_tick events; we expect at least 2 (curator + fast-path).
tick_count=$(grep -c '"kind":"daemon_tick"' "$AMB_FAKE" || true)
[[ "$tick_count" -ge 2 ]] \
  || fail "expected ≥2 daemon_tick events, got $tick_count"
ok "got $tick_count daemon_tick events (≥2)"

# Each tick line must have exit_code + elapsed_ms + task + run_id.
while IFS= read -r line; do
  for field in '"exit_code":' '"elapsed_ms":' '"task":' '"run_id":'; do
    echo "$line" | grep -q "$field" \
      || fail "daemon_tick missing $field — line: $line"
  done
done < <(grep '"kind":"daemon_tick"' "$AMB_FAKE")
ok "every daemon_tick has exit_code + elapsed_ms + task + run_id"

# A tick whose stub script exits 0 should record exit_code:0.
grep -q '"exit_code":0' "$AMB_FAKE" \
  || fail "no daemon_tick with exit_code:0 — stubs were supposed to succeed"
ok "successful tick records exit_code:0"

echo
echo "=== test-chump-fleet-daemon.sh PASSED ==="
