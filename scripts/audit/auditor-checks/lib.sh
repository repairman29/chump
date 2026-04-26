#!/usr/bin/env bash
# scripts/audit/auditor-checks/lib.sh — shared helpers for auditor checks.
#
# Each check script sources this and emits findings as one JSON object per line
# on stdout. Logging goes to stderr. The file-findings.sh consumer reads stdin.
#
# Finding shape (all fields required):
#   {
#     "check":      "<check name, kebab-case>",
#     "key":        "<stable dedup key — same finding -> same key>",
#     "title":      "<under 70 chars; becomes the gap title>",
#     "description":"<one paragraph; becomes gap description body>",
#     "domain":     "<INFRA|EVAL|COG|MEM|DOC|FLEET|PRODUCT|RESEARCH|FRONTIER>",
#     "priority":   "<P0|P1|P2>",     // P2 default; P1 only if blocking work
#     "effort":     "<xs|s|m|l>",
#     "evidence":   ["<file:line>", "<commit-sha>", ...]
#   }
#
# The 'key' field is the dedup primitive. Same problem -> same key across runs.
# Format suggestion: "CHECK_NAME::SCOPED_IDENT::SOURCE_LOC"
# (e.g. "DEAD_GAP_REF::COG-077::src/agent_loop.rs:142")

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

emit_finding() {
    # emit_finding CHECK KEY TITLE DESCRIPTION DOMAIN PRIORITY EFFORT EVIDENCE_JSON_ARRAY
    local check="$1" key="$2" title="$3" desc="$4" domain="$5" prio="$6" effort="$7" evidence="$8"
    python3 -c "
import json, sys
print(json.dumps({
    'check':       sys.argv[1],
    'key':         sys.argv[2],
    'title':       sys.argv[3],
    'description': sys.argv[4],
    'domain':      sys.argv[5],
    'priority':    sys.argv[6],
    'effort':      sys.argv[7],
    'evidence':    json.loads(sys.argv[8]),
}, ensure_ascii=False))
" "$check" "$key" "$title" "$desc" "$domain" "$prio" "$effort" "$evidence"
}

log() {
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

# Returns space-separated list of all gap IDs from canonical .chump/state.db
# (via `chump gap list --json`). Falls back to docs/gaps.yaml if chump CLI is
# unavailable (CI without the binary), tolerating its known bad-escape artifacts.
all_gap_ids() {
    if command -v chump >/dev/null 2>&1; then
        chump gap list --json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(' '.join(g['id'] for g in d if g.get('id')))
"
    else
        python3 -c "
import yaml, re
with open('$REPO_ROOT/docs/gaps.yaml') as f:
    raw = f.read()
raw = re.sub(r'\\\\\\$', '\$', raw)  # strip bad \$ escapes from chump-gap-dump
data = yaml.safe_load(raw)
print(' '.join(g['id'] for g in data.get('gaps', []) if g.get('id')))
"
    fi
}

# Returns canonical gap data as JSON array. Same fallback as all_gap_ids.
all_gaps_json() {
    if command -v chump >/dev/null 2>&1; then
        chump gap list --json 2>/dev/null
    else
        python3 -c "
import yaml, json, re
with open('$REPO_ROOT/docs/gaps.yaml') as f:
    raw = f.read()
raw = re.sub(r'\\\\\\$', '\$', raw)
data = yaml.safe_load(raw)
print(json.dumps(data.get('gaps', [])))
"
    fi
}
