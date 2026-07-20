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

printf '\n== Summary: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
