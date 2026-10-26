#!/usr/bin/env bash
# test-inbox-watcher-pattern.sh — INFRA-1936, widened to full-fleet by MISSION-003
#
# Verifies that EVERY checked-in .claude/agents/<role>.md contains a
# session-start inbox-watcher arm block (per INBOX_WATCHER_PATTERN.md).
# MISSION-003 (curator-pillar-assignment-matrix) requires uniform
# event-driven wake across all curators — no more per-role skip list.
#
# Asserts, for each .claude/agents/*.md file:
#   1. A section heading matching "Session start" or "Session-start"
#   2. The section includes a Monitor invocation (Claude Code), a
#      file-watcher primitive (inotifywait/fswatch/tail -F), or an
#      inbox-read invocation (scripts/coord/chump-inbox.sh read) —
#      any of the harness-agnostic wake mechanisms documented in the
#      pattern doc
#   3. The section (or file) cross-references
#      docs/process/INBOX_WATCHER_PATTERN.md
#
# Exit codes:
#   0 — all agent files have the watcher block
#   1 — at least one agent file is missing the block
#   2 — INBOX_WATCHER_PATTERN.md doc itself is missing (catastrophic)

set -uo pipefail

REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"

DOC="docs/process/INBOX_WATCHER_PATTERN.md"
AGENTS_DIR=".claude/agents"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }

# ── (0) catastrophic: the pattern doc must exist ─────────────────────────────
if [[ ! -f "$DOC" ]]; then
    printf '\033[31mFATAL\033[0m: %s missing — pattern undocumented\n' "$DOC" >&2
    exit 2
fi
printf '== Inbox-watcher pattern test (INFRA-1936 / MISSION-003) ==\n\n'
ok "$DOC exists"

# ── (1) every checked-in agent file must include the watcher block ───────────
for f in "$AGENTS_DIR"/*.md; do
    [[ -f "$f" ]] || continue

    printf '  -- checking %s --\n' "$f"

    # Assert a "Session start" / "Session-start" section heading present
    if grep -qE "^## Session.?start" "$f"; then
        ok "  has a 'Session start' section"
    else
        ko "  missing a 'Session start' section"
        continue
    fi

    # Assert Monitor invocation, file-watcher reference, or inbox-read tick
    if grep -qE "Monitor\(|inotifywait|fswatch|tail -F|chump-inbox\.sh read" "$f"; then
        ok "  references a watcher primitive (Monitor / inotifywait / fswatch / tail -F / chump-inbox.sh read)"
    else
        ko "  missing watcher primitive reference"
    fi

    # Assert cross-reference to the pattern doc
    if grep -q "INBOX_WATCHER_PATTERN.md" "$f"; then
        ok "  cross-references INBOX_WATCHER_PATTERN.md"
    else
        ko "  missing cross-reference to INBOX_WATCHER_PATTERN.md"
    fi
done

# ── (2) INFRA-1941: inbox-watcher-nag.sh hook behavior ───────────────────────
printf '\n  -- checking scripts/hooks/inbox-watcher-nag.sh (INFRA-1941) --\n'
NAG_TMP="$(mktemp -d)"
trap 'rm -rf "$NAG_TMP"' EXIT
NAG_AMB="$NAG_TMP/ambient.jsonl"

CHUMP_LOCK_DIR="$NAG_TMP" AMBIENT_JSONL="$NAG_AMB" CHUMP_SESSION_ID="sess-1941" \
    bash "$REPO/scripts/hooks/inbox-watcher-nag.sh" 2>"$NAG_TMP/err1"
if grep -q '"kind":"inbox_watcher_missing"' "$NAG_AMB"; then
    ok "  missing heartbeat emits kind=inbox_watcher_missing"
else
    ko "  missing heartbeat did not emit kind=inbox_watcher_missing"
fi

touch "$NAG_TMP/inbox-watcher-sess-fresh.heartbeat"
: > "$NAG_AMB"
CHUMP_LOCK_DIR="$NAG_TMP" AMBIENT_JSONL="$NAG_AMB" CHUMP_SESSION_ID="sess-fresh" \
    bash "$REPO/scripts/hooks/inbox-watcher-nag.sh" 2>"$NAG_TMP/err2"
if [[ ! -s "$NAG_AMB" ]]; then
    ok "  fresh heartbeat produces no warning or emit"
else
    ko "  fresh heartbeat unexpectedly emitted to ambient"
fi

: > "$NAG_AMB"
CHUMP_LOCK_DIR="$NAG_TMP" AMBIENT_JSONL="$NAG_AMB" CHUMP_SESSION_ID="sess-optout" \
    CHUMP_INBOX_WATCHER_OPTOUT=1 bash "$REPO/scripts/hooks/inbox-watcher-nag.sh" 2>"$NAG_TMP/err3"
if grep -q '"kind":"inbox_watcher_opted_out"' "$NAG_AMB"; then
    ok "  CHUMP_INBOX_WATCHER_OPTOUT=1 emits kind=inbox_watcher_opted_out"
else
    ko "  CHUMP_INBOX_WATCHER_OPTOUT=1 did not emit kind=inbox_watcher_opted_out"
fi

# ── (3) INFRA-1948: A2A schema validation + lifecycle helpers ────────────────
printf '\n  -- checking scripts/coord/lib/a2a_schema.sh (INFRA-1948) --\n'
: > "$NAG_AMB"
if (
    export AMBIENT_JSONL="$NAG_AMB"
    source "$REPO/scripts/coord/lib/a2a_schema.sh"
    a2a_validate_message_json '{"from":"w1","to":"w2","ts":"2026-06-01T00:00:00Z","kind":"handoff","body":"ok"}'
); then
    ok "  valid A2A message passes schema validation"
else
    ko "  valid A2A message rejected by schema validation"
fi

if (
    export AMBIENT_JSONL="$NAG_AMB"
    source "$REPO/scripts/coord/lib/a2a_schema.sh"
    a2a_validate_message_json '{"from":"w1","to":"w2"}'
); then
    ko "  invalid A2A message (missing ts/kind/body) should fail validation"
else
    if grep -q '"kind":"a2a_msg_schema_violation"' "$NAG_AMB"; then
        ok "  invalid A2A message rejected + emits kind=a2a_msg_schema_violation"
    else
        ko "  invalid A2A message did not emit kind=a2a_msg_schema_violation"
    fi
fi

printf '\n== Summary: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
