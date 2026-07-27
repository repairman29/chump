#!/usr/bin/env bash
# test-opencode-harness-install.sh — EFFECTIVE-320 (born-wired)
#
# Proves install-opencode-harness.sh wires opencode.json's mcp.almanac
# correctly, idempotently, and without clobbering existing config — so a fresh
# machine is BORN with the opencode+Almanac harness instead of hand-assembled.
# Fully stubbed: no real opencode/almanac/network required (CI-portable).

set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/setup/install-opencode-harness.sh"

echo "=== EFFECTIVE-320 opencode-harness install smoke ==="; echo

[[ -x "$INSTALLER" ]] && ok "installer present + executable" || fail "installer missing/not executable"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub opencode CLI: `mcp list` reports almanac connected; everything else no-op.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "mcp" && "${2:-}" == "list" ]]; then
  echo "  ✓ almanac  connected"
fi
exit 0
STUB
chmod +x "$TMP/bin/opencode"

# Stub almanac-mcp binary + a fake index file.
touch "$TMP/almanac-mcp"; chmod +x "$TMP/almanac-mcp"
touch "$TMP/idx.db"

run_installer() {
    PATH="$TMP/bin:$PATH" \
    OPENCODE_CONFIG="$TMP/oc.json" \
    CHUMP_ALMANAC_MCP_BIN="$TMP/almanac-mcp" \
    CHUMP_ALMANAC_DB="$TMP/idx.db" \
    bash "$INSTALLER" >"$TMP/out.log" 2>&1
}

# ── 1. wires almanac into a fresh (seeded) config, preserving existing keys ──
printf '{"$schema":"https://opencode.ai/config.json","model":"x","provider":{"mlx":{"name":"keep"}}}\n' > "$TMP/oc.json"
if run_installer; then ok "installer exits 0"; else fail "installer exited non-zero"; fi

python3 - "$TMP/oc.json" <<'PY' && ok "mcp.almanac wired + existing config preserved" || fail "wiring/preserve check failed"
import json,sys
c=json.load(open(sys.argv[1]))
a=c.get("mcp",{}).get("almanac",{})
assert a.get("type")=="local", "type"
assert a.get("enabled") is True, "enabled"
assert isinstance(a.get("command"),list) and a["command"], "command"
assert a.get("environment",{}).get("ALMANAC_DB"), "ALMANAC_DB env"
assert c.get("provider",{}).get("mlx",{}).get("name")=="keep", "existing provider clobbered"
assert c.get("model")=="x", "existing model clobbered"
PY

# ── 2. idempotent ────────────────────────────────────────────────────────────
cp "$TMP/oc.json" "$TMP/before.json"
run_installer
if diff -q "$TMP/oc.json" "$TMP/before.json" >/dev/null; then ok "idempotent (no change on re-run)"; else fail "config changed on re-run"; fi

# ── 3. verify step sees the stub's 'connected' line ──────────────────────────
grep -qi 'almanac connected' "$TMP/out.log" && ok "verify step reports almanac connected" \
    || fail "verify step did not confirm connection"

# ── 4. skips cleanly when opencode CLI absent (opt-in harness) ───────────────
rm -f "$TMP/oc2.json"
if env -i HOME="$HOME" PATH="/usr/bin:/bin" OPENCODE_CONFIG="$TMP/oc2.json" \
     bash "$INSTALLER" >"$TMP/skip.log" 2>&1; then
    grep -qi 'opencode.*not' "$TMP/skip.log" && ok "skips cleanly (exit 0) when opencode absent" \
        || fail "opencode-absent path did not print the expected hint"
else
    fail "opencode-absent path should exit 0 (opt-in), not error"
fi

echo; echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
