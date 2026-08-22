#!/usr/bin/env bash
# scripts/ci/test-process-organ-heal.sh — INFRA-3650 (PEER-HEAL-03)
#
# Proves process-organ-heal.sh detects + respawns a dead process-organ with
# no human step, using a stubbed `pgrep` and a synthetic registry so the test
# is deterministic (no real background processes, no real ambient.jsonl).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HEAL="$REPO_ROOT/scripts/ops/process-organ-heal.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-process-organ-heal.sh (INFRA-3650) ==="

# ── 1. Source contract ───────────────────────────────────────────────────────
[[ -f "$HEAL" ]] || fail "heal script missing: $HEAL"
[[ -x "$HEAL" ]] || fail "heal script not executable: $HEAL"
bash -n "$HEAL" || fail "heal script bash -n failed"
[[ -f "$REPO_ROOT/scripts/ops/process-organ-registry.txt" ]] || fail "registry missing"
[[ -f "$REPO_ROOT/scripts/ops/almanac-vision-keeper.sh" ]] || fail "almanac-vision-keeper.sh missing"
grep -q '^almanac-vision-keeper|' "$REPO_ROOT/scripts/ops/process-organ-registry.txt" \
    || fail "almanac-vision-keeper not declared in process-organ-registry.txt (gap AC3)"
pass "scripts + registry present, syntax clean, almanac-vision-keeper declared"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A fake organ script under a fake repo root so respawn has something real
# to exec (writes a marker file so we can prove it actually ran).
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/scripts/ops"
FAKE_ORGAN_REL="scripts/ops/fake-organ.sh"
MARKER="$TMP/fake-organ-ran"
cat > "$FAKE_REPO/$FAKE_ORGAN_REL" <<EOF
#!/usr/bin/env bash
echo ran > "$MARKER"
EOF
chmod +x "$FAKE_REPO/$FAKE_ORGAN_REL"

REGISTRY="$TMP/registry.txt"
cat > "$REGISTRY" <<EOF
# test registry
fake-organ|$FAKE_ORGAN_REL
EOF

AMBIENT="$TMP/ambient.jsonl"

# ── 2. DOWN organ path: stub pgrep reports nothing running ─────────────────
PGREP_DOWN="$TMP/pgrep-down"
cat > "$PGREP_DOWN" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$PGREP_DOWN"

REPO_ROOT="$FAKE_REPO" \
CHUMP_PROCESS_ORGAN_REGISTRY="$REGISTRY" \
CHUMP_PROCESS_ORGAN_PGREP_BIN="$PGREP_DOWN" \
CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$HEAL" > "$TMP/out-down.log" 2>&1
rc=$?
[[ $rc -eq 0 ]] || fail "heal exited $rc on DOWN path (expected 0): $(cat "$TMP/out-down.log")"

# Respawned process runs async (nohup &) — give it a moment to write its marker.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f "$MARKER" ]] && break
    sleep 0.3
done
[[ -f "$MARKER" ]] || fail "fake-organ never ran — respawn did not fire"
pass "DOWN organ respawned (marker file written)"

grep -q '"kind":"process_organ_revived"' "$AMBIENT" || fail "process_organ_revived not emitted"
grep -q '"kind":"organ_watchdog_tick"' "$AMBIENT" || fail "organ_watchdog_tick heartbeat not emitted"
grep -q '"source":"process-organ-heal"' "$AMBIENT" || fail "organ_watchdog_tick missing source=process-organ-heal"
pass "ambient events present (process_organ_revived + organ_watchdog_tick)"

# ── 3. UP organ path: stub pgrep reports the organ IS running ──────────────
rm -f "$MARKER"
AMBIENT2="$TMP/ambient2.jsonl"
PGREP_UP="$TMP/pgrep-up"
cat > "$PGREP_UP" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$PGREP_UP"

REPO_ROOT="$FAKE_REPO" \
CHUMP_PROCESS_ORGAN_REGISTRY="$REGISTRY" \
CHUMP_PROCESS_ORGAN_PGREP_BIN="$PGREP_UP" \
CHUMP_AMBIENT_LOG="$AMBIENT2" \
    bash "$HEAL" > "$TMP/out-up.log" 2>&1
rc=$?
[[ $rc -eq 0 ]] || fail "heal exited $rc on UP path (expected 0)"
[[ -f "$MARKER" ]] && fail "fake-organ ran even though pgrep reported it UP (should not respawn)"
grep -q '"kind":"process_organ_revived"' "$AMBIENT2" && fail "process_organ_revived emitted on UP path (should not)"
grep -q '"kind":"organ_watchdog_tick"' "$AMBIENT2" || fail "organ_watchdog_tick heartbeat missing on UP path"
pass "UP organ left alone; heartbeat still emitted"

# ── 4. --dry-run never spawns ────────────────────────────────────────────────
rm -f "$MARKER"
AMBIENT3="$TMP/ambient3.jsonl"
REPO_ROOT="$FAKE_REPO" \
CHUMP_PROCESS_ORGAN_REGISTRY="$REGISTRY" \
CHUMP_PROCESS_ORGAN_PGREP_BIN="$PGREP_DOWN" \
CHUMP_AMBIENT_LOG="$AMBIENT3" \
    bash "$HEAL" --dry-run > "$TMP/out-dry.log" 2>&1
[[ -f "$MARKER" ]] && fail "--dry-run spawned the organ (should not)"
grep -q '"dry_run":1' "$AMBIENT3" || fail "dry-run tick did not report dry_run:1"
pass "--dry-run reports without spawning"

# ── 5. reaper heartbeat self-registration (AC2) ─────────────────────────────
grep -qE '^\s*process-organ-heal\)' "$REPO_ROOT/scripts/ops/reaper-heartbeat-watchdog.sh" \
    || fail "reaper-heartbeat-watchdog.sh has no process-organ-heal threshold case (AC2)"
grep -qE 'TARGETS=\(.*process-organ-heal' "$REPO_ROOT/scripts/ops/reaper-heartbeat-watchdog.sh" \
    || fail "process-organ-heal not in reaper-heartbeat-watchdog.sh's default TARGETS (AC2)"
pass "reaper-heartbeat-watchdog.sh grades process-organ-heal"

# ── 6. chump-node-install.sh wiring (AC1) ───────────────────────────────────
grep -q 'process-organ-heal' "$REPO_ROOT/scripts/setup/chump-node-install.sh" \
    || fail "process-organ-heal not wired into chump-node-install.sh (AC1)"
pass "chump-node-install.sh installs process-organ-heal"

echo "=== all process-organ-heal tests passed ==="
