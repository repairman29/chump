#!/usr/bin/env bash
# test-inbox-watcher-pattern.sh — INFRA-1936
#
# Verifies that every productized curator role's .claude/agents/<role>.md
# contains the session-start inbox-watcher arm block (per INFRA-1936).
#
# Asserts:
#   1. Each role file present in .claude/agents/ contains a section titled
#      "Session start" with the FIRST-action instruction
#   2. The section includes a Monitor invocation (Claude Code) OR equivalent
#      file-watcher reference (harness-agnostic)
#   3. The section references `.chump-locks/inbox/<SESSION-ID>.jsonl` (the
#      canonical inbox path)
#   4. The section cross-references docs/process/INBOX_WATCHER_PATTERN.md
#
# Exit codes:
#   0 — all present agents have the watcher block
#   1 — at least one agent file is missing the block
#   2 — INBOX_WATCHER_PATTERN.md doc itself is missing (catastrophic)

set -uo pipefail

REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"

DOC="docs/process/INBOX_WATCHER_PATTERN.md"
AGENTS_DIR=".claude/agents"

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }
note() { SKIP=$((SKIP+1)); printf '  \033[33m·\033[0m %s\n' "$*"; }

# ── (0) catastrophic: the pattern doc must exist ─────────────────────────────
if [[ ! -f "$DOC" ]]; then
    printf '\033[31mFATAL\033[0m: %s missing — pattern undocumented\n' "$DOC" >&2
    exit 2
fi
printf '== Inbox-watcher pattern test (INFRA-1936) ==\n\n'
ok "$DOC exists"

# ── (1) every present agent file must include the watcher block ──────────────
# We test files that EXIST in the worktree. If the file is not yet productized
# (e.g. shepherd hasn't shipped yet), we skip (not fail) — the gap's scope is
# target + harvester per INFRA-1936's wizard-authorized slice. Other roles
# absorb the pattern as their .claude/agents/<role>.md sub-productizations
# land via META-097 sub-fleet.
ROLES=(target harvester shepherd ci-audit handoff decompose md-links orchestrator)
for role in "${ROLES[@]}"; do
    f="$AGENTS_DIR/$role.md"
    if [[ ! -f "$f" ]]; then
        note "$role.md not yet productized — skip (other 5 roles land via META-097)"
        continue
    fi

    printf '  -- checking %s --\n' "$f"

    # Assert "Session start" section heading present
    if grep -q "^## Session start" "$f"; then
        ok "  has '## Session start' section"
    else
        ko "  missing '## Session start' section"
        continue
    fi

    # Assert Monitor invocation OR file-watcher reference
    if grep -qE "Monitor\(|inotifywait|fswatch|tail -F" "$f"; then
        ok "  references a watcher primitive (Monitor / inotifywait / fswatch / tail -F)"
    else
        ko "  missing watcher primitive reference"
    fi

    # Assert canonical inbox path reference
    if grep -q ".chump-locks/inbox/" "$f"; then
        ok "  references .chump-locks/inbox/<SESSION-ID>.jsonl"
    else
        ko "  missing inbox path reference"
    fi

    # Assert cross-reference to the pattern doc
    if grep -q "INBOX_WATCHER_PATTERN.md" "$f"; then
        ok "  cross-references INBOX_WATCHER_PATTERN.md"
    else
        ko "  missing cross-reference to INBOX_WATCHER_PATTERN.md"
    fi
done

printf '\n== Summary: %d passed, %d failed, %d skipped ==\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
