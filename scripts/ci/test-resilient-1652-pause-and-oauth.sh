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

# ZERO-WASTE-134: the ONE shared cargo target dir — never a path inside the
# worktree/repo root. Exports CARGO_TARGET_DIR so the binary lookup below and
# the wired sub-tests all build/read from the same shared dir.
# shellcheck source=lib/resolve-cargo-target-dir.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/ci/lib/resolve-cargo-target-dir.sh"
chump_export_cargo_target_dir

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
# Static wiring guard: node-converge's _nc_paused must actually INVOKE the verb
# (not merely mention it in a comment), so this parity governs the real converge
# path (not just a standalone binary). Match the invocation form `"$chump" node
# is-paused`, which the comment block does not contain.
grep -qF '"$chump" node is-paused' "$REPO_ROOT/scripts/ops/node-converge.sh" \
    || fail 'node-converge.sh _nc_paused must INVOKE "$chump" node is-paused'
ok "(6) is-paused parity: both line forms + legacy control-plane+WE=0 paused; WE=0-alone not paused; sentinel present/absent; node-converge delegates"

# ── (7) task (3): Linux oauth-token.json judged by CONTENT, not mtime, THROUGH
#       the farmer gate (kills mutant M11 — oauth judged by mtime on Linux). ──
# The gate's Linux fallback reads <state-home>/.chump/oauth-token.json and must
# judge it by CONTENT: a long-lived env token (providers.env-linux shape, no
# expiry) with an OLD mtime reads FRESH; a missing / empty / expired-with-expiry
# token reds. env -i with no ANTHROPIC_API_KEY, no .credentials.json, no
# auth-status-cache, no free-tier forces the check to the oauth-token.json
# branch; a not-paused node.env isolates the oauth axis so `green` tracks
# oauth_fresh 1:1. Linux-only (the content branch is `cfg!(target_os=linux)`).
if [ "$(uname -s)" = "Linux" ]; then
    OROOT="$TMP/oauth"; OSTATE="$OROOT/.chump"; ONODE="$TMP/oauth-node"
    mkdir -p "$OSTATE" "$ONODE" "$TMP/ohome"
    printf 'CHUMP_NODE_MODE=work-ready\n' > "$ONODE/node.env"   # not paused → isolate oauth axis
    gate_oauth() {  # $1=label $2=expected (true|false); asserts oauth_fresh AND green both == expected
        local json verdict
        json="$(env -i PATH="$STUB:/usr/bin:/bin" HOME="$TMP/ohome" \
            CHUMP_REPO="$OROOT" CHUMP_HOME="$OROOT" CHUMP_STATE_DIR="$ONODE" \
            "$CHUMP_BIN" farmer status --json 2>/dev/null)" || true
        verdict="$(printf '%s' "$json" | python3 -c 'import json,sys
s=json.load(sys.stdin)
print(str(s["oauth_fresh"]).lower(), str(s["green"]).lower())' 2>/dev/null)" || true
        [ "$verdict" = "$2 $2" ] \
            || fail "(7) oauth $1: oauth_fresh/green=[$verdict] expected [$2 $2] (json=$json)"
    }
    # Long-lived env token, no expiry, OLD mtime → FRESH (content, not mtime).
    printf '{"token":"sk-ant-oat01-longlived-fixture","source":"providers.env-linux"}\n' > "$OSTATE/oauth-token.json"
    backdate "$OSTATE/oauth-token.json" 8640000   # 100 days old
    gate_oauth "long-lived old-mtime token" true
    # Missing token → RED.
    rm -f "$OSTATE/oauth-token.json"
    gate_oauth "missing token" false
    # Empty token → RED.
    printf '{"token":""}\n' > "$OSTATE/oauth-token.json"
    gate_oauth "empty token" false
    # Expired-with-expiry token → RED.
    printf '{"token":"sk-ant-oat01-x","expiresAt":1}\n' > "$OSTATE/oauth-token.json"
    gate_oauth "expired-with-expiry token" false
    ok "(7) Linux oauth-token.json judged by CONTENT through the gate: long-lived OLD-mtime token fresh; missing/empty/expired RED (kills M11 mtime-judging)"
else
    ok "(7) oauth content gate: skipped (non-Linux — the content branch is Linux-only)"
fi

# ── (8) task (4): `chump node is-paused` makes ZERO writes ────────────────────
# A pure read-only predicate verb: the node state dir and node.env must be
# byte-identical before and after the call, on BOTH a paused and a not-paused
# node. Kills: is-paused writes a marker; is-paused rewrites node.env.
snapshot() { ( cd "$1" && find . -type f -exec sha256sum {} + 2>/dev/null | LC_ALL=C sort ); }
ISP="$TMP/isp"; mkdir -p "$ISP/.chump" "$TMP/isphome"
for form in "CHUMP_NODE_MODE=paused" "CHUMP_NODE_MODE=work-ready"; do
    printf '%s\n' "$form" > "$ISP/node.env"
    isp_before="$(snapshot "$ISP")"; ne_before="$(cat "$ISP/node.env")"
    env -i PATH="$STUB:/usr/bin:/bin" HOME="$TMP/isphome" CHUMP_STATE_DIR="$ISP" \
        "$CHUMP_BIN" node is-paused >/dev/null 2>&1 || true
    isp_after="$(snapshot "$ISP")"; ne_after="$(cat "$ISP/node.env")"
    [ "$isp_before" = "$isp_after" ] \
        || fail "(8) is-paused ($form) mutated the state dir (wrote a marker?): before=[$isp_before] after=[$isp_after]"
    [ "$ne_before" = "$ne_after" ] \
        || fail "(8) is-paused ($form) rewrote node.env"
done
ok "(8) chump node is-paused makes ZERO writes (state dir + node.env byte-identical before/after, paused & not-paused)"

# ── (9) task (5): node-converge's OWN _nc_paused over the node.env fixtures ───
# Source node-converge.sh (its source-guard returns before the converge body)
# with the chump binary on PATH, and run _nc_paused directly. With a binary
# present it DELEGATES to `chump node is-paused` (the ONE Rust predicate), so
# WORK_ENABLED=0 ALONE reads NOT paused — the exact point the old shell-only
# rule got wrong. Kills: node-converge keeps its own rule (`if false` → shell
# fallback would pause on WE=0-alone); node-converge ignores the not-paused rc.
NCSTATE="$TMP/ncstate"; mkdir -p "$NCSTATE/.chump" "$TMP/nchome"
# node-converge's _nc_paused resolves the binary via `command -v chump`, so a
# binary that must be named exactly `chump` on PATH is what makes it DELEGATE
# (vs. the no-binary shell fallback). CHUMP_BIN may be named anything (a CI
# per-run path, a local copy), so expose it as `chump` in a dedicated dir.
NCBIN="$TMP/ncbin"; mkdir -p "$NCBIN"; ln -sf "$CHUMP_BIN" "$NCBIN/chump"
(
    set -uo pipefail
    export HOME="$TMP/nchome"
    export PATH="$NCBIN:$STUB:/usr/bin:/bin"
    # shellcheck source=scripts/ops/node-converge.sh
    source "$REPO_ROOT/scripts/ops/node-converge.sh"
    [ "$(type -t _nc_paused)" = function ] || { echo "_nc_paused not defined after source"; exit 1; }
    nc_is() {  # $1=label $2=expected_rc
        local rc=0
        CHUMP_STATE_DIR="$NCSTATE" _nc_paused || rc=$?
        [ "$rc" -eq "$2" ] || { echo "_nc_paused $1: rc=$rc expected $2"; exit 1; }
    }
    printf 'CHUMP_NODE_MODE=paused\n'                                    > "$NCSTATE/node.env"; nc_is "mode=paused" 0
    printf 'export CHUMP_NODE_MODE=control-plane\nexport CHUMP_NODE_WORK_ENABLED=0\n' > "$NCSTATE/node.env"; nc_is "legacy control-plane+WE=0" 0
    printf 'CHUMP_NODE_MODE=work-ready\nCHUMP_NODE_WORK_ENABLED=0\n'     > "$NCSTATE/node.env"; nc_is "WORK_ENABLED=0 ALONE (not paused)" 1
    printf 'CHUMP_NODE_MODE=work-ready\n'                                > "$NCSTATE/node.env"; nc_is "work-ready" 1
    printf 'CHUMP_NODE_MODE=work-ready\n'                                > "$NCSTATE/node.env"
    printf 'REASON=slo\n' > "$NCSTATE/.chump/fleet-paused"; nc_is "sentinel present" 0
) || fail "(9) node-converge _nc_paused parity over fixtures (delegation to the Rust predicate broke)"
ok "(9) node-converge _nc_paused (binary present) delegates to the Rust predicate: paused forms paused; WORK_ENABLED=0 ALONE NOT paused; sentinel paused"

# ── (10) healthy-node-fixture self-test (repair 5, item 4) ────────────────────
# The ONE shared CI fixture helper (scripts/ci/lib/healthy-node-fixture.sh) must:
#  (a) write a token the Linux content gate ACCEPTS;
#  (b) export NO environment variable (it writes EVIDENCE, never env); and
#  (c) with the environment CLEARED, make the gate read GREEN on the fixture
#      alone. Kills the mutant where the helper exports CHUMP_FREE_TIER_PROVIDERS
#      (or any env) instead of writing a token: `env -i` wipes any export so the
#      gate then has neither a token nor a free-tier signal → RED; and the
#      export-diff below catches the stray export directly.
HNF="$REPO_ROOT/scripts/ci/lib/healthy-node-fixture.sh"
HROOT="$TMP/hnf"; HHOME="$HROOT/home"; HSTATE="$HHOME/.chump"; HREPO="$HROOT/repo"
mkdir -p "$HHOME" "$HREPO/.chump"

# (b) exports-nothing: in a subshell with the fixture env already set, capture the
# exported-name set before/after sourcing+calling; the delta must be empty (the
# helper uses only `local` vars). Also writes the fixture as a side effect.
EXPORT_DELTA="$(env -i PATH="$STUB:/usr/bin:/bin" HOME="$HHOME" CHUMP_HOME="$HHOME" \
    CHUMP_STATE_DIR="$HSTATE" CHUMP_REPO="$HREPO" bash -c '
        before="$(compgen -e | LC_ALL=C sort)"
        source "'"$HNF"'"
        write_healthy_node_fixture >/dev/null 2>&1 || { echo "HELPER_FAILED"; exit 0; }
        after="$(compgen -e | LC_ALL=C sort)"
        comm -13 <(printf "%s\n" "$before") <(printf "%s\n" "$after")
    ')"
[ "$EXPORT_DELTA" != "HELPER_FAILED" ] || fail "(10) helper refused to write the fixture under a clean temp home"
[ -z "$EXPORT_DELTA" ] || fail "(10) helper EXPORTED env var(s) instead of writing evidence: [$EXPORT_DELTA]"

# evidence lands exactly where the gate reads it (repair 5, item 2): oauth under
# <state_home>/.chump, node.env in the state dir, heartbeat under repo_root/.chump
# (farmer_status reads repo_root/.chump/farmer-heartbeat — NOT the node state dir).
[ -f "$HHOME/.chump/oauth-token.json" ] || fail "(10) oauth token not written under <state_home>/.chump"
[ -f "$HSTATE/node.env" ]               || fail "(10) node.env not written in the state dir"
[ -f "$HREPO/.chump/farmer-heartbeat" ] || fail "(10) heartbeat not written where the gate reads it (repo_root/.chump/farmer-heartbeat)"

# (a)+(c) token content accepted AND gate GREEN on the fixture alone, env cleared
# (no ANTHROPIC_API_KEY, no CHUMP_FREE_TIER_PROVIDERS, no cache — env -i guarantees it).
HNF_JSON="$(env -i PATH="$STUB:/usr/bin:/bin" HOME="$HHOME" CHUMP_HOME="$HHOME" \
    CHUMP_STATE_DIR="$HSTATE" CHUMP_REPO="$HREPO" "$CHUMP_BIN" farmer status --json 2>/dev/null)" || true
python3 - "$HNF_JSON" <<'PY' || fail "(10) gate not GREEN on the helper fixture alone — token content rejected or a stray env leaked"
import json,sys
s=json.loads(sys.argv[1])
assert s["oauth_fresh"] is True, f"oauth_fresh must be True from the fixture token alone: {s}"
assert s["green"] is True, f"green must be True on the healthy-node fixture alone: {s}"
PY
ok "(10) healthy-node-fixture: writes a content-valid token, exports NO env, gate GREEN on the fixture alone (env cleared) — kills the CHUMP_FREE_TIER_PROVIDERS mutant"

# ── (11) SAFETY regression: the helper NEVER touches an inherited CHUMP_STATE_DIR
#     (repair 5, item 1) ──────────────────────────────────────────────────────
# On a node the installer EXPORTS CHUMP_STATE_DIR at the REAL state dir. Export it
# here at a PAUSED sentinel dir and prove that (a) the helper HARD-STOPS (exit 2)
# rather than write into it, and (b) EVERY wired test the architect reproduced the
# exploit with (test-state-db-yaml-sync.sh — fast-checks; test-outcome-gate.sh —
# runs inside `chump preflight`) leaves that dir BYTE-IDENTICAL (node.env +
# heartbeat untouched), because each exports its OWN temp CHUMP_STATE_DIR first.
PAUSED="$TMP/paused-real-statedir"; mkdir -p "$PAUSED"
printf 'export CHUMP_NODE_MODE=paused\nexport CHUMP_RUN_USER=ubuntu\n' > "$PAUSED/node.env"
printf 'real-durable-heartbeat\n' > "$PAUSED/farmer-heartbeat"
paused_snapshot() { ( cd "$PAUSED" && find . -type f -exec sha256sum {} + 2>/dev/null | LC_ALL=C sort ); }
PAUSED_BEFORE="$(paused_snapshot)"

# (a) direct: helper must exit 2 (CHUMP_STATE_DIR != the derived temp state dir)
#     and write nothing into $PAUSED.
REG_HOME="$TMP/reg-home"; mkdir -p "$REG_HOME"
reg_rc=0
( env -i PATH="$STUB:/usr/bin:/bin" HOME="$REG_HOME" CHUMP_HOME="$REG_HOME" \
    CHUMP_STATE_DIR="$PAUSED" bash -c 'source "'"$HNF"'"; write_healthy_node_fixture' ) >/dev/null 2>&1 || reg_rc=$?
[ "$reg_rc" -eq 2 ] || fail "(11a) helper must exit 2 when CHUMP_STATE_DIR points outside the test temp home (got $reg_rc)"
[ "$(paused_snapshot)" = "$PAUSED_BEFORE" ] || fail "(11a) helper MUTATED the inherited CHUMP_STATE_DIR (node.env/heartbeat not byte-identical)"

# (b) end-to-end: run the two exploit-reproducing wired tests with CHUMP_STATE_DIR
#     exported at $PAUSED; assert $PAUSED stays byte-identical after each. (These
#     two don't invoke bot-merge, so they're side-effect-free here; the remaining
#     wired tests share the SAME helper + guard, so this proves the class.)
for wt in test-state-db-yaml-sync.sh test-outcome-gate.sh; do
    env CHUMP_STATE_DIR="$PAUSED" CHUMP_BIN="$CHUMP_BIN" \
        HOME="$TMP/wt-outer-home" \
        bash "$REPO_ROOT/scripts/ci/$wt" >/dev/null 2>&1 || true
    [ "$(paused_snapshot)" = "$PAUSED_BEFORE" ] \
        || fail "(11b) wired test $wt MUTATED the inherited paused CHUMP_STATE_DIR (node.env/heartbeat changed!)"
done
ok "(11) safety: helper refuses (exit 2) an inherited real CHUMP_STATE_DIR; it and the exploit-reproducing wired tests leave the paused dir BYTE-IDENTICAL (node.env + heartbeat untouched)"

echo ""
echo "All RESILIENT-1652 / RESILIENT-1653 pause + oauth tests passed!"
