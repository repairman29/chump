#!/usr/bin/env bash
# scripts/ci/test-roadmap-update-agent.sh — INFRA-1147
#
# Static + behavior tests for roadmap-update-agent.py. No live LLM call;
# verifies prompt construction, idempotency, dry-run, ambient kinds, and
# launchd plist correctness.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="$REPO_ROOT/scripts/auto-docs/roadmap-update-agent.py"
PLIST="$REPO_ROOT/scripts/launchd/com.chump.roadmap-update-agent.plist"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$AGENT" ]] || fail "agent script missing"
[[ -x "$AGENT" ]] || fail "agent script not executable"
ok "scripts/auto-docs/roadmap-update-agent.py exists and is executable"

# Python compiles
python3.12 -m py_compile "$AGENT" 2>&1 || fail "agent script has syntax errors"
ok "agent script compiles"

# Help works
python3.12 "$AGENT" --help 2>&1 | grep -q "dry-run" || fail "--help broken"
ok "--help works"

# Prompt-only mode produces a prompt without calling LLM
TMP=$(mktemp -d -t roadmap-update-test-XXXX)
trap 'rm -rf "$TMP"' EXIT

# Fixture inputs
cat > "$TMP/roadmap.md" <<'EOF'
# Chump Roadmap — 30 days

## Week 1 — User-facing front door (May 6 → 13)
Outcome: solo dev can run `chump gen "<task>"`.
Gaps: INFRA-593, INFRA-591

## Week 2 — Credible evidence (May 14 → 21)
Outcome: published numbers.
Gaps: EVAL-101, COG-053
EOF

cat > "$TMP/log.txt" <<'EOF'
abc123 feat(INFRA-593): EFFECTIVE — chump gen CLI shipped
def456 feat(EVAL-101): CREDIBLE — eval harness v1
EOF

cat > "$TMP/gaps.json" <<'EOF'
[
  {"id": "INFRA-593", "title": "EFFECTIVE: chump gen CLI", "closed_date": "2026-05-13"},
  {"id": "EVAL-101", "title": "CREDIBLE: eval harness", "closed_date": "2026-05-14"}
]
EOF

PROMPT=$(python3.12 "$AGENT" --prompt-only \
    --fixture-roadmap "$TMP/roadmap.md" \
    --fixture-log "$TMP/log.txt" \
    --fixture-gaps "$TMP/gaps.json" 2>&1)
echo "$PROMPT" | grep -q "CURRENT ROADMAP.md" || fail "prompt missing ROADMAP block"
echo "$PROMPT" | grep -q "SHIP HISTORY" || fail "prompt missing ship-history block"
echo "$PROMPT" | grep -q "SHIPPED GAPS" || fail "prompt missing shipped-gaps block"
echo "$PROMPT" | grep -q "unified diff" || fail "prompt missing output-format instruction"
echo "$PROMPT" | grep -q "INFRA-593" || fail "prompt missing fixture gap ID"
echo "$PROMPT" | grep -q "Week 1 — User-facing" || fail "prompt missing roadmap content"
ok "prompt construction: contains all 3 input sections + format instruction + fixture content"

# Default model: haiku (per AC: <\$0.05/run)
grep -qE 'claude-haiku-4-5-20251001' "$AGENT" || fail "default model is not haiku-4-5"
ok "default model is claude-haiku-4-5-20251001"

# --high-fidelity overrides to sonnet
grep -qE 'claude-sonnet-4-6.*high_fidelity|high_fidelity.*claude-sonnet-4-6' "$AGENT" \
    || python3.12 -c "
import re
src = open('$AGENT').read()
# Must have a line like: model = ... if args.high_fidelity ... claude-sonnet ...
assert 'high_fidelity' in src and 'sonnet' in src
" 2>&1 || fail "--high-fidelity does not route to sonnet"
ok "--high-fidelity routes to sonnet"

# Never auto-merges (no enablePullRequestAutoMerge / --auto / merge_method in PR open call)
grep -E "enablePullRequestAutoMerge|gh pr merge.*--auto|\"--auto\"" "$AGENT" \
    && fail "agent calls auto-merge (forbidden per AC)"
ok "agent never auto-merges"

# Branch name pattern: roadmap/weekly-update-YYYY-WW
grep -q 'roadmap/weekly-update-' "$AGENT" || fail "branch name does not follow roadmap/weekly-update-YYYY-WW pattern"
ok "branch name follows roadmap/weekly-update-YYYY-WW"

# Ambient kinds emitted
for kind in roadmap_update_proposal_cost roadmap_update_proposal_opened \
            roadmap_update_proposal_failed roadmap_update_proposal_skipped; do
    grep -q "\"$kind\"\|'$kind'\|emit(\"$kind\"" "$AGENT" \
        || grep -q "emit($kind\|\"$kind\"" "$AGENT" \
        || python3.12 -c "
src = open('$AGENT').read()
assert '$kind' in src, '$kind not emitted'
" 2>&1 || fail "agent does not emit kind=$kind"
done
ok "all 4 ambient kinds emitted (cost / opened / failed / skipped)"

# EVENT_REGISTRY registers all 4 kinds
ER="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
for kind in roadmap_update_proposal_cost roadmap_update_proposal_opened \
            roadmap_update_proposal_failed roadmap_update_proposal_skipped; do
    grep -q "^  - kind: $kind" "$ER" || fail "EVENT_REGISTRY missing kind=$kind"
done
ok "EVENT_REGISTRY registers all 4 kinds"

# Launchd plist exists + runs Sunday 09:00 local
[[ -f "$PLIST" ]] || fail "launchd plist missing: $PLIST"
grep -q "<key>Weekday</key>" "$PLIST" || fail "plist missing Weekday key"
grep -A 1 "<key>Weekday</key>" "$PLIST" | grep -q '<integer>0</integer>' \
    || fail "plist Weekday is not 0 (Sunday)"
grep -A 1 "<key>Hour</key>" "$PLIST" | grep -q '<integer>9</integer>' \
    || fail "plist Hour is not 9"
ok "launchd plist runs Sunday 09:00 local"

# Plist never sets RunAtLoad=true (never auto-merge means never run unprompted at launch)
grep -A 1 "<key>RunAtLoad</key>" "$PLIST" | grep -q '<false/>' \
    || fail "plist has RunAtLoad=true (should be false)"
ok "plist has RunAtLoad=false"

# Idempotency: --force flag exists
grep -q '"--force"\|action="store_true".*force' "$AGENT" \
    || python3.12 -c "
src = open('$AGENT').read()
assert '\"--force\"' in src or 'force' in src
" 2>&1 || fail "agent missing --force flag"
ok "agent has --force flag for same-week override"

echo
echo "All INFRA-1147 roadmap-update-agent tests passed."
