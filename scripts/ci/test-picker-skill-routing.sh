#!/usr/bin/env bash
# scripts/ci/test-picker-skill-routing.sh — INFRA-1829
# Picker consults .chump-locks/capabilities/*.jsonl: a gap whose skills_required
# match another live session's manifest (and not ours) is deferred to it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PICKER="$ROOT/scripts/dispatch/_pick_and_claim_gap.py"
PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/locks/capabilities" "$T/root/.chump"
AMB="$T/ambient.jsonl"; GAPS="$T/gaps.json"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
manifest() { # session skills_json
  printf '{"schema_version":"chump-capability-v1","session_id":"%s","skills":%s,"heartbeat_at":"%s","ttl_seconds":300}\n' \
    "$1" "$2" "$NOW" > "$T/locks/capabilities/$1.jsonl"
}
manifest sess-rust '["rust"]'
manifest sess-shell '["shell"]'

gap() { printf '{"id":"%s","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"[\\"%s\\"]","created_at":%s}' "$1" "$2" "$3"; }
printf '[%s,%s]' "$(gap INFRA-9101 rust 1000)" "$(gap INFRA-9102 shell 2000)" > "$GAPS"

pick() { # session env...
  local s="$1"; shift
  env PATH="$PATH" GAP_JSON_FILE="$GAPS" CHUMP_LOCK_DIR="$T/locks" CHUMP_SESSION_ID="$s" \
    CHUMP_FLEET_DRY_RUN=1 CHUMP_REBALANCE=0 CHUMP_ACTIVE_MISSION=NONE-0 WORKER_INDEX=1 \
    WORKER_SKILLS=rust,shell AMBIENT_JSONL="$AMB" REPO_ROOT="$T/root" \
    CHUMP_PICKER_OPEN_PR_FALLBACK=0 "$@" python3 -I "$PICKER" 2>/dev/null
}

check "rust session wins the rust gap" "$(pick sess-rust)" "INFRA-9101"
check "shell session defers rust gap, takes shell gap" "$(pick sess-shell)" "INFRA-9102"
check "CHUMP_SKILL_ROUTING=0 reverts to old ordering" "$(pick sess-shell CHUMP_SKILL_ROUTING=0)" "INFRA-9101"

printf '[%s]' "$(gap INFRA-9103 cuda 1000)" > "$GAPS"; : > "$AMB"
check "no match falls back to picking the gap" "$(pick sess-shell)" "INFRA-9103"
if grep -q '"kind": *"skill_routing_no_match"' "$AMB" && grep -q INFRA-9103 "$AMB"; then
  ok "skill_routing_no_match emitted"; else bad "skill_routing_no_match missing"; fi

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
