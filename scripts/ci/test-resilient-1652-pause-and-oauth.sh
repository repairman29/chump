#!/usr/bin/env bash
# scripts/ci/test-resilient-1652-pause-and-oauth.sh — RESILIENT-1652 / RESILIENT-1653
#
# The cuphead ship wall, second cut (PHASE-R R1/R6). After #5601 (RESILIENT-1636)
# the paused node STILL could not ship because:
#   (1) cuphead expressed its pause as the LEGACY form (node.env
#       CHUMP_NODE_MODE=control-plane + CHUMP_NODE_WORK_ENABLED=0, set before the
#       pause verb existed) which the farmer gate did not recognise as paused —
#       so a dispatch-held re-claim was refused as RED, not admitted; and
#   (2) `check_oauth_fresh` read `<CHUMP_HOME>/.claude/.credentials.json` while
#       `claude -p` reads `<HOME>/.claude/.credentials.json`; on a node whose
#       node.env exports CHUMP_HOME≠HOME the creds were never found, the check
#       fell through to the stale mirror mtime and reported oauth_fresh=false
#       although `claude -p` authenticated fine.
#
# Also pins the RESILIENT-1653 pause-verb hardening:
#   (3) `chump node pause|resume --help` and `--dry-run` make ZERO writes;
#   (4) an unknown flag is a usage error (exit 2), NEVER a pause with a default
#       reason;
#   (5) node pause WRITES the node pause sentinel `<state_dir>/.chump/fleet-paused`
#       (carrying REASON=), resume REMOVES it, and pause NEVER writes the
#       `<repo>/.chump/fleet-paused` kill switch (it would wall re-entry) nor the
#       old doubled `.chump/.chump` path.
#
# Zero network. Pure local: chump binary + git + python3.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Resolve + build the branch binary (precedent: test-resilient-1636…).
CHUMP_BIN_DEFAULT="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
CHUMP_BIN="${CHUMP_BIN:-$CHUMP_BIN_DEFAULT}"
if [ "$CHUMP_BIN" = "$CHUMP_BIN_DEFAULT" ]; then
    ( cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --quiet --bin chump ) \
        || fail "cargo build --bin chump failed"
fi
[ -x "$CHUMP_BIN" ] || fail "CHUMP_BIN not found or not executable: $CHUMP_BIN"

# Stub launchctl/systemctl empty so pause's two-scope scan stays hermetic.
STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/launchctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/systemctl"
chmod +x "$STUB/launchctl" "$STUB/systemctl"

backdate() { python3 -c "import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))" "$1" "$2"; }

# ── (1) legacy control-plane + WORK_ENABLED=0 reads as PAUSED, admits re-entry ─
REPO="$TMP/repo"; HOMEDIR="$TMP/home"; STATE="$TMP/state"; CHOME="$TMP/chome"
mkdir -p "$REPO/.chump" "$REPO/.chump-locks" "$HOMEDIR/.claude" "$STATE" "$CHOME/.chump"
git -C "$REPO" init -q; git -C "$REPO" config user.email t@e.com; git -C "$REPO" config user.name T
git -C "$REPO" commit -q --allow-empty -m init

# cuphead's legacy pause form (NOT the verb, NO CHUMP_NODE_MODE=paused line).
printf 'export CHUMP_NODE_MODE=control-plane\nexport CHUMP_NODE_WORK_ENABLED=0\n' > "$STATE/node.env"
printf 'x\n' > "$REPO/.chump/farmer-heartbeat"; backdate "$REPO/.chump/farmer-heartbeat" 80000
# VALID creds under HOME/.claude (the path claude -p reads), stale mirror under CHUMP_HOME.
printf '{"claudeAiOauth":{"accessToken":"sk-x","refreshToken":"rt","expiresAt":9999999999999}}\n' \
    > "$HOMEDIR/.claude/.credentials.json"
printf '{"accessToken":"old"}\n' > "$CHOME/.chump/oauth-token.json"; backdate "$CHOME/.chump/oauth-token.json" 80000

run_chump() {
    env -i PATH="$STUB:/usr/bin:/bin" HOME="$HOMEDIR" \
        CHUMP_REPO="$REPO" CHUMP_HOME="$CHOME" CHUMP_STATE_DIR="$STATE" \
        "$@"
}

STATUS_JSON="$(run_chump "$CHUMP_BIN" farmer status --json 2>/dev/null)" || true
python3 - "$STATUS_JSON" <<'PY' || fail "farmer status did not report PAUSED + oauth_fresh for the legacy form"
import json,sys
s=json.loads(sys.argv[1])
assert s["paused"] is True, f"legacy control-plane+WORK_ENABLED=0 must read PAUSED: {s}"
assert s["oauth_fresh"] is True, f"oauth_fresh must be True from HOME/.claude creds (CHUMP_HOME≠HOME): {s}"
assert s["green"] is False, f"paused is not lights-on: {s}"
PY
ok "(1) legacy control-plane+WORK_ENABLED=0 reads PAUSED; (2) oauth_fresh from HOME/.claude (CHUMP_HOME≠HOME)"

# The dispatch already holds the lease for the gap → re-entry admitted past the gate.
cat > "$REPO/.chump-locks/sess-A.json" <<'JSON'
{"session_id":"sess-A","gap_id":"GAP-RE-1","expires_at":"2999-01-01T00:00:00Z","paths":[]}
JSON
REENTRY_OUT="$(run_chump CHUMP_SESSION_ID=sess-A "$CHUMP_BIN" claim GAP-RE-1 --role bot-merge --skip-doctor --skip-import 2>&1)" || true
grep -qi 'admitting re-entry' <<<"$REENTRY_OUT" \
    || fail "legacy-paused node must admit dispatch-held re-entry (ship-wall not fixed): $REENTRY_OUT"
grep -qi 'no new claims admitted' <<<"$REENTRY_OUT" \
    && fail "legacy-paused re-entry was refused: $REENTRY_OUT"
ok "(1) legacy-paused node admits dispatch-held bot-merge re-entry (cuphead ships)"

# A NEW claim (no live lease) is still refused — the gate is not weakened.
NEW_OUT="$(run_chump CHUMP_SESSION_ID=sess-A "$CHUMP_BIN" claim GAP-NEW-9 --role fleet-worker --skip-doctor --skip-import 2>&1)"; NEW_RC=$?
grep -qi 'no new claims admitted' <<<"$NEW_OUT" || fail "NEW claim must still be refused on a legacy-paused node: $NEW_OUT"
[ "$NEW_RC" -ne 0 ] || fail "NEW claim should exit non-zero (rc=$NEW_RC)"
ok "(6) gate not loosened: NEW claim still refused on a legacy-paused node"

# ── (2) negative: expired, unrefreshable HOME/.claude creds ⇒ NOT GREEN ───────
HOME2="$TMP/home2"; REPO2="$TMP/repo2"; STATE2="$TMP/state2"; CHOME2="$TMP/chome2"
mkdir -p "$HOME2/.claude" "$REPO2/.chump" "$STATE2" "$CHOME2/.chump"
git -C "$REPO2" init -q; git -C "$REPO2" config user.email t@e.com; git -C "$REPO2" config user.name T
git -C "$REPO2" commit -q --allow-empty -m init
printf 'CHUMP_NODE_MODE=work-ready\n' > "$STATE2/node.env"
printf 'x\n' > "$REPO2/.chump/farmer-heartbeat"
printf '{"claudeAiOauth":{"accessToken":"sk-x","expiresAt":1}}\n' > "$HOME2/.claude/.credentials.json"
EXP_RC=0
env -i PATH="$STUB:/usr/bin:/bin" HOME="$HOME2" \
    CHUMP_REPO="$REPO2" CHUMP_HOME="$CHOME2" CHUMP_STATE_DIR="$STATE2" \
    "$CHUMP_BIN" farmer status --quiet >/dev/null 2>&1 || EXP_RC=$?
[ "$EXP_RC" -ne 0 ] || fail "expired non-refreshable HOME/.claude creds must NOT be GREEN (rc=$EXP_RC)"
ok "(2) expired unrefreshable HOME/.claude creds ⇒ NOT GREEN (dead credential still reds)"

# ── (3)+(4)+(5) pause verb: --help / --dry-run zero-write; unknown flag exit 2 ─
VREPO="$TMP/vrepo"; VSTATE="$TMP/vstate"
mkdir -p "$VREPO/.chump" "$VSTATE"
git -C "$VREPO" init -q; git -C "$VREPO" config user.email t@e.com; git -C "$VREPO" config user.name T
git -C "$VREPO" commit -q --allow-empty -m init
printf 'export CHUMP_NODE_MODE=work-ready\nexport CHUMP_RUN_USER=ubuntu\n' > "$VSTATE/node.env"
NE_BEFORE="$(cat "$VSTATE/node.env")"

run_verb() {
    env -i PATH="$STUB:/usr/bin:/bin" HOME="$TMP/vhome" \
        CHUMP_REPO="$VREPO" CHUMP_STATE_DIR="$VSTATE" "$CHUMP_BIN" "$@"
}
assert_node_env_unchanged() {
    [ "$(cat "$VSTATE/node.env")" = "$NE_BEFORE" ] || fail "$1: node.env changed (must be byte-unchanged)"
    [ ! -e "$VREPO/.chump/fleet-paused" ] || fail "$1: fleet-paused sentinel written (must be absent)"
    [ ! -e "$VSTATE/.chump/fleet-paused" ] || fail "$1: state-dir sentinel written (must be absent)"
}

for sub in pause resume; do
    run_verb node "$sub" --help >/dev/null 2>&1 || fail "node $sub --help should exit 0"
    assert_node_env_unchanged "node $sub --help"
    run_verb node "$sub" --dry-run >/dev/null 2>&1 || fail "node $sub --dry-run should exit 0"
    assert_node_env_unchanged "node $sub --dry-run"
done
ok "(3) node pause|resume --help and --dry-run make ZERO writes (node.env + sentinel byte-unchanged)"

# Unknown flag ⇒ usage error exit 2, NEVER a pause-with-default-reason.
run_verb node pause --frobnicate >/dev/null 2>&1; UP_RC=$?
[ "$UP_RC" -eq 2 ] || fail "node pause --frobnicate must exit 2 (got $UP_RC)"
assert_node_env_unchanged "node pause --frobnicate"
run_verb node resume --frobnicate >/dev/null 2>&1; UR_RC=$?
[ "$UR_RC" -eq 2 ] || fail "node resume --frobnicate must exit 2 (got $UR_RC)"
assert_node_env_unchanged "node resume --frobnicate"
# --reason with no value ⇒ usage error, not a pause.
run_verb node pause --reason >/dev/null 2>&1; RV_RC=$?
[ "$RV_RC" -eq 2 ] || fail "node pause --reason (no value) must exit 2 (got $RV_RC)"
assert_node_env_unchanged "node pause --reason (no value)"
ok "(4) unknown flag / --reason-without-value ⇒ usage error exit 2 (never a default-reason pause)"

# ── (5) a real pause writes node.env=paused + the NODE sentinel (REASON=), never
#       the repo kill switch; resume removes the node sentinel ─────────────────
run_verb node pause --reason "maintenance" >/dev/null 2>&1 || fail "real pause should succeed"
grep -qx "CHUMP_NODE_MODE=paused" "$VSTATE/node.env" || fail "real pause must set bare CHUMP_NODE_MODE=paused"
grep -qx "export CHUMP_RUN_USER=ubuntu" "$VSTATE/node.env" || fail "real pause must preserve other lines' export form"
# RESILIENT-1652/1653 (task 1): pause WRITES the node pause sentinel at exactly
# <state_dir>/.chump/fleet-paused carrying REASON= (the same path node-converge's
# _nc_paused and the farmer gate read), and NEVER the <repo>/.chump kill switch
# (which would wall re-entry) nor the old doubled .chump/.chump path.
[ -e "$VSTATE/.chump/fleet-paused" ] || fail "real pause must write the node pause sentinel <state_dir>/.chump/fleet-paused"
grep -q "REASON=maintenance" "$VSTATE/.chump/fleet-paused" || fail "node pause sentinel must carry REASON="
[ ! -e "$VREPO/.chump/fleet-paused" ] || fail "real pause must NOT write the repo kill-switch sentinel"
[ ! -e "$VSTATE/.chump/.chump/fleet-paused" ] || fail "real pause must NOT write the doubled .chump/.chump path"
# is-paused agrees with the written state (exit 0 = paused), zero writes.
run_verb node is-paused >/dev/null 2>&1 || fail "chump node is-paused must exit 0 on a paused node"
# resume removes the node sentinel it wrote and flips is-paused back to exit 1.
run_verb node resume >/dev/null 2>&1 || fail "real resume should succeed"
[ ! -e "$VSTATE/.chump/fleet-paused" ] || fail "resume must remove the node pause sentinel"
run_verb node is-paused >/dev/null 2>&1 && fail "chump node is-paused must exit 1 after resume"
ok "(5) real pause writes node.env=paused (bare) + node sentinel (REASON=), no kill switch; resume removes it; is-paused agrees"

# ── (6) is-paused ↔ node-converge parity over the node.env fixtures ───────────
# task (3): node-converge's `_nc_paused` now DELEGATES to `chump node is-paused`
# (the ONE Rust predicate) instead of its own divergent rule. Pin the verdict
# the shell relies on across every fixture form, INCLUDING the key divergence:
# WORK_ENABLED=0 ALONE (no control-plane mode) is NOT paused under the Rust
# predicate, where the old shell-only rule wrongly treated it as paused.
PSTATE="$TMP/pstate"
# expect: 0 = must read PAUSED (is-paused exit 0); 1 = must read NOT paused.
is_paused_is() {  # $1=label $2=expected_rc ; node.env already written to $PSTATE
    local rc=0
    env -i PATH="$STUB:/usr/bin:/bin" HOME="$TMP/phome" \
        CHUMP_STATE_DIR="$PSTATE" "$CHUMP_BIN" node is-paused >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq "$2" ] || fail "parity $1: is-paused rc=$rc, expected $2"
}
rm -rf "$PSTATE"; mkdir -p "$PSTATE/.chump"
printf 'CHUMP_NODE_MODE=paused\n' > "$PSTATE/node.env"; is_paused_is "bare mode=paused" 0
printf 'export CHUMP_NODE_MODE=paused\n' > "$PSTATE/node.env"; is_paused_is "export mode=paused" 0
printf 'CHUMP_NODE_MODE=control-plane\nCHUMP_NODE_WORK_ENABLED=0\n' > "$PSTATE/node.env"; is_paused_is "legacy bare control-plane+WE=0" 0
printf 'export CHUMP_NODE_MODE=control-plane\nexport CHUMP_NODE_WORK_ENABLED=0\n' > "$PSTATE/node.env"; is_paused_is "legacy export control-plane+WE=0" 0
# WORK_ENABLED=0 ALONE (work-ready mode) is NOT paused under the Rust predicate.
printf 'CHUMP_NODE_MODE=work-ready\nCHUMP_NODE_WORK_ENABLED=0\n' > "$PSTATE/node.env"; is_paused_is "WE=0 alone (not control-plane)" 1
# sentinel present (node.env unpaused) → paused; absent → not paused.
printf 'CHUMP_NODE_MODE=work-ready\n' > "$PSTATE/node.env"; is_paused_is "work-ready, no sentinel" 1
printf 'REASON=slo\n' > "$PSTATE/.chump/fleet-paused"; is_paused_is "work-ready + node sentinel present" 0
rm -f "$PSTATE/.chump/fleet-paused"; is_paused_is "sentinel removed → not paused" 1
# Static wiring guard: node-converge's _nc_paused must delegate to the verb, so
# this parity governs the real converge path (not just a standalone binary).
grep -q 'node is-paused' "$REPO_ROOT/scripts/ops/node-converge.sh" \
    || fail "node-converge.sh _nc_paused must delegate to 'chump node is-paused'"
ok "(6) is-paused parity: both line forms + legacy control-plane+WE=0 paused; WE=0-alone not paused; sentinel present/absent; node-converge delegates"

echo ""
echo "All RESILIENT-1652 / RESILIENT-1653 pause + oauth tests passed!"
