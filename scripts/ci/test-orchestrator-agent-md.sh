#!/usr/bin/env bash
# scripts/ci/test-orchestrator-agent-md.sh — INFRA-1940
#
# Smoke for .claude/agents/orchestrator.md (wizard role productization).
# Asserts the file exists, has the required frontmatter, references
# the 3 companion docs, names the 4 rings, and includes the directed-
# dispatch format block.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO/.claude/agents/orchestrator.md"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$TARGET" ]] || fail "$TARGET missing — INFRA-1940 not landed"
ok "orchestrator.md exists"

# ── Frontmatter ───────────────────────────────────────────────────────────
head -n 20 "$TARGET" | grep -q '^name: orchestrator' || fail "frontmatter missing name=orchestrator"
ok "frontmatter name=orchestrator"

head -n 20 "$TARGET" | grep -q '^description:' || fail "frontmatter missing description"
ok "frontmatter description present"

head -n 20 "$TARGET" | grep -q '^  - Monitor' || fail "tools list missing Monitor (required for inbox-watcher pattern)"
ok "tools list includes Monitor"

# ── Body — required companion-doc references ──────────────────────────────
for doc in "INBOX_WATCHER_PATTERN.md" "WIZARD_STRATEGIC_BACKLOG.md" "OPERATOR_PLAYBOOK.md" "ROADMAP"; do
    grep -q "$doc" "$TARGET" || fail "body missing reference to $doc"
done
ok "body references INBOX_WATCHER_PATTERN.md + WIZARD_STRATEGIC_BACKLOG.md + OPERATOR_PLAYBOOK.md + ROADMAP"

# ── Body — 4 rings named ──────────────────────────────────────────────────
for ring in "Ship" "Coordinate" "Retire" "Command"; do
    grep -qE "\\*\\*(${ring}|[0-9]+\\. ${ring})\\*\\*" "$TARGET" \
        || grep -qE "\\| \\*\\*[0-9]+\\. ${ring}\\*\\*" "$TARGET" \
        || fail "4-rings table missing $ring"
done
ok "4 rings named (Ship / Coordinate / Retire / Command)"

# ── Body — directed dispatch format block ─────────────────────────────────
grep -qiE "directed dispatch format|directed dispatch.*4th[ -]ring" "$TARGET" \
    || fail "body missing 'directed dispatch format' section"
ok "directed-dispatch format section present"

# ── Body — session-start protocol with inbox-watcher arm ──────────────────
grep -q "Monitor" "$TARGET" && grep -q "tail -F" "$TARGET" \
    || fail "session-start protocol missing Monitor + tail -F (per INBOX_WATCHER_PATTERN)"
ok "session-start protocol references Monitor + tail -F (INBOX_WATCHER_PATTERN compliance)"

# ── Body — hard rules ──────────────────────────────────────────────────────
grep -qiE "(never push to .main|do NOT free-claim|cap each iter)" "$TARGET" \
    || fail "body missing hard-rules section"
ok "hard-rules section present"

# ── Lineage / companion citation ──────────────────────────────────────────
grep -qE "(INFRA-1940|INFRA-1936|META-095|META-089)" "$TARGET" \
    || fail "body missing lineage/companion citations"
ok "lineage section cites INFRA-1940 + INFRA-1936 + META-095 + META-089"

echo ""
echo "ALL INFRA-1940 orchestrator-agent-md assertions passed."
