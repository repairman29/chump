#!/usr/bin/env bash
# test-claude-reaper.sh — INFRA-1662
# Validates the orphan-claude-subprocess reaper:
#   - script exists + executable + bash syntax clean
#   - plist exists + references the script
#   - CHUMP_REAPER_DISABLED bypass is honored
#   - foreground-PID protection (ppid-chain walk) logic is present
#   - synthetic ps fixture: orphans flagged, legitimate-chain skipped
#   - emits kind=orphan_subprocess_reaped event
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REAPER="$REPO_ROOT/scripts/ops/reap-orphan-claude-procs.sh"
PLIST="$REPO_ROOT/launchd/com.chump.claude-reaper.plist"
INSTALL="$REPO_ROOT/scripts/setup/install-claude-reaper.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-claude-reaper.sh (INFRA-1662) ==="

# ── 1. Script presence + executable ──────────────────────────────────────────
echo "--- 1: script exists + executable ---"
[[ -f "$REAPER" ]] || fail "reaper script missing: $REAPER"
[[ -x "$REAPER" ]] || fail "reaper script not executable: $REAPER"
pass "reaper script present + executable"

# ── 2. bash syntax ───────────────────────────────────────────────────────────
echo "--- 2: bash syntax clean ---"
bash -n "$REAPER" || fail "reaper bash -n failed"
bash -n "$INSTALL" || fail "install bash -n failed"
pass "bash -n clean (reaper + installer)"

# ── 3. plist present + references the script ────────────────────────────────
echo "--- 3: plist references script ---"
[[ -f "$PLIST" ]] || fail "plist missing: $PLIST"
grep -q "reap-orphan-claude-procs.sh" "$PLIST" \
    || fail "plist does not reference reap-orphan-claude-procs.sh"
grep -q "com.chump.claude-reaper" "$PLIST" \
    || fail "plist missing expected Label com.chump.claude-reaper"
pass "plist present + references reaper script"

# ── 4. CHUMP_REAPER_DISABLED bypass ──────────────────────────────────────────
echo "--- 4: CHUMP_REAPER_DISABLED bypass ---"
TMP_AMB="$(mktemp)"
trap 'rm -f "$TMP_AMB" "$TMP_AMB.before"' EXIT
: > "$TMP_AMB"
out="$(CHUMP_REAPER_DISABLED=1 CHUMP_AMBIENT_LOG="$TMP_AMB" "$REAPER" 2>&1)"
echo "$out" | grep -q "CHUMP_REAPER_DISABLED" \
    || fail "bypass did not log expected message; got: $out"
[[ ! -s "$TMP_AMB" ]] \
    || fail "bypass should not write to ambient.jsonl; got: $(cat "$TMP_AMB")"
pass "CHUMP_REAPER_DISABLED=1 short-circuits cleanly"

# ── 5. Foreground-PID / ppid-chain logic present in source ───────────────────
echo "--- 5: foreground-pid protection (ppid-chain walk) present ---"
grep -q "chain_reaches_fg\|ppid chain\|FG_PID" "$REAPER" \
    || fail "no ppid-chain / FG_PID guard found in reaper"
grep -q "Claude\.app" "$REAPER" \
    || fail "no Claude.app foreground reference (won't know what to protect)"
pass "ppid-chain walk + Claude.app foreground reference present"

# ── 6. Synthetic ps fixture: orphans vs. legitimate-chain ────────────────────
# We use the CHUMP_REAPER_PS_BIN override to stub ps. The fake ps prints a
# fixed table:
#
#   PID  PPID   ETIME      RSS   COMMAND
#   1000  900   00:00      4096  /Applications/Claude.app/Contents/MacOS/Claude   <- foreground
#   1001 1000   02:00      8192  /Users/x/Library/.../claude-code/2.1.138/claude.app/Contents/MacOS/claude --output-format stream-json   <- legitimate (child of fg)
#   2001    1   02-00:00   16384 /Users/x/Library/.../claude-code/2.1.138/claude.app/Contents/MacOS/claude --output-format stream-json   <- orphan, 2 days old
#   2002    1   05:00      8192  /Users/x/Library/.../claude-code/2.1.138/claude.app/Contents/MacOS/claude --output-format stream-json   <- orphan but YOUNG (5 min, < 1h)
#   2003    1   01:30:00   32768 /Users/x/Library/.../claude-code/2.1.138/claude.app/Contents/MacOS/claude --output-format stream-json   <- orphan, 1.5h old
#
# Expected with REAP_AGE=3600 and DRY_RUN=1:
#   - 2001 and 2003 flagged (orphan AND etime>=3600)
#   - 1001 skipped (chain reaches foreground)
#   - 2002 skipped (orphan but too young)
echo "--- 6: synthetic ps fixture identifies the right orphans ---"
FAKE_PS_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_AMB" "$TMP_AMB.before" "$FAKE_PS_DIR"' EXIT

cat > "$FAKE_PS_DIR/ps" <<'FAKE_PS'
#!/usr/bin/env bash
# Stub ps for INFRA-1662 reaper test. Honors the exact `ps -A -o ...` call
# and any `pgrep` will fail-through to a real pgrep (we are only shimming ps).
cat <<'TBL'
 1000   900 00:00 4096 /Applications/Claude.app/Contents/MacOS/Claude
 1001 1000 02:00 8192 /Users/x/Library/Application Support/Claude/claude-code/2.1.138/claude.app/Contents/MacOS/claude --output-format stream-json
 2001    1 02-00:00:00 16384 /Users/x/Library/Application Support/Claude/claude-code/2.1.138/claude.app/Contents/MacOS/claude --output-format stream-json
 2002    1 05:00 8192 /Users/x/Library/Application Support/Claude/claude-code/2.1.138/claude.app/Contents/MacOS/claude --output-format stream-json
 2003    1 01:30:00 32768 /Users/x/Library/Application Support/Claude/claude-code/2.1.138/claude.app/Contents/MacOS/claude --output-format stream-json
TBL
FAKE_PS

chmod +x "$FAKE_PS_DIR/ps"

# Stub pgrep so FG_PID=1000 deterministically (real pgrep would not see our
# stubbed PIDs).
cat > "$FAKE_PS_DIR/pgrep" <<'FAKE_PG'
#!/usr/bin/env bash
# Stub pgrep — return PID 1000 when asked for the foreground Claude.app.
for arg in "$@"; do
    case "$arg" in
        *Claude.app/Contents/MacOS/Claude*) echo 1000; exit 0 ;;
    esac
done
exit 1
FAKE_PG
chmod +x "$FAKE_PS_DIR/pgrep"

: > "$TMP_AMB"
out="$(
    PATH="$FAKE_PS_DIR:$PATH" \
    CHUMP_REAPER_PS_BIN="$FAKE_PS_DIR/ps" \
    CHUMP_REAPER_DRY_RUN=1 \
    CHUMP_AMBIENT_LOG="$TMP_AMB" \
    REAP_AGE=3600 \
    "$REAPER" 2>&1
)"
echo "$out" | sed 's/^/    /'

# Verify the script reports candidates=4, orphans=2, killed=2 (dry-run).
echo "$out" | grep -qE "candidates=4 orphans=2 killed=2" \
    || fail "expected candidates=4 orphans=2 killed=2; got: $out"
pass "synthetic fixture: 4 candidates → 2 orphans → 2 reaped (DRY_RUN)"

# Verify pids 2001 and 2003 appear in DRY-RUN log lines, but NOT 1001 / 2002.
echo "$out" | grep -q "DRY-RUN would SIGKILL pid=2001" || fail "expected pid 2001 to be flagged"
echo "$out" | grep -q "DRY-RUN would SIGKILL pid=2003" || fail "expected pid 2003 to be flagged"
echo "$out" | grep -q "DRY-RUN would SIGKILL pid=1001" \
    && fail "pid 1001 should be protected (ppid chain reaches FG)"
echo "$out" | grep -q "DRY-RUN would SIGKILL pid=2002" \
    && fail "pid 2002 should be skipped (etime < REAP_AGE)"
pass "correct PIDs flagged (orphans 2001+2003) and protected (legit 1001, young 2002)"

# ── 7. Ambient event emitted ────────────────────────────────────────────────
echo "--- 7: emits orphan_subprocess_reaped event ---"
grep -q '"kind":"orphan_subprocess_reaped"' "$TMP_AMB" \
    || fail "ambient.jsonl missing orphan_subprocess_reaped event; got: $(cat "$TMP_AMB")"
grep -q '"count":2' "$TMP_AMB" \
    || fail "expected count=2 in emitted event; got: $(cat "$TMP_AMB")"
grep -q '"oldest_etime_secs":172800' "$TMP_AMB" \
    || fail "expected oldest_etime_secs=172800 (2 days); got: $(cat "$TMP_AMB")"
pass "ambient event emitted with correct fields"

echo
echo "=== test-claude-reaper.sh PASS ==="
