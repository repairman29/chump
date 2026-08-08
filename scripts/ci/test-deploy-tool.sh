#!/usr/bin/env bash
# scripts/ci/test-deploy-tool.sh — INFRA-3502 (COTG-5.1)
#
# Verifies scripts/ops/deploy-tool.sh: the stage-then-verify-then-promote
# flow that deploys a shipped tool to a usable customer surface, and refuses
# to expose an unverified artifact to the customer.
#
# Acceptance criteria verified (INFRA-3502, first slice):
#   (1) Given a stubbed deploy cmd (fake stage URL) + a DoD cmd that EXITS 0,
#       runs deploy -> DoD-on-stage -> promote IN ORDER and exits 0.
#   (2) When the injected DoD cmd EXITS NON-ZERO, promote is NOT called at all
#       and kind=tool_promote_blocked is emitted (never tool_promoted).
#   (3) Promote runs on the SAME stage artifact and does NO fresh build/deploy:
#       the deploy stub is invoked EXACTLY ONCE across a full success run.
#   (4) All 4 ambient kinds (tool_deployed_stage, tool_dod_passed,
#       tool_promoted, tool_promote_blocked) are scanner-anchored in the script
#       AND registered in docs/observability/EVENT_REGISTRY.yaml.
#   (5) The customer URL is printed to stdout ONLY after a successful promote —
#       present in the success run, absent in the blocked-DoD run.
#
# No real network / no real Vercel: the deploy, DoD, and promote commands are
# all stubbed via CHUMP_TOOL_DEPLOY_CMD / CHUMP_TOOL_DOD_CMD /
# CHUMP_TOOL_PROMOTE_CMD, and ambient.jsonl is isolated per-run via
# CHUMP_REPO_ROOT pointing at a temp dir.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY_TOOL="$REPO_ROOT/scripts/ops/deploy-tool.sh"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── Static checks ─────────────────────────────────────────────────────────────
[[ -x "$DEPLOY_TOOL" ]] || fail "deploy-tool.sh missing or not executable"
grep -q 'INFRA-3502' "$DEPLOY_TOOL" || fail "INFRA-3502 banner missing"

# (4) all 4 kinds scanner-anchored in the script AND registered in the registry
for kind in tool_deployed_stage tool_dod_passed tool_promoted tool_promote_blocked; do
    grep -q "scanner-anchor: \"kind\":\"$kind\"" "$DEPLOY_TOOL" \
        || fail "$kind missing its scanner-anchor comment in deploy-tool.sh"
    grep -q "kind: $kind" "$REG" \
        || fail "EVENT_REGISTRY.yaml missing kind: $kind"
done
ok "all 4 ambient kinds are scanner-anchored in the script AND registered (AC4)"

# ── Shared stubs ──────────────────────────────────────────────────────────────
# Each stub appends its name to ORDER_LOG so we can assert call order.
# The deploy stub also appends a line to DEPLOY_COUNT per call (count = lines).
DEPLOY_STUB="$TMP/deploy-stub.sh"
cat >"$DEPLOY_STUB" <<'EOF'
#!/usr/bin/env bash
echo deploy >> "$ORDER_LOG"
echo x >> "$DEPLOY_COUNT"
# Emit the stage URL as the last stdout line (as `vercel deploy` does).
echo "Building..."
echo "https://stage-deadbeef.vercel.app"
EOF
chmod +x "$DEPLOY_STUB"

# DoD stub: verifies STAGE_URL was exported, then exits with DOD_EXIT.
DOD_STUB="$TMP/dod-stub.sh"
cat >"$DOD_STUB" <<'EOF'
#!/usr/bin/env bash
echo dod >> "$ORDER_LOG"
[[ -n "${STAGE_URL:-}" ]] || { echo "STAGE_URL not exported to DoD cmd" >&2; exit 99; }
exit "${DOD_EXIT:-0}"
EOF
chmod +x "$DOD_STUB"

# Promote stub: marks that it ran. Deliberately does NOT touch DEPLOY_COUNT,
# so a spurious rebuild during promote would show up as a second deploy line.
PROMOTE_STUB="$TMP/promote-stub.sh"
cat >"$PROMOTE_STUB" <<'EOF'
#!/usr/bin/env bash
echo promote >> "$ORDER_LOG"
[[ -n "${STAGE_URL:-}" ]] || { echo "STAGE_URL not exported to promote cmd" >&2; exit 98; }
touch "$PROMOTE_MARKER"
exit 0
EOF
chmod +x "$PROMOTE_STUB"

CUSTOMER_URL="https://customer-prod.example.com"

# run_flow <repo_root> <dod_exit> <stdout_file> — drive one full flow with stubs.
run_flow() {
    local repo_root="$1" dod_exit="$2" out="$3"
    mkdir -p "$repo_root/.chump-locks"
    ORDER_LOG="$repo_root/order.log" \
    DEPLOY_COUNT="$repo_root/deploy.count" \
    PROMOTE_MARKER="$repo_root/promote.marker" \
    DOD_EXIT="$dod_exit" \
    CHUMP_REPO_ROOT="$repo_root" \
    CHUMP_TOOL_TARGET="$repo_root" \
    CHUMP_TOOL_DEPLOY_CMD="ORDER_LOG=$repo_root/order.log DEPLOY_COUNT=$repo_root/deploy.count bash $DEPLOY_STUB" \
    CHUMP_TOOL_DOD_CMD="ORDER_LOG=$repo_root/order.log DOD_EXIT=$dod_exit bash $DOD_STUB" \
    CHUMP_TOOL_PROMOTE_CMD="ORDER_LOG=$repo_root/order.log PROMOTE_MARKER=$repo_root/promote.marker bash $PROMOTE_STUB" \
    CHUMP_TOOL_CUSTOMER_URL="$CUSTOMER_URL" \
        bash "$DEPLOY_TOOL" >"$out" 2>"$repo_root/err.log"
    return $?
}

# ── (1)+(3)+(5 success) Happy path: deploy->DoD->promote, in order, exit 0 ────
REPO_OK="$TMP/repo-ok"
run_flow "$REPO_OK" 0 "$TMP/out-ok.log"
RC=$?
[[ "$RC" -eq 0 ]] || fail "scenario OK: expected exit 0, got $RC: $(cat "$REPO_OK/err.log")"

ORDER="$(tr '\n' ' ' < "$REPO_OK/order.log" | sed 's/ *$//')"
[[ "$ORDER" == "deploy dod promote" ]] \
    || fail "scenario OK: expected order 'deploy dod promote', got '$ORDER'"
ok "deploy -> DoD-on-stage -> promote run in order, exit 0 (AC1)"

# (3) deploy invoked exactly once — no fresh build/deploy during promote.
DEPLOYS="$(wc -l < "$REPO_OK/deploy.count" | tr -d ' ')"
[[ "$DEPLOYS" -eq 1 ]] \
    || fail "scenario OK: deploy stub must run EXACTLY once (promote must not rebuild), got $DEPLOYS"
[[ -e "$REPO_OK/promote.marker" ]] || fail "scenario OK: promote stub did not run"
ok "promote flips the SAME stage artifact; deploy invoked exactly once (AC3)"

# (5-success) customer URL is printed to stdout, as the last line, after promote.
LAST_LINE="$(grep -E '[^[:space:]]' "$TMP/out-ok.log" | tail -n1)"
[[ "$LAST_LINE" == "$CUSTOMER_URL" ]] \
    || fail "scenario OK: customer URL must be the last stdout line, got '$LAST_LINE'"
ok "customer URL printed to stdout after a successful promote (AC5 success)"

# success run emits tool_promoted, not tool_promote_blocked
AMB_OK="$REPO_OK/.chump-locks/ambient.jsonl"
grep -q '"kind":"tool_deployed_stage"' "$AMB_OK" || fail "scenario OK: tool_deployed_stage not emitted"
grep -q '"kind":"tool_dod_passed"'     "$AMB_OK" || fail "scenario OK: tool_dod_passed not emitted"
grep -q '"kind":"tool_promoted"'       "$AMB_OK" || fail "scenario OK: tool_promoted not emitted"
grep -q '"kind":"tool_promote_blocked"' "$AMB_OK" \
    && fail "scenario OK: tool_promote_blocked must NOT be emitted on a passing DoD"
ok "success run emits tool_deployed_stage + tool_dod_passed + tool_promoted (no blocked)"

# ── (2)+(5 blocked) DoD fails: no promote, emits tool_promote_blocked ─────────
REPO_BLOCK="$TMP/repo-block"
run_flow "$REPO_BLOCK" 1 "$TMP/out-block.log"
RC=$?
[[ "$RC" -ne 0 ]] || fail "scenario BLOCK: a failing DoD must exit non-zero, got 0"

ORDER_B="$(tr '\n' ' ' < "$REPO_BLOCK/order.log" | sed 's/ *$//')"
[[ "$ORDER_B" == "deploy dod" ]] \
    || fail "scenario BLOCK: expected order 'deploy dod' (no promote), got '$ORDER_B'"
[[ ! -e "$REPO_BLOCK/promote.marker" ]] \
    || fail "scenario BLOCK: promote MUST NOT run when the DoD fails on stage"

AMB_B="$REPO_BLOCK/.chump-locks/ambient.jsonl"
grep -q '"kind":"tool_promote_blocked"' "$AMB_B" \
    || fail "scenario BLOCK: tool_promote_blocked not emitted"
grep -q '"kind":"tool_promoted"' "$AMB_B" \
    && fail "scenario BLOCK: tool_promoted must NOT be emitted when the DoD fails"
ok "failing DoD blocks promote entirely + emits tool_promote_blocked, not tool_promoted (AC2)"

# (5-blocked) customer URL is absent from stdout on the blocked run.
if grep -qF "$CUSTOMER_URL" "$TMP/out-block.log"; then
    fail "scenario BLOCK: customer URL must NOT be printed when promote was blocked"
fi
ok "customer URL absent from stdout on the blocked-DoD run (AC5 blocked)"

echo
echo "All INFRA-3502 deploy-tool tests passed."
