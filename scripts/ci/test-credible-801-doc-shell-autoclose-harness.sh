#!/usr/bin/env bash
# test-credible-801-doc-shell-autoclose-harness.sh — CREDIBLE-801 (CREDIBLE-295 slice)
#
# Unit test harness that simulates scripts/coord/bot-merge.sh's auto-close
# stage (INFRA-154, the "── INFRA-1030: Auto-close gap AFTER auto-merge arm"
# block) driven by a synthetic shell/doc PR payload — WITHOUT running the
# real bot-merge.sh end to end (no git/gh network I/O).
#
# How it works: the real `_bm_err_handler` (RESILIENT-052 ERR trap) and the
# real auto-close block are extracted verbatim from bot-merge.sh via
# anchor-bounded `sed` (same technique as
# test-bot-merge-err-trap-loud-fail.sh) and assembled into a standalone
# harness script with lightweight stand-ins for stage_start/stage_done/
# green/red/yellow/info/run_timed_hb (the extracted block's only external
# dependencies besides the `chump` CLI, which is stubbed).
#
# THIS TEST IS EXPECTED TO CURRENTLY FAIL (red, by design — CREDIBLE-801
# AC#2). It reproduces a real, live defect found while building this
# harness: `_tmpship=$(mktemp)` (scripts/coord/bot-merge.sh, inside the
# auto-close loop, immediately before the `chump gap ship` call) is the one
# command in the whole auto-close block with no `|| true` / fallback
# guard — every sibling command in the block is defensively guarded. On a
# shell/doc-only-fastpath runner with a full or unwritable TMPDIR, `mktemp`
# fails, `set -euo pipefail` kills the script right there, the RESILIENT-052
# ERR trap fires loud (kind=bot_merge_uncaught_error), and it does so BEFORE
# `chump gap ship` — i.e. before any state mutation ("changes") happens. The
# PR is already auto-merge-armed at this point (INFRA-1030's stated
# invariant), so the gap silently never gets its auto-close — this is a
# plausible root cause for the CREDIBLE-204 "auto-close missed" class
# ("printed 'auto-close targeting state.db' then died").
#
# Fix (tracked separately, not in scope for this harness-only slice): guard
# `_tmpship=$(mktemp)` the same way every other command in the block is
# guarded, and/or fall back to a fixed path. Once fixed, this test goes
# green — do not delete it on failure, it locks in the reproduction.
#
# NOT wired into any CI workflow or `chump preflight` gate (deliberately —
# a red-by-design test would break the gate). Run by hand:
#   bash scripts/ci/test-credible-801-doc-shell-autoclose-harness.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $1" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$BOT_MERGE" ]] || { echo "SKIP: bot-merge.sh not found at $BOT_MERGE" >&2; exit 0; }

echo "=== CREDIBLE-801: auto-close stage harness, driven by a shell/doc PR payload ==="
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. Extract the real ERR trap handler verbatim ────────────────────────────
_ERR_START=$(grep -n '^_bm_err_handler() {' "$BOT_MERGE" | head -1 | cut -d: -f1)
_ERR_END=$(grep -n "^trap '_bm_err_handler" "$BOT_MERGE" | head -1 | cut -d: -f1)

# ── 2. Extract the real auto-close block verbatim (INFRA-1030 .. INFRA-193) ──
_AC_START=$(grep -n '── INFRA-1030: Auto-close gap AFTER auto-merge arm' "$BOT_MERGE" | head -1 | cut -d: -f1)
_AC_END_MARKER=$(grep -n '── INFRA-193: speculative-execution loser sweep' "$BOT_MERGE" | head -1 | cut -d: -f1)

if [[ -z "$_ERR_START" || -z "$_ERR_END" || -z "$_AC_START" || -z "$_AC_END_MARKER" ]]; then
    fail "could not locate extraction anchors (err_handler=[$_ERR_START,$_ERR_END] autoclose=[$_AC_START,$_AC_END_MARKER]) — bot-merge.sh restructured, update anchors"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
ok "extraction anchors located in bot-merge.sh (err_handler + auto-close block)"

_AC_END=$(( _AC_END_MARKER - 1 ))
sed -n "${_ERR_START},${_ERR_END}p" "$BOT_MERGE" > "$TMP/err_handler.sh"
sed -n "${_AC_START},${_AC_END}p" "$BOT_MERGE" > "$TMP/autoclose_block.sh"

# ── 3. Stub `chump` — a shell/doc PR payload's ship call succeeds instantly ──
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "gap" && "$2" == "ship" ]]; then echo "shipped ok"; exit 0; fi
if [[ "$1" == "pr" && "$2" == "ac-coverage" ]]; then echo '{"status":"ok"}'; exit 0; fi
if [[ "$1" == "gap" && "$2" == "list" ]]; then echo '[]'; exit 0; fi
exit 0
STUB
chmod +x "$TMP/bin/chump"

# ── 4. Assemble the harness: real err handler + real auto-close block, ───────
# lightweight stand-ins for the surrounding stage/logging helpers, and a
# synthetic shell/doc PR payload (GAP_IDS + TARGET_PR — the two inputs the
# auto-close block actually reads).
cat > "$TMP/harness.sh" <<HARNESS
#!/usr/bin/env bash
set -euo pipefail
export PATH="$TMP/bin:\$PATH"
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
export REPO_ROOT="$TMP/work"
export MAIN_REPO="$TMP/work"
LOCK_DIR="$TMP/work/.chump-locks"
mkdir -p "\$LOCK_DIR" "$TMP/work/.chump"

# Synthetic shell/doc PR payload: a doc-only fastpath PR (INFRA-920) closing
# one gap, no Rust files touched.
DRY_RUN=0
CHUMP_AUTO_CLOSE_GAP=1
CHUMP_BENCH_MODE=0
CHUMP_VERIFY_LIVE_BLOCKING=0
GAP_IDS=("CREDIBLE-801-DOC-SHELL-PAYLOAD")
TARGET_PR=999001
_BM_NAMED_STEP=""

green()  { printf '[green] %s\n' "\$*"; }
red()    { printf '[red] %s\n' "\$*"; }
yellow() { printf '[yellow] %s\n' "\$*"; }
info()   { printf '[info] %s\n' "\$*"; }
stage_start() { __STAGE_LABEL="\$1"; info "stage_start: \$1"; }
stage_done()  { info "stage_done: \${__STAGE_LABEL:-}"; }
run_timed_hb() { local label=\$1 max_secs=\$2; shift 2; "\$@"; }

# The realistic trigger: a shell/doc-only-fastpath runner whose TMPDIR is
# full/unwritable. mktemp fails; the block has exactly one unguarded mktemp
# call.
export TMPDIR="$TMP/no-such-tmpdir"

source "$TMP/err_handler.sh"
source "$TMP/autoclose_block.sh"
echo "HARNESS COMPLETED WITHOUT DYING"
HARNESS
chmod +x "$TMP/harness.sh"
ok "harness assembled: real ERR trap + real auto-close block + shell/doc PR payload (GAP_IDS/TARGET_PR)"

# ── 5. Run it ──────────────────────────────────────────────────────────────
_HOUT="$TMP/harness_stdout.log"
_hrc=0
"$TMP/harness.sh" > "$_HOUT" 2>&1 || _hrc=$?

if grep -q '^\[info\] stage_start: auto-close gap CREDIBLE-801-DOC-SHELL-PAYLOAD' "$_HOUT"; then
    ok "AC#1: harness invoked the auto-close stage with the shell/doc PR payload"
else
    fail "AC#1: auto-close stage was never entered — harness payload wiring is broken: $(cat "$_HOUT")"
fi

# The desired/correct behavior is a clean auto-close: no uncaught error, PR
# ship runs. That is the assertion below — and it currently FAILS (AC#2),
# because bot_merge_uncaught_error fires (see docstring for root cause: the
# unguarded `_tmpship=$(mktemp)` call) before `chump gap ship` ever runs.
# This is intentionally a red test — it locks in the reproduction until the
# mktemp guard lands, at which point it flips green without modification.
if [[ -f "$TMP/ambient.jsonl" ]] && grep -q '"kind":"bot_merge_uncaught_error"' "$TMP/ambient.jsonl"; then
    fail "AC#2: kind=bot_merge_uncaught_error emitted during auto-close for a shell/doc PR payload (known defect, see docstring): $(grep '\"kind\":\"bot_merge_uncaught_error\"' "$TMP/ambient.jsonl")"
    if grep '"kind":"bot_merge_uncaught_error"' "$TMP/ambient.jsonl" | grep -q '"cmd":"_tmpship=\$(mktemp)"'; then
        echo "  (confirmed: fires at the unguarded mktemp call, BEFORE chump gap ship runs — before any changes)"
    fi
    if ! grep -q 'shipped ok' "$_HOUT"; then
        echo "  (confirmed: no ship/close mutation occurred — the gap silently never got its auto-close)"
    fi
else
    ok "AC#2: auto-close completed cleanly for the shell/doc PR payload — no bot_merge_uncaught_error (defect fixed)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
echo "(this test is expected to FAIL until the mktemp guard lands — see docstring)"
[[ "$FAIL" -eq 0 ]]
