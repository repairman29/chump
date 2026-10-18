#!/usr/bin/env bash
# scripts/ci/test-resilient-1636-farmer-gate-ship-wall.sh — RESILIENT-1636
#
# The cuphead ship wall: on a paused Linux node, bot-merge's re-claim of work a
# dispatch already holds died at the farmer RED gate (stale ~/.chump/oauth-token.json
# mirror mtime + stale heartbeat), so every dispatch shipped only through salvage.
#
# This fixture reproduces that exact host state hermetically — a PAUSED farmer
# (node.env CHUMP_NODE_MODE=paused), a STALE heartbeat, a STALE oauth-token.json
# mirror, and a VALID ~/.claude credential (the path claude -p actually uses),
# in a non-login shell with no mirror refresher — and proves the invariant:
#
#   AC1  a gap whose dispatch ALREADY holds the claim is ADMITTED past the
#        farmer gate (bot-merge reaches the push step), proven by `chump claim`
#        printing the re-entry admission instead of refusing.
#   AC2  the gate is NOT weakened: a NEW claim (no live lease for that session)
#        is still refused, printing "no new claims admitted".
#   AC3  the farmer oauth check reads OK from the credential path claude -p uses
#        (valid ~/.claude/.credentials.json) even with a STALE mirror — the
#        mirror mtime is never consulted (RESILIENT-086, CREDIBLE-147).
#   AC(b) a paused farmer is reported PAUSED, not stale.
#   AC6  no automated caller uses --skip-farmer-gate (grep gate).
#
# Zero network. Pure local: chump binary + git + python3 (for mtime back-dating).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Resolve the binary the way the fast-checks steps do (precedent:
# test-resilient-1614-node-pause-invariant.sh) and build it when absent.
CHUMP_BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
if ! [ -x "$CHUMP_BIN" ]; then
    ( cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --quiet --bin chump ) \
        || fail "cargo build --bin chump failed"
fi
[ -x "$CHUMP_BIN" ] || fail "CHUMP_BIN not found or not executable: $CHUMP_BIN"

# Non-login Linux shell: no launchctl (Linux), stub it + systemctl empty so the
# exit-78 / node-pause supervisor scans stay hermetic on any runner.
STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/launchctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/systemctl"
chmod +x "$STUB/launchctl" "$STUB/systemctl"

# back-date a file's mtime by N seconds (portable).
backdate() { python3 -c "import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))" "$1" "$2"; }

# ── Build the cuphead ship-wall fixture ──────────────────────────────────────
REPO="$TMP/repo"; HOMEDIR="$TMP/home"; STATE="$TMP/state"
mkdir -p "$REPO/.chump" "$REPO/.chump-locks" "$HOMEDIR/.chump" "$HOMEDIR/.claude" "$STATE"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@e.com
git -C "$REPO" config user.name T
git -C "$REPO" commit -q --allow-empty -m init

# PAUSED farmer: node.env says paused (chump node pause's durable signal).
printf 'export CHUMP_NODE_MODE=paused\n' > "$STATE/node.env"
# STALE heartbeat: the farmer daemon is idle because it is paused.
printf 'x\n' > "$REPO/.chump/farmer-heartbeat"; backdate "$REPO/.chump/farmer-heartbeat" 80000
# STALE oauth-token.json mirror: the macOS-only refresher never ran on Linux.
printf '{"accessToken":"old"}\n' > "$HOMEDIR/.chump/oauth-token.json"; backdate "$HOMEDIR/.chump/oauth-token.json" 80000
# VALID ~/.claude credential: the path claude -p actually reads (future expiry).
printf '{"claudeAiOauth":{"accessToken":"sk-x","refreshToken":"rt","expiresAt":9999999999999}}\n' \
    > "$HOMEDIR/.claude/.credentials.json"

# Env a dispatch's bot-merge re-claim runs under on cuphead. CHUMP_REPO pins the
# repo root (wins over the chumpd socket), CHUMP_HOME feeds the oauth reads,
# CHUMP_STATE_DIR locates node.env. No API key / oauth-token env / auth cache.
run_chump() {
    env -i PATH="$STUB:/usr/bin:/bin" HOME="$HOMEDIR" \
        CHUMP_REPO="$REPO" CHUMP_HOME="$HOMEDIR" CHUMP_STATE_DIR="$STATE" \
        "$@"
}

# ── AC(b) + AC3: farmer status reports PAUSED, oauth reads OK ─────────────────
STATUS_JSON="$(run_chump "$CHUMP_BIN" farmer status --json 2>/dev/null)" || true
python3 - "$STATUS_JSON" <<'PY' || fail "farmer status did not report PAUSED + oauth_fresh"
import json,sys
s=json.loads(sys.argv[1])
assert s["paused"] is True, f"paused should be True: {s}"
assert s["green"] is False, f"green should be False (paused is not lights-on): {s}"
assert s["oauth_fresh"] is True, f"oauth_fresh should be True (valid ~/.claude creds, stale mirror ignored): {s}"
PY
ok "AC(b)/AC3: farmer status PAUSED, green=false, oauth_fresh=true (stale mirror ignored)"

# A paused farmer is reported PAUSED, not stale.
STATUS_TXT="$(run_chump "$CHUMP_BIN" farmer status 2>/dev/null)" || true
grep -q 'PAUSED' <<<"$STATUS_TXT" || fail "farmer status text should say PAUSED: $STATUS_TXT"
grep -qi 'paused by node mode' <<<"$STATUS_TXT" || fail "status should cite node-mode pause: $STATUS_TXT"
grep -qi 'heartbeat stale' <<<"$STATUS_TXT" && fail "paused farmer must NOT report 'heartbeat stale': $STATUS_TXT"
ok "AC(b): paused farmer reported PAUSED, not stale"

# ── AC1: re-entry of already-claimed work reaches the push step ──────────────
# The dispatch already holds the lease for GAP-RE-1 under session sess-A.
cat > "$REPO/.chump-locks/sess-A.json" <<'JSON'
{"session_id":"sess-A","gap_id":"GAP-RE-1","expires_at":"2999-01-01T00:00:00Z","paths":[]}
JSON
REENTRY_OUT="$(run_chump CHUMP_SESSION_ID=sess-A "$CHUMP_BIN" claim GAP-RE-1 --role bot-merge --skip-doctor --skip-import 2>&1)" || true
grep -qi 'admitting re-entry' <<<"$REENTRY_OUT" \
    || fail "re-entry claim was NOT admitted past the farmer gate: $REENTRY_OUT"
grep -qi 'no new claims admitted' <<<"$REENTRY_OUT" \
    && fail "re-entry claim was refused by the farmer gate (ship wall not fixed): $REENTRY_OUT"
ok "AC1: dispatch-held gap admitted past the farmer gate (bot-merge reaches push)"

# ── AC2: the gate is NOT weakened — a NEW claim is still refused ──────────────
# Same paused farmer, same session, but NO live lease for GAP-NEW-2.
NEW_OUT="$(run_chump CHUMP_SESSION_ID=sess-A "$CHUMP_BIN" claim GAP-NEW-2 --role worker --skip-doctor --skip-import 2>&1)"; NEW_RC=$?
grep -qi 'no new claims admitted' <<<"$NEW_OUT" \
    || fail "NEW claim should be refused by the farmer gate: $NEW_OUT"
grep -qi 'PAUSED' <<<"$NEW_OUT" || fail "refusal should name the PAUSED state: $NEW_OUT"
[ "$NEW_RC" -ne 0 ] || fail "NEW claim should exit non-zero when refused (rc=$NEW_RC)"
ok "AC2: NEW claim still refused under the paused farmer (gate not weakened)"

# A new claim with NO session at all is likewise refused.
NOSESS_OUT="$(run_chump "$CHUMP_BIN" claim GAP-RE-1 --role worker --skip-doctor --skip-import 2>&1)" || true
grep -qi 'no new claims admitted' <<<"$NOSESS_OUT" \
    || fail "claim with no CHUMP_SESSION_ID should be refused: $NOSESS_OUT"
ok "AC2: claim with no session is refused (no re-entry anchor)"

# ── AC3 (positive GREEN): valid creds + stale mirror ⇒ GREEN when not paused ─
REPO2="$TMP/repo2"; STATE2="$TMP/state2"
mkdir -p "$REPO2/.chump" "$REPO2/.chump-locks" "$STATE2"
git -C "$REPO2" init -q; git -C "$REPO2" config user.email t@e.com; git -C "$REPO2" config user.name T
git -C "$REPO2" commit -q --allow-empty -m init
printf 'export CHUMP_NODE_MODE=work-ready\n' > "$STATE2/node.env"
printf 'x\n' > "$REPO2/.chump/farmer-heartbeat"   # fresh heartbeat (not back-dated)
GREEN_RC=0
env -i PATH="$STUB:/usr/bin:/bin" HOME="$HOMEDIR" \
    CHUMP_REPO="$REPO2" CHUMP_HOME="$HOMEDIR" CHUMP_STATE_DIR="$STATE2" \
    "$CHUMP_BIN" farmer status --quiet >/dev/null 2>&1 || GREEN_RC=$?
[ "$GREEN_RC" -eq 0 ] || fail "farmer should be GREEN with valid creds + stale mirror + fresh heartbeat (rc=$GREEN_RC)"
ok "AC3: stale mirror + valid ~/.claude creds ⇒ farmer GREEN (mirror mtime never gates)"

# ── AC6: no automated caller uses --skip-farmer-gate ─────────────────────────
# Scan every scripts/ caller EXCEPT this fixture (which names the flag in its
# own doc + grep). Any surviving hit is a real automated bypass → fail.
AC6_HITS="$(grep -rIn -- '--skip-farmer-gate' "$REPO_ROOT/scripts" 2>/dev/null \
    | grep -v 'test-resilient-1636-farmer-gate-ship-wall.sh' || true)"
[ -z "$AC6_HITS" ] \
    || fail "an automated scripts/ caller uses --skip-farmer-gate (banned, RESILIENT-1636 AC6):
$AC6_HITS"
ok "AC6: no automated scripts/ caller uses --skip-farmer-gate"

echo ""
echo "All RESILIENT-1636 farmer-gate ship-wall tests passed!"
