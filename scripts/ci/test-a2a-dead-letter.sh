#!/usr/bin/env bash
# scripts/ci/test-a2a-dead-letter.sh — INFRA-1946
#
# Smoke test: scripts/coord/a2a-dead-letter-reaper.sh (INFRA-1862 slice C).
# Verifies:
#   (a) an unread message older than CHUMP_A2A_DEAD_LETTER_MIN in a dormant
#       inbox gets appended to .chump-locks/inbox/dead-letter.jsonl
#   (b) kind=a2a_msg_dead_lettered is emitted to ambient.jsonl for it
#   (c) a fresh (not-yet-old) unread message is left alone
#   (d) a message the recipient has already read (cursor past its offset)
#       is left alone even though it's old
#   (e) re-running the reaper does not duplicate the dead-letter entry
#   (f) when N dead-lettered messages in one run exceed
#       CHUMP_A2A_DEAD_LETTER_PAGE_THRESHOLD, operator-recall.sh is invoked
#       with --condition A2A_DEAD_LETTER_FLOOD (kind=operator_recall emitted)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
REAPER="$REPO_ROOT/scripts/coord/a2a-dead-letter-reaper.sh"

[[ -x "$REAPER" ]] || { echo "[FAIL] a2a-dead-letter-reaper.sh not executable at $REAPER" >&2; exit 1; }

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOCK_DIR="$TMP/.chump-locks"
INBOX_DIR="$LOCK_DIR/inbox"
AMBIENT="$LOCK_DIR/ambient.jsonl"
DEAD_LETTER="$INBOX_DIR/dead-letter.jsonl"
mkdir -p "$INBOX_DIR"

old_ts() {
    python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

run_reaper() {
    ( cd "$TMP" && CHUMP_REPO="$REPO_ROOT" LOCK_DIR="$LOCK_DIR" CHUMP_AMBIENT_PATH="$AMBIENT" \
        CHUMP_A2A_DEAD_LETTER_MIN="${A2A_MIN:-30}" \
        CHUMP_A2A_DEAD_LETTER_PAGE_THRESHOLD="${A2A_THRESHOLD:-5}" \
        "$REAPER" "$@" )
}

# ── fixtures ─────────────────────────────────────────────────────────────────
# (a)/(b) an old, unread message in a dormant inbox — no cursor file at all.
DORMANT_TS="$(old_ts 45)"
printf '{"ts":"%s","event":"WARN","session":"curator-x","reason":"unread dormant"}\n' \
    "$DORMANT_TS" > "$INBOX_DIR/dormant-session.jsonl"

# (c) a fresh unread message — should NOT be dead-lettered.
FRESH_TS="$(old_ts 2)"
printf '{"ts":"%s","event":"WARN","session":"curator-x","reason":"too fresh"}\n' \
    "$FRESH_TS" > "$INBOX_DIR/fresh-session.jsonl"

# (d) an old message that's already been read (cursor past its byte offset).
READ_LINE="$(printf '{"ts":"%s","event":"WARN","session":"curator-x","reason":"already read"}\n' "$(old_ts 60)")"
printf '%s' "$READ_LINE" > "$INBOX_DIR/read-session.jsonl"
printf '%s' "${#READ_LINE}" > "$INBOX_DIR/read-session.cursor"

A2A_MIN=30 A2A_THRESHOLD=5 run_reaper >"$TMP/run1.log" 2>&1 || fail "reaper run 1 exited non-zero: $(cat "$TMP/run1.log")"

# ── (a) dead-letter.jsonl grew for the dormant message ────────────────────────
[[ -f "$DEAD_LETTER" ]] || fail "(a) dead-letter.jsonl was not created: $(cat "$TMP/run1.log")"
grep -q '"to": *"dormant-session"' "$DEAD_LETTER" \
    || fail "(a) dead-letter.jsonl missing dormant-session entry: $(cat "$DEAD_LETTER")"
ok "(a) unread message older than threshold is appended to dead-letter.jsonl"

# ── (b) kind=a2a_msg_dead_lettered emitted ────────────────────────────────────
[[ -f "$AMBIENT" ]] || fail "(b) ambient.jsonl was not created: $(cat "$TMP/run1.log")"
DL_LINE="$(grep '"kind":"a2a_msg_dead_lettered"' "$AMBIENT" | grep 'dormant-session' || true)"
[[ -n "$DL_LINE" ]] || fail "(b) no a2a_msg_dead_lettered event for dormant-session in ambient: $(cat "$AMBIENT")"
ok "(b) kind=a2a_msg_dead_lettered emitted for the dead-lettered message"

# ── (c) fresh message left alone ──────────────────────────────────────────────
grep -q '"to": *"fresh-session"' "$DEAD_LETTER" \
    && fail "(c) fresh-session message was dead-lettered too early: $(cat "$DEAD_LETTER")"
ok "(c) message younger than CHUMP_A2A_DEAD_LETTER_MIN is left alone"

# ── (d) already-read message left alone ───────────────────────────────────────
grep -q '"to": *"read-session"' "$DEAD_LETTER" \
    && fail "(d) already-read message was dead-lettered: $(cat "$DEAD_LETTER")"
ok "(d) already-read message (cursor past its offset) is left alone"

# ── (e) re-run does not duplicate ─────────────────────────────────────────────
COUNT_BEFORE="$(wc -l < "$DEAD_LETTER" | tr -d ' ')"
A2A_MIN=30 A2A_THRESHOLD=5 run_reaper >"$TMP/run2.log" 2>&1 || fail "reaper run 2 exited non-zero: $(cat "$TMP/run2.log")"
COUNT_AFTER="$(wc -l < "$DEAD_LETTER" | tr -d ' ')"
[[ "$COUNT_BEFORE" == "$COUNT_AFTER" ]] \
    || fail "(e) re-run duplicated dead-letter entries: before=$COUNT_BEFORE after=$COUNT_AFTER"
ok "(e) re-running the reaper does not duplicate dead-letter entries"

# ── (f) flood threshold pages the operator ────────────────────────────────────
FLOOD_TMP="$TMP/flood"
FLOOD_LOCK_DIR="$FLOOD_TMP/.chump-locks"
FLOOD_INBOX_DIR="$FLOOD_LOCK_DIR/inbox"
FLOOD_AMBIENT="$FLOOD_LOCK_DIR/ambient.jsonl"
mkdir -p "$FLOOD_INBOX_DIR"
FLOOD_TS="$(old_ts 45)"
for i in 1 2 3 4 5 6; do
    printf '{"ts":"%s","event":"WARN","session":"curator-x","reason":"flood-%d"}\n' "$FLOOD_TS" "$i" \
        > "$FLOOD_INBOX_DIR/flood-$i.jsonl"
done
( cd "$FLOOD_TMP" && CHUMP_REPO="$REPO_ROOT" LOCK_DIR="$FLOOD_LOCK_DIR" CHUMP_AMBIENT_PATH="$FLOOD_AMBIENT" \
    CHUMP_A2A_DEAD_LETTER_MIN=30 CHUMP_A2A_DEAD_LETTER_PAGE_THRESHOLD=5 \
    "$REAPER" ) >"$TMP/flood.log" 2>&1 || fail "reaper flood run exited non-zero: $(cat "$TMP/flood.log")"

grep -q '"kind":"operator_recall"' "$FLOOD_AMBIENT" \
    || fail "(f) no operator_recall event after exceeding page threshold: $(cat "$FLOOD_AMBIENT" 2>/dev/null || echo MISSING)"
grep '"kind":"operator_recall"' "$FLOOD_AMBIENT" | grep -q 'A2A_DEAD_LETTER_FLOOD' \
    || fail "(f) operator_recall event missing condition=A2A_DEAD_LETTER_FLOOD"
ok "(f) exceeding CHUMP_A2A_DEAD_LETTER_PAGE_THRESHOLD invokes operator-recall --condition A2A_DEAD_LETTER_FLOOD"

echo "ALL a2a-dead-letter-reaper assertions passed."
