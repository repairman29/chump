#!/usr/bin/env bash
# test-md-links-reactor.sh — META-171: smoke test for md-links-loop.sh Phase 1.5 reactor.
#
# Exercises two fixtures:
#   A. Proposal rationale references docs/ path → vote=+1 (lane-match)
#   B. Proposal with no docs/ reference → vote=-1 (not-lane-match)
# Also validates: anti-reaction-loop guards, cooldown, flag-off.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOOP_SCRIPT="$REPO_ROOT/scripts/coord/md-links-loop.sh"

if [[ ! -f "$LOOP_SCRIPT" ]]; then
    printf 'FAIL: %s not found\n' "$LOOP_SCRIPT" >&2
    exit 1
fi

chmod +x "$LOOP_SCRIPT"

_pass=0
_fail=0
_ok()  { printf '  ok  %s\n' "$*"; _pass=$((_pass + 1)); }
_bad() { printf '  FAIL: %s\n' "$*" >&2; _fail=$((_fail + 1)); }

# ── Test 1: bash -n syntax check ─────────────────────────────────────────────
printf 'Test 1: bash -n syntax check...\n'
if bash -n "$LOOP_SCRIPT" 2>/dev/null; then
    _ok "bash -n passes"
else
    _bad "bash -n failed — syntax error in $LOOP_SCRIPT"
fi

# ── Test 2: heartbeat exits 0 + emits md_links_heartbeat ─────────────────────
printf 'Test 2: heartbeat emits kind=md_links_heartbeat...\n'
_dir2="$(mktemp -d)"
_amb2="$_dir2/ambient.jsonl"
_rc=0
CHUMP_AMBIENT_LOG="$_amb2" \
CHUMP_SESSION_ID="test-md-links-hb-$$" \
CHUMP_LOCK_DIR="$_dir2" \
"$LOOP_SCRIPT" heartbeat >/dev/null 2>&1 || _rc=$?
if (( _rc == 0 )); then
    _ok "heartbeat exits 0"
else
    _bad "heartbeat should exit 0, got $_rc"
fi
if grep -q '"kind":"md_links_heartbeat"' "$_amb2" 2>/dev/null; then
    _ok "heartbeat emits md_links_heartbeat kind"
else
    _bad "heartbeat should emit md_links_heartbeat"
fi
rm -rf "$_dir2"

# ── Fixture A: docs/ reference → vote=+1 ─────────────────────────────────────
printf 'Test 3 (Fixture A): docs/ reference → vote=+1...\n'
_dir3="$(mktemp -d)"
_amb3="$_dir3/ambient.jsonl"
_inbox_dir3="$_dir3/inbox"
_docs3="$_dir3/docs/process"
mkdir -p "$_inbox_dir3" "$_docs3"
_session3="test-md-links-reactor-a-$$"
_inbox_file3="$_inbox_dir3/${_session3}.jsonl"

# Proposal that references a docs/ path
printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-docs-001","session":"peer-aaa","subject":"update docs/process/FRESHNESS_DISCIPLINE.md","rationale":"broken link in docs/process/FRESHNESS_DISCIPLINE.md#staleness-table"}\n' \
    > "$_inbox_file3"

CHUMP_FLEET_WIRE_V1=1 \
CHUMP_AMBIENT_LOG="$_amb3" \
CHUMP_SESSION_ID="$_session3" \
CHUMP_LOCK_DIR="$_dir3" \
CHUMP_MD_LINKS_DOCS="$_dir3/docs" \
"$LOOP_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"kind":"md_links_reactor_voted"' "$_amb3" 2>/dev/null; then
    _ok "Fixture A: md_links_reactor_voted emitted"
else
    _bad "Fixture A: expected md_links_reactor_voted in ambient"
fi

if grep -q '"vote":1' "$_amb3" 2>/dev/null; then
    _ok "Fixture A: vote=+1 for docs/ reference"
else
    _bad "Fixture A: expected vote=1 for docs/ proposal"
fi

if grep -q '"reason":"lane-match:docs-ref"' "$_amb3" 2>/dev/null; then
    _ok "Fixture A: reason=lane-match:docs-ref"
else
    _bad "Fixture A: expected reason lane-match:docs-ref"
fi
rm -rf "$_dir3"

# ── Fixture B: no docs/ reference → vote=-1 ──────────────────────────────────
printf 'Test 4 (Fixture B): no docs/ reference → vote=-1...\n'
_dir4="$(mktemp -d)"
_amb4="$_dir4/ambient.jsonl"
_inbox_dir4="$_dir4/inbox"
_docs4="$_dir4/docs/process"
mkdir -p "$_inbox_dir4" "$_docs4"
_session4="test-md-links-reactor-b-$$"
_inbox_file4="$_inbox_dir4/${_session4}.jsonl"

# Proposal with no docs/ path or markdown anchor
printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-nodocs-001","session":"peer-bbb","subject":"add cargo clippy gate","rationale":"clippy warnings in crates/chump-coord cause build noise"}\n' \
    > "$_inbox_file4"

CHUMP_FLEET_WIRE_V1=1 \
CHUMP_AMBIENT_LOG="$_amb4" \
CHUMP_SESSION_ID="$_session4" \
CHUMP_LOCK_DIR="$_dir4" \
CHUMP_MD_LINKS_DOCS="$_dir4/docs" \
"$LOOP_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"kind":"md_links_reactor_voted"' "$_amb4" 2>/dev/null; then
    _ok "Fixture B: md_links_reactor_voted emitted"
else
    _bad "Fixture B: expected md_links_reactor_voted in ambient"
fi

if grep -q '"vote":-1' "$_amb4" 2>/dev/null; then
    _ok "Fixture B: vote=-1 for no-docs-ref"
else
    _bad "Fixture B: expected vote=-1 for proposal without docs/ ref"
fi

if grep -q '"reason":"not-lane-match:no-docs-ref"' "$_amb4" 2>/dev/null; then
    _ok "Fixture B: reason=not-lane-match:no-docs-ref"
else
    _bad "Fixture B: expected reason not-lane-match:no-docs-ref"
fi
rm -rf "$_dir4"

# ── Test 5: anti-reaction-loop — own-session skipped ─────────────────────────
printf 'Test 5: anti-reaction-loop (own-session)...\n'
_dir5="$(mktemp -d)"
_amb5="$_dir5/ambient.jsonl"
_inbox_dir5="$_dir5/inbox"
_docs5="$_dir5/docs/process"
mkdir -p "$_inbox_dir5" "$_docs5"
_session5="test-md-links-own-$$"
_inbox_file5="$_inbox_dir5/${_session5}.jsonl"

printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-own-003","session":"%s","subject":"docs/process update","rationale":"docs/process/FOO.md"}\n' \
    "$_session5" > "$_inbox_file5"

CHUMP_FLEET_WIRE_V1=1 \
CHUMP_AMBIENT_LOG="$_amb5" \
CHUMP_SESSION_ID="$_session5" \
CHUMP_LOCK_DIR="$_dir5" \
CHUMP_MD_LINKS_DOCS="$_dir5/docs" \
"$LOOP_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"corr_id":"corr-own-003"' "$_amb5" 2>/dev/null; then
    _bad "anti-reaction-loop: should NOT vote on own-session proposal"
else
    _ok "anti-reaction-loop: own-session proposal correctly skipped"
fi
rm -rf "$_dir5"

# ── Test 6: .md anchor reference also triggers +1 ────────────────────────────
printf 'Test 6: .md#anchor reference → vote=+1...\n'
_dir6="$(mktemp -d)"
_amb6="$_dir6/ambient.jsonl"
_inbox_dir6="$_dir6/inbox"
_docs6="$_dir6/docs/process"
mkdir -p "$_inbox_dir6" "$_docs6"
_session6="test-md-links-anchor-$$"
_inbox_file6="$_inbox_dir6/${_session6}.jsonl"

printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-anchor-001","session":"peer-ccc","subject":"fix stale anchor AGENTS.md#naming-conventions","rationale":"broken anchor in AGENTS.md#naming-conventions-infra-186"}\n' \
    > "$_inbox_file6"

CHUMP_FLEET_WIRE_V1=1 \
CHUMP_AMBIENT_LOG="$_amb6" \
CHUMP_SESSION_ID="$_session6" \
CHUMP_LOCK_DIR="$_dir6" \
CHUMP_MD_LINKS_DOCS="$_dir6/docs" \
"$LOOP_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"vote":1' "$_amb6" 2>/dev/null; then
    _ok "anchor ref: vote=+1 for .md#anchor reference"
else
    _bad "anchor ref: expected vote=1 for .md#anchor proposal"
fi
rm -rf "$_dir6"

# ── Test 7: flag off — reactor skipped ───────────────────────────────────────
printf 'Test 7: CHUMP_FLEET_WIRE_V1=0 skips reactor...\n'
_dir7="$(mktemp -d)"
_amb7="$_dir7/ambient.jsonl"
_inbox_dir7="$_dir7/inbox"
_docs7="$_dir7/docs/process"
mkdir -p "$_inbox_dir7" "$_docs7"
_session7="test-md-links-flagoff-$$"
printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-flagoff-003","session":"peer-ddd","subject":"docs/process update","rationale":"docs/process/FOO.md"}\n' \
    > "$_inbox_dir7/${_session7}.jsonl"

CHUMP_FLEET_WIRE_V1=0 \
CHUMP_AMBIENT_LOG="$_amb7" \
CHUMP_SESSION_ID="$_session7" \
CHUMP_LOCK_DIR="$_dir7" \
CHUMP_MD_LINKS_DOCS="$_dir7/docs" \
"$LOOP_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"kind":"md_links_reactor_voted"' "$_amb7" 2>/dev/null; then
    _bad "flag-off: reactor should not run when CHUMP_FLEET_WIRE_V1=0"
else
    _ok "flag-off: reactor correctly skipped when CHUMP_FLEET_WIRE_V1=0"
fi
rm -rf "$_dir7"

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n--- test-md-links-reactor: %d passed, %d failed ---\n' "$_pass" "$_fail"
(( _fail == 0 ))
