#!/usr/bin/env bash
# test-wake-recovery.sh — RESILIENT-169
#
#  - wake-recovery.sh runs headlessly against a fixture repo and emits a
#    valid kind=wake_recovery line (auth_ok + kicked fields present)
#  - installer refuses to run from a temp path (RESILIENT-168 guard)
#  - chumpwake Swift source compiles (skipped when swiftc unavailable)
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "=== RESILIENT-169 wake-recovery test ==="

# ── 1. handler emits a valid event against a fixture repo ────────────────────
FIX="$(mktemp -d)"
mkdir -p "$FIX/.chump-locks" "$FIX/scripts/coord"
# fixture auth probe: always OK
cat > "$FIX/scripts/coord/auth-status.sh" <<'EOF'
#!/usr/bin/env bash
echo "AUTH ✓ OK — fixture"
EOF
chmod +x "$FIX/scripts/coord/auth-status.sh"

if CHUMP_REPO="$FIX" HOME="$FIX" bash "$REPO_ROOT/scripts/ops/wake-recovery.sh" >/dev/null 2>&1; then
    ok "wake-recovery.sh exits 0 on fixture repo"
else
    fail "wake-recovery.sh should exit 0 on fixture repo"
fi

line="$(grep '"kind":"wake_recovery"' "$FIX/.chump-locks/ambient.jsonl" 2>/dev/null | tail -1 || true)"
if [[ -n "$line" ]]; then
    ok "emits kind=wake_recovery to ambient.jsonl"
else
    fail "no wake_recovery event emitted"
fi

if printf '%s' "$line" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
assert d["kind"] == "wake_recovery"
assert isinstance(d["auth_ok"], bool)
assert "kicked" in d
' 2>/dev/null; then
    ok "event has valid JSON with auth_ok bool + kicked field"
else
    fail "event JSON invalid or missing required fields — got: $line"
fi

if printf '%s' "$line" | grep -q '"auth_ok":true'; then
    ok "fixture auth probe (OK) reflected as auth_ok=true"
else
    fail "auth_ok should be true with fixture OK probe"
fi
rm -rf "$FIX"

# ── 2. installer refuses temp paths ──────────────────────────────────────────
TMPCOPY="$(mktemp -d)/chump"
mkdir -p "$TMPCOPY/scripts/setup" "$TMPCOPY/tools/chumpwake"
cp "$REPO_ROOT/scripts/setup/install-wake-recovery.sh" "$TMPCOPY/scripts/setup/"
cp "$REPO_ROOT/tools/chumpwake/main.swift" "$TMPCOPY/tools/chumpwake/"
if bash "$TMPCOPY/scripts/setup/install-wake-recovery.sh" >/dev/null 2>&1; then
    fail "installer should refuse to run from a temp path"
else
    ok "installer refuses temp path (RESILIENT-168 guard)"
fi
rm -rf "$(dirname "$TMPCOPY")"

# ── 3. Swift source compiles ─────────────────────────────────────────────────
if command -v swiftc >/dev/null 2>&1 || xcrun -f swiftc >/dev/null 2>&1; then
    OUT="$(mktemp -d)/chumpwake"
    if xcrun swiftc -O -o "$OUT" "$REPO_ROOT/tools/chumpwake/main.swift" 2>/dev/null; then
        ok "chumpwake compiles with swiftc -O"
    else
        fail "chumpwake failed to compile"
    fi
    rm -rf "$(dirname "$OUT")"
else
    echo "  SKIP: swiftc unavailable — compile check skipped"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
