#!/usr/bin/env bash
# test-credible-959-autoclose-else-branch-logging.sh — CREDIBLE-959
# (CREDIBLE-870 / CREDIBLE-295 slice)
#
# Locks in the auto-close stage's error-handling contract in
# scripts/coord/bot-merge.sh (INFRA-1030 block): when `chump gap ship`
# returns a non-zero exit code, the else-branch must (a) log the non-zero
# exit code so a curator/operator can see it, and (b) NOT abort the
# script — the PR is already auto-merge-armed at that point, so killing
# bot-merge here would only confuse the caller (see the INFRA-1030 comment
# immediately above the block).
#
# Technique: extract the real auto-close block verbatim from bot-merge.sh
# via anchor-bounded `sed` (same technique as
# test-credible-801-doc-shell-autoclose-harness.sh) and drive it with a
# stubbed `chump` whose `gap ship` subcommand deliberately fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $1" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$BOT_MERGE" ]] || { echo "SKIP: bot-merge.sh not found at $BOT_MERGE" >&2; exit 0; }

echo "=== CREDIBLE-959: auto-close else-branch error logging ==="
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. Extract the real auto-close block verbatim (INFRA-1030 .. INFRA-193) ──
_AC_START=$(grep -n '── INFRA-1030: Auto-close gap AFTER auto-merge arm' "$BOT_MERGE" | head -1 | cut -d: -f1)
_AC_END_MARKER=$(grep -n '── INFRA-193: speculative-execution loser sweep' "$BOT_MERGE" | head -1 | cut -d: -f1)

if [[ -z "$_AC_START" || -z "$_AC_END_MARKER" ]]; then
    fail "could not locate extraction anchors (autoclose=[$_AC_START,$_AC_END_MARKER]) — bot-merge.sh restructured, update anchors"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
ok "extraction anchor located in bot-merge.sh (auto-close block)"

_AC_END=$(( _AC_END_MARKER - 1 ))
sed -n "${_AC_START},${_AC_END}p" "$BOT_MERGE" > "$TMP/autoclose_block.sh"

if grep -q '^\s*else$' "$TMP/autoclose_block.sh"; then
    ok "auto-close block contains an else-branch"
else
    fail "auto-close block has no else-branch — bot-merge.sh restructured, update this test"
fi

# ── 2. Stub `chump` — `gap ship` deliberately fails with a distinctive rc ───
FORCED_RC=17
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "gap" && "\$2" == "ship" ]]; then
    echo "simulated ship failure (CREDIBLE-959 forced error)" >&2
    exit $FORCED_RC
fi
if [[ "\$1" == "pr" && "\$2" == "ac-coverage" ]]; then echo '{"status":"ok"}'; exit 0; fi
if [[ "\$1" == "gap" && "\$2" == "list" ]]; then echo '[]'; exit 0; fi
exit 0
STUB
chmod +x "$TMP/bin/chump"

# ── 3. Assemble the harness: real auto-close block, lightweight stand-ins
# for the surrounding stage/logging helpers, and a synthetic single-gap PR
# payload (GAP_IDS + TARGET_PR — the two inputs the auto-close block reads).
mkdir -p "$TMP/work/.chump-locks" "$TMP/work/.chump"
cat > "$TMP/harness.sh" <<HARNESS
#!/usr/bin/env bash
set -uo pipefail
export PATH="$TMP/bin:\$PATH"
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
export REPO_ROOT="$TMP/work"
export MAIN_REPO="$TMP/work"

DRY_RUN=0
CHUMP_AUTO_CLOSE_GAP=1
CHUMP_BENCH_MODE=0
CHUMP_VERIFY_LIVE_BLOCKING=0
GAP_IDS=("CREDIBLE-959-FORCED-ERROR")
TARGET_PR=999002
_BM_NAMED_STEP=""

green()  { printf '[green] %s\n' "\$*"; }
red()    { printf '[red] %s\n' "\$*"; }
yellow() { printf '[yellow] %s\n' "\$*"; }
info()   { printf '[info] %s\n' "\$*"; }
stage_start() { __STAGE_LABEL="\$1"; info "stage_start: \$1"; }
stage_done()  { info "stage_done: \${__STAGE_LABEL:-}"; }
run_timed_hb() { local label=\$1 max_secs=\$2; shift 2; "\$@"; }

source "$TMP/autoclose_block.sh"
echo "HARNESS COMPLETED WITHOUT DYING"
HARNESS
chmod +x "$TMP/harness.sh"
ok "harness assembled: real auto-close block + forced chump-gap-ship failure (rc=$FORCED_RC)"

# ── 4. Run it ─────────────────────────────────────────────────────────────
_HOUT="$TMP/harness_stdout.log"
_hrc=0
"$TMP/harness.sh" > "$_HOUT" 2>&1 || _hrc=$?

# AC#2: the script must NOT abort — it should reach the end and print the
# completion marker, with a clean (0) exit code.
if [[ "$_hrc" -eq 0 ]] && grep -q '^HARNESS COMPLETED WITHOUT DYING$' "$_HOUT"; then
    ok "AC#2: else-branch logged the failure but did not abort the script (harness ran to completion, rc=$_hrc)"
else
    fail "AC#2: harness aborted or exited non-zero (rc=$_hrc) instead of continuing past the ship failure: $(cat "$_HOUT")"
fi

# AC#1: the non-zero exit code must be recorded — both in the human-readable
# red() log line and in the ambient event.
if grep -q "rc=$FORCED_RC" "$_HOUT"; then
    ok "AC#1: else-branch log line recorded the non-zero exit code (rc=$FORCED_RC)"
else
    fail "AC#1: no log line recorded rc=$FORCED_RC: $(cat "$_HOUT")"
fi

if [[ -f "$TMP/ambient.jsonl" ]] && grep -q "\"kind\":\"gap_ship_post_arm_failed\"" "$TMP/ambient.jsonl" \
        && grep -q "\"rc\":$FORCED_RC" "$TMP/ambient.jsonl"; then
    ok "AC#1: ambient event kind=gap_ship_post_arm_failed recorded rc=$FORCED_RC for curator/operator pickup"
else
    fail "AC#1: ambient event did not record the non-zero rc: $(cat "$TMP/ambient.jsonl" 2>/dev/null || echo '(no ambient.jsonl)')"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
