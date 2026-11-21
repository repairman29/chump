#!/usr/bin/env bash
# scripts/ci/test-broadcast-feedback-fanout.sh — META-158
#
# Smoke tests: verify broadcast.sh FEEDBACK fan-out-to-inbox behaviour
# when CHUMP_FLEET_RECV_SIDE_V0=1 is set.
#
# AC coverage:
#   AC1  — when --to unset + event=FEEDBACK + kind in (proposal,preference,defect,retro)
#           + CHUMP_FLEET_RECV_SIDE_V0=1 → expand recipients via .curator-opus-*.lock glob
#   AC2  — --no-fanout flag suppresses fan-out → silent no-op for inbox (legacy)
#   AC3  — 3 fake .curator-opus-{foo,bar,baz}.lock files → 3 inbox files written with same JSON
#   AC4  — zero matching .lock files → WARN printed, exits 0, ambient still written
#   AC5  — --no-fanout + --to unset → silent no-op (no inbox write, no WARN)
#   AC6  — existing --to <session-id> path unchanged; inbox written to that session only
#   AC7  — feature flag off (CHUMP_FLEET_RECV_SIDE_V0 unset/0) → silent no-op (legacy)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BROADCAST="$REPO_ROOT/scripts/coord/broadcast.sh"
[[ -x "$BROADCAST" ]] || { echo "[FAIL] broadcast.sh not executable at $BROADCAST" >&2; exit 1; }

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stand up a minimal git sandbox so broadcast.sh's git calls succeed.
SANDBOX="$TMP/repo"
mkdir -p "$SANDBOX/.chump-locks/inbox"
git -C "$TMP" init -q "$SANDBOX"
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

LOCK_DIR="$SANDBOX/.chump-locks"
AMBIENT="$LOCK_DIR/ambient.jsonl"
FEEDBACK_LOG="$LOCK_DIR/feedback.jsonl"
INBOX_DIR="$LOCK_DIR/inbox"

# Helper: run broadcast.sh in the sandbox with feature flag ON by default.
run_broadcast() {
    (
        cd "$SANDBOX"
        CHUMP_SESSION_ID="test-$$" \
        CHUMP_REPO="$SANDBOX" \
        CHUMP_FLEET_RECV_SIDE_V0=1 \
            "$BROADCAST" "$@"
    ) 2>&1
}

# Helper: run broadcast.sh with feature flag OFF.
run_broadcast_flag_off() {
    (
        cd "$SANDBOX"
        CHUMP_SESSION_ID="test-$$" \
        CHUMP_REPO="$SANDBOX" \
        CHUMP_FLEET_RECV_SIDE_V0=0 \
            "$BROADCAST" "$@"
    ) 2>&1
}

reset_sandbox() {
    rm -f "$AMBIENT" "$FEEDBACK_LOG"
    rm -f "$INBOX_DIR"/*.jsonl "$INBOX_DIR"/.*.lock 2>/dev/null || true
    # Remove any .curator-opus-*.lock sentinels from previous test.
    rm -f "$LOCK_DIR"/.curator-opus-*.lock 2>/dev/null || true
}

# ── Test 1: 3 lock files → 3 inbox files written (AC1, AC3) ─────────────────
reset_sandbox
touch "$LOCK_DIR/.curator-opus-foo.lock"
touch "$LOCK_DIR/.curator-opus-bar.lock"
touch "$LOCK_DIR/.curator-opus-baz.lock"

run_broadcast FEEDBACK proposal "meta-158-fanout-test" "rationale-text" 0

# ambient must be written
[[ -f "$AMBIENT" ]] || fail "AC1: ambient.jsonl not written"
grep -qE '"event"[[:space:]]*:[[:space:]]*"FEEDBACK"' "$AMBIENT" || fail "AC1: FEEDBACK event missing from ambient"

# feedback.jsonl must be written
[[ -f "$FEEDBACK_LOG" ]] || fail "AC1: feedback.jsonl not written"

# 3 inbox files must exist with FEEDBACK JSON
for curator in foo bar baz; do
    inbox_file="$INBOX_DIR/curator-opus-${curator}.jsonl"
    [[ -f "$inbox_file" ]] || fail "AC1/AC3: inbox file missing for curator-opus-${curator}: $inbox_file"
    grep -qE '"event"[[:space:]]*:[[:space:]]*"FEEDBACK"' "$inbox_file" \
        || fail "AC1/AC3: FEEDBACK JSON not written to curator-opus-${curator} inbox"
done
ok "AC1/AC3: 3 .curator-opus-*.lock files → 3 inbox files written with FEEDBACK JSON"

# ── Test 2: --no-fanout flag suppresses fan-out, no inbox write (AC2, AC5) ──
reset_sandbox
touch "$LOCK_DIR/.curator-opus-foo.lock"
touch "$LOCK_DIR/.curator-opus-bar.lock"

output="$(run_broadcast --no-fanout FEEDBACK proposal "test-nofanout" "rationale" 0)"

# ambient must still be written
[[ -f "$AMBIENT" ]] || fail "AC2: ambient.jsonl not written with --no-fanout"

# No inbox files should be written
inbox_count="$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$inbox_count" -eq 0 ]] || fail "AC2: inbox files written despite --no-fanout (count=$inbox_count)"

# No WARN about zero lock files should appear (silent no-op)
if echo "$output" | grep -q "WARN: FEEDBACK fan-out found 0"; then
    fail "AC2: unexpected WARN about zero lock files with --no-fanout"
fi
ok "AC2: --no-fanout suppresses inbox fan-out (ambient retained, no inbox write)"

# ── Test 3: zero .lock files → WARN printed, exits 0, ambient written (AC4) ─
reset_sandbox
# No .curator-opus-*.lock files present

output="$(run_broadcast FEEDBACK defect "test-zero-locks" "rationale" 0)"

[[ -f "$AMBIENT" ]] || fail "AC4: ambient.jsonl not written when zero lock files"
echo "$output" | grep -q "WARN: FEEDBACK fan-out found 0" \
    || fail "AC4: expected WARN about zero lock files, got: $output"

# No inbox files
inbox_count="$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$inbox_count" -eq 0 ]] || fail "AC4: unexpected inbox files when zero lock files"
ok "AC4: zero .curator-opus-*.lock files → WARN printed, exits 0, ambient retained"

# ── Test 4: --no-fanout + --to unset → silent no-op, no WARN (AC5) ──────────
reset_sandbox
# No lock files either

output="$(run_broadcast --no-fanout FEEDBACK retro "test-silent-noop" "rationale" 0)"

[[ -f "$AMBIENT" ]] || fail "AC5: ambient.jsonl not written"
inbox_count="$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$inbox_count" -eq 0 ]] || fail "AC5: inbox files written despite --no-fanout + no --to"
# Must be silent (no WARN about zero locks)
if echo "$output" | grep -q "WARN: FEEDBACK fan-out found 0"; then
    fail "AC5: unexpected WARN with --no-fanout (should be silent no-op)"
fi
ok "AC5: --no-fanout + --to unset → silent no-op, no WARN"

# ── Test 5: --to <session> with lock files → single-recipient, not fan-out (AC6) ─
reset_sandbox
touch "$LOCK_DIR/.curator-opus-foo.lock"
touch "$LOCK_DIR/.curator-opus-bar.lock"

run_broadcast --to "explicit-session-abc" FEEDBACK preference "test-explicit-to" "rationale" "+1"

# Only explicit-session-abc inbox should exist
explicit_inbox="$INBOX_DIR/explicit-session-abc.jsonl"
[[ -f "$explicit_inbox" ]] || fail "AC6: explicit --to inbox not written"
grep -qE '"event"[[:space:]]*:[[:space:]]*"FEEDBACK"' "$explicit_inbox" \
    || fail "AC6: FEEDBACK JSON missing from explicit --to inbox"

# curator inboxes must NOT be written
for curator in foo bar; do
    inbox_file="$INBOX_DIR/curator-opus-${curator}.jsonl"
    if [[ -f "$inbox_file" ]]; then
        fail "AC6: curator inbox written despite --to being set: $inbox_file"
    fi
done
ok "AC6: --to <session> → single-recipient inbox write only, no curator fan-out"

# ── Test 6: feature flag OFF → silent no-op for inbox (legacy, AC7) ─────────
reset_sandbox
touch "$LOCK_DIR/.curator-opus-foo.lock"

run_broadcast_flag_off FEEDBACK proposal "test-flag-off" "rationale" 0

[[ -f "$AMBIENT" ]] || fail "AC7: ambient.jsonl not written when flag off"

inbox_count="$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$inbox_count" -eq 0 ]] || fail "AC7: inbox files written despite CHUMP_FLEET_RECV_SIDE_V0=0"
ok "AC7: CHUMP_FLEET_RECV_SIDE_V0=0 → legacy silent no-op for inbox"

# ── Test 7: all 4 FEEDBACK kinds fan-out correctly ───────────────────────────
for fb_kind in proposal preference defect retro; do
    reset_sandbox
    touch "$LOCK_DIR/.curator-opus-alpha.lock"

    if [[ "$fb_kind" == "preference" ]]; then
        run_broadcast FEEDBACK "$fb_kind" "test-kind-${fb_kind}" "rationale" "+1"
    else
        run_broadcast FEEDBACK "$fb_kind" "test-kind-${fb_kind}" "rationale" 0
    fi

    inbox_file="$INBOX_DIR/curator-opus-alpha.jsonl"
    [[ -f "$inbox_file" ]] || fail "kind=$fb_kind: inbox not written for curator-opus-alpha"
    grep -qE '"kind"[[:space:]]*:[[:space:]]*"'"$fb_kind"'"' "$inbox_file" \
        || fail "kind=$fb_kind: kind field missing from inbox JSON"
done
ok "All 4 FEEDBACK kinds (proposal/preference/defect/retro) fan-out to inbox"

# ── Test 8: JSON content identical across all fan-out recipients ─────────────
reset_sandbox
touch "$LOCK_DIR/.curator-opus-x.lock"
touch "$LOCK_DIR/.curator-opus-y.lock"
touch "$LOCK_DIR/.curator-opus-z.lock"

run_broadcast FEEDBACK proposal "consistency-test" "rationale-consistency" 0

content_x="$(cat "$INBOX_DIR/curator-opus-x.jsonl" 2>/dev/null || true)"
content_y="$(cat "$INBOX_DIR/curator-opus-y.jsonl" 2>/dev/null || true)"
content_z="$(cat "$INBOX_DIR/curator-opus-z.jsonl" 2>/dev/null || true)"
[[ -n "$content_x" ]] || fail "consistency: curator-opus-x inbox empty"
[[ "$content_x" == "$content_y" ]] || fail "consistency: x vs y inbox content differs"
[[ "$content_x" == "$content_z" ]] || fail "consistency: x vs z inbox content differs"
ok "JSON content identical across all fan-out recipient inboxes"

echo
echo "All META-158 broadcast fan-out-to-inbox tests passed."
