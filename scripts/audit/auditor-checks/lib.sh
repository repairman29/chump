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
# (via `chump gap list --json`). The previous python+yaml fallback against
# docs/gaps.yaml was retired in INFRA-242: post-INFRA-188 the YAML mirror is
# gone and the python fallback also lacked the `yaml` module on most CI hosts.
# The auditor depends on chump for everything else anyway — fail loud with an
# actionable install hint instead of pretending we have a working fallback.
all_gap_ids() {
    if ! command -v chump >/dev/null 2>&1; then
        echo "auditor: chump binary not found in PATH. Install with:" >&2
        echo "  cargo install --path . --bin chump --force" >&2
        echo "  (or add \$HOME/.local/bin to PATH)" >&2
        return 1
    fi
    chump gap list --json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(' '.join(g['id'] for g in d if g.get('id')))
"
}

# Returns canonical gap data as JSON array. Requires the chump binary; see
# all_gap_ids for the rationale (INFRA-242 retired the python+yaml fallback).
all_gaps_json() {
    if ! command -v chump >/dev/null 2>&1; then
        echo "auditor: chump binary not found in PATH. Install with:" >&2
        echo "  cargo install --path . --bin chump --force" >&2
        echo "  (or add \$HOME/.local/bin to PATH)" >&2
        return 1
    fi
    chump gap list --json 2>/dev/null
}
