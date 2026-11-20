#!/usr/bin/env bash
# scripts/ci/test-node-orchestrator-cargo-jobs-cap.sh — INFRA-3659
#
# Proves node-orchestrator.sh caps AGGREGATE cargo/rustc parallelism
# (worker_count * CARGO_BUILD_JOBS) to this host's core count:
#   1. cargo_jobs_cap() = floor(CORES / effective_max()), floored at 1.
#   2. enforce_cargo_jobs() writes a managed [build] jobs block into the
#      target cargo config, idempotently (no rewrite when unchanged).
#   3. enforce_cargo_jobs() refuses to touch a file with a pre-existing,
#      unmanaged [build] section rather than clobbering unknown config.
#   4. A changed cap value updates the managed block in place while
#      preserving surrounding, unrelated config content.
#
# Sources the script (guarded so the daemon while-loop only runs when
# executed directly) — no real systemd/cargo calls.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCH="$REPO_ROOT/scripts/ops/node-orchestrator.sh"

[[ -f "$ORCH" ]] || { echo "[FAIL] $ORCH not found"; exit 1; }

echo "=== INFRA-3659 node-orchestrator cargo-jobs aggregate-concurrency cap ==="

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

STATE_DIR_TEST="$TMPDIR_TEST/state"
AMBIENT_TEST="$TMPDIR_TEST/ambient.jsonl"
mkdir -p "$STATE_DIR_TEST"

FAKE_BIN="$TMPDIR_TEST/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/systemctl"
cat > "$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$FAKE_BIN/sudo"
export PATH="$FAKE_BIN:$PATH"

CHUMP_STATE_DIR="$STATE_DIR_TEST" CHUMP_AMBIENT_LOG="$AMBIENT_TEST" \
  source "$ORCH" 2>/dev/null || true

for fn in cargo_jobs_cap enforce_cargo_jobs; do
  if declare -f "$fn" >/dev/null 2>&1; then
    ok "orchestrator defines $fn (sourced without running daemon loop)"
  else
    fail "orchestrator missing $fn or daemon loop ran during source"
  fi
done

# ── 1. cargo_jobs_cap() = floor(CORES / effective_max()), floored at 1 ─────
CORES=4
WORKER_MAX=0   # effective_max() -> CORES-1 = 3 -> 4/3 -> 1
if [ "$(cargo_jobs_cap)" = "1" ]; then
  ok "cargo_jobs_cap floors at 1 on a 4-core box with auto worker max (CJ incident shape)"
else
  fail "cargo_jobs_cap expected 1, got $(cargo_jobs_cap)"
fi

CORES=16
WORKER_MAX=4   # 16/4 = 4
if [ "$(cargo_jobs_cap)" = "4" ]; then
  ok "cargo_jobs_cap scales up per-worker jobs on a bigger box with a smaller worker cap"
else
  fail "cargo_jobs_cap expected 4, got $(cargo_jobs_cap)"
fi

# ── 2. enforce_cargo_jobs() writes a managed block, idempotently ───────────
CARGO_CONFIG="$TMPDIR_TEST/config.toml"
STATE_DIR="$STATE_DIR_TEST"
CORES=4; WORKER_MAX=0
enforce_cargo_jobs
if grep -q "BEGIN CHUMP-MANAGED cargo-jobs-cap" "$CARGO_CONFIG" 2>/dev/null && grep -q "jobs = 1" "$CARGO_CONFIG" 2>/dev/null; then
  ok "enforce_cargo_jobs writes a managed [build] jobs block"
else
  fail "enforce_cargo_jobs did not write the expected managed block: $(cat "$CARGO_CONFIG" 2>/dev/null)"
fi

_mtime_before=$(stat -c %Y "$CARGO_CONFIG" 2>/dev/null || stat -f %m "$CARGO_CONFIG")
sleep 1.1
enforce_cargo_jobs
_mtime_after=$(stat -c %Y "$CARGO_CONFIG" 2>/dev/null || stat -f %m "$CARGO_CONFIG")
if [ "$_mtime_before" = "$_mtime_after" ]; then
  ok "enforce_cargo_jobs is a no-op (no rewrite) when the computed cap hasn't changed"
else
  fail "enforce_cargo_jobs rewrote the file despite an unchanged cap"
fi

# ── 3. refuses to touch a pre-existing unmanaged [build] section ───────────
CARGO_CONFIG_UNMANAGED="$TMPDIR_TEST/config-unmanaged.toml"
cat > "$CARGO_CONFIG_UNMANAGED" <<'EOF'
[build]
rustc-wrapper = "sccache"
EOF
CARGO_CONFIG="$CARGO_CONFIG_UNMANAGED"
rm -f "$STATE_DIR_TEST/.orch-cargo-jobs"
enforce_cargo_jobs
if grep -q 'rustc-wrapper = "sccache"' "$CARGO_CONFIG_UNMANAGED" && ! grep -q "CHUMP-MANAGED" "$CARGO_CONFIG_UNMANAGED"; then
  ok "enforce_cargo_jobs leaves a pre-existing unmanaged [build] section untouched"
else
  fail "enforce_cargo_jobs clobbered an unmanaged [build] section: $(cat "$CARGO_CONFIG_UNMANAGED")"
fi

# ── 4. a changed cap updates the block in place, preserving other content ──
CARGO_CONFIG="$TMPDIR_TEST/config-update.toml"
cat > "$CARGO_CONFIG" <<'EOF'
[registries.crates-io]
protocol = "sparse"
EOF
STATE_DIR="$TMPDIR_TEST/state2"; mkdir -p "$STATE_DIR"
CORES=4; WORKER_MAX=0
enforce_cargo_jobs
CORES=16; WORKER_MAX=4   # cap changes 1 -> 4
enforce_cargo_jobs
if grep -q "jobs = 4" "$CARGO_CONFIG" && ! grep -q "jobs = 1" "$CARGO_CONFIG" && grep -q 'protocol = "sparse"' "$CARGO_CONFIG"; then
  ok "enforce_cargo_jobs updates the managed block in place on a changed cap, preserving unrelated config"
else
  fail "enforce_cargo_jobs did not correctly update in place: $(cat "$CARGO_CONFIG")"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILS[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
