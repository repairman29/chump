#!/usr/bin/env bash
# agent-tool-smoke.sh (INFRA-3452) — the deploy-time receipt check.
#
# Runs a table of CRITICAL tools through a real chump --acp agent turn and
# asserts each is actually INVOKED with outcome=ok. This is the automated form
# of the manual verification that caught the comprehend_repo profile gap: a tool
# can be registered, in a profile, and present in the binary while the agent
# still cannot call it — only a live invocation proves reachability.
#
# NOT a per-commit CI gate: it drives an LLM (slow, model-dependent). Run it on
# deploy, nightly, or on demand.
#
# Usage:
#   scripts/dev/agent-tool-smoke.sh [--bin <chump>] [--repo <cwd>]
#   CHUMP_SMOKE_TOOLS="comprehend_repo:/path/to/repo grep_repo:" overrides the table.
#
# Each table entry is  <tool>:<target>  (target optional; passed as repo arg).

set -uo pipefail

BIN="${CHUMP_SMOKE_BIN:-/opt/homebrew/bin/chump}"
REPO="${CHUMP_SMOKE_REPO:-/Users/jeffadkins/Projects/Chump}"
DRIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/acp_invoke.py"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin) BIN="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Critical tools every deployed agent must be able to reach. <tool>:<target>.
DEFAULT_TABLE="comprehend_repo:/Users/jeffadkins/Projects/olive grep_repo: almanac_search:"
read -r -a TABLE <<< "${CHUMP_SMOKE_TOOLS:-$DEFAULT_TABLE}"

echo "=== agent-tool-invocation smoke ==="
echo "  bin:  $BIN"
echo "  repo: $REPO"
echo "  tools: ${#TABLE[@]}"
echo ""

fails=0
for entry in "${TABLE[@]}"; do
  tool="${entry%%:*}"
  target="${entry#*:}"
  [[ "$target" == "$tool" ]] && target=""
  printf '  %-18s ' "$tool"
  out="$(python3 "$DRIVER" --bin "$BIN" --repo "$REPO" --tool "$tool" ${target:+--target "$target"} 2>/dev/null)"
  rc=$?
  invoked="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("invoked"))' 2>/dev/null)"
  outcome="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("outcome"))' 2>/dev/null)"
  if [[ "$rc" -eq 0 ]]; then
    echo "✓ invoked, outcome=$outcome"
  else
    echo "✗ NOT reachable (invoked=$invoked outcome=$outcome) — check profile/registration/gate"
    fails=$((fails + 1))
  fi
done

echo ""
if [[ "$fails" -gt 0 ]]; then
  echo "FAIL: $fails critical tool(s) the agent could not invoke."
  echo "This is the comprehend_repo-profile-gap class — the tool exists but isn't reachable."
  exit 1
fi
echo "OK: every critical tool was invoked by the live agent with outcome=ok."
