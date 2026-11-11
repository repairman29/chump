#!/usr/bin/env bash
# INFRA-8059: node attribution — ambient host field + node-output query.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
CHUMP_AMBIENT_LOG="$T/a.jsonl" CHUMP_NODE_ID=cloud-test1 CHUMP_AGENT_HARNESS=manual \
    bash "$ROOT/scripts/dev/ambient-emit.sh" session_start gap=X-1 >/dev/null
grep -q '"host":"cloud-test1"' "$T/a.jsonl" || { echo "FAIL: host missing"; exit 1; }
CHUMP_AMBIENT_LOG="$T/b.jsonl" CHUMP_NODE_ID=cloud-test1 CHUMP_AGENT_HARNESS=manual \
    bash "$ROOT/scripts/dev/ambient-emit.sh" session_start host=explicit >/dev/null
[[ "$(grep -o '"host"' "$T/b.jsonl" | wc -l)" == 1 ]] || { echo "FAIL: duplicate host"; exit 1; }
source "$ROOT/scripts/lib/node-id.sh"
[[ "$(CHUMP_NODE_ID='a b' chump_node_id)" == "a_b" ]] || { echo "FAIL: sanitize"; exit 1; }
bash "$ROOT/scripts/dev/node-output.sh" --hours 1 --ref HEAD >/dev/null
echo "PASS test-node-attribution"
