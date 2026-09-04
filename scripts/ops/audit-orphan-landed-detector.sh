#!/usr/bin/env bash
# scripts/ops/audit-orphan-landed-detector.sh — INFRA-4535 (INFRA-1861 slice c)
#
# Detects NEWLY-landed register-without-emit orphans (EVENT_REGISTRY.yaml
# entries with no matching emit site anywhere in the tree) and emits
# kind=audit_orphan_landed for each one `chump pr-rescue`'s audit-orphan-prune
# step (src/pr_rescue.rs, INFRA-4535) hasn't already batched into an
# allowlist PR.
#
# Reuses scripts/ci/test-event-registry-coverage.sh's `report` mode as the
# ground truth for orphan detection instead of re-implementing the
# grep/YAML parsing — one source of truth for "what counts as an orphan".
#
# State: .chump-locks/audit-orphan-seen.json — the set of orphan kinds this
# detector has already emitted an event for. A kind only ever fires
# kind=audit_orphan_landed once per "landing" (until it's resolved — removed
# from the orphan set — and a NEW orphan with the same name lands again,
# which re-arms it, since the state file is rebuilt from the current orphan
# set union each run, not append-only).
#
# Usage:
#   bash scripts/ops/audit-orphan-landed-detector.sh
#
# Env (used by scripts/ci/test-audit-orphan-landed-detector.sh):
#   CHUMP_ORPHAN_DETECTOR_STATE            override state file path
#   CHUMP_ORPHAN_DETECTOR_AMBIENT          override ambient.jsonl path
#   CHUMP_ORPHAN_DETECTOR_COVERAGE_SCRIPT  override coverage script path
#
# Exit: always 0 — a detector, not a gate.
#
# scanner-anchor: "kind":"audit_orphan_landed"

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="${CHUMP_ORPHAN_DETECTOR_STATE:-$REPO_ROOT/.chump-locks/audit-orphan-seen.json}"
AMBIENT_LOG="${CHUMP_ORPHAN_DETECTOR_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
COVERAGE_SCRIPT="${CHUMP_ORPHAN_DETECTOR_COVERAGE_SCRIPT:-$REPO_ROOT/scripts/ci/test-event-registry-coverage.sh}"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$AMBIENT_LOG")"

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if [[ ! -f "$COVERAGE_SCRIPT" ]]; then
    echo "[audit-orphan-landed-detector] coverage script not found: $COVERAGE_SCRIPT — skipping" >&2
    exit 0
fi

# ── Current orphan set (ground truth: the coverage gate's own report mode) ──
current_orphans=$(CHUMP_REGISTRY_GATE_MODE=report bash "$COVERAGE_SCRIPT" 2>/dev/null \
    | sed -nE 's/^ *ORPHAN: //p' | sort -u)

if [[ -z "$current_orphans" ]]; then
    echo "[audit-orphan-landed-detector] no orphans on this tree"
    # Still clear stale state so a re-landed orphan of the same name re-arms.
    echo '[]' > "$STATE_FILE"
    exit 0
fi

# ── Previously-seen set ──────────────────────────────────────────────────────
seen_json="[]"
[[ -f "$STATE_FILE" ]] && seen_json=$(cat "$STATE_FILE")
seen=$(python3 -c "
import json, sys
try:
    print('\n'.join(json.loads(sys.argv[1])))
except Exception:
    pass
" "$seen_json" 2>/dev/null | sort -u)

new_count=0
while IFS= read -r kind; do
    [[ -z "$kind" ]] && continue
    if ! grep -qxF "$kind" <<<"$seen"; then
        hash=$(python3 -c "import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:8])" "$kind")
        printf '{"ts":"%s","kind":"audit_orphan_landed","orphan_kind":"%s","hash":"%s"}\n' \
            "$(now_ts)" "$kind" "$hash" >> "$AMBIENT_LOG"
        echo "[audit-orphan-landed-detector] NEW orphan landed: $kind (hash $hash)"
        new_count=$((new_count + 1))
    fi
done <<<"$current_orphans"

# ── Persist updated seen-set = current orphan set (drops resolved orphans so
# a future re-landing of the same kind name re-fires) ───────────────────────
python3 -c "
import json, sys
current = [l for l in sys.argv[1].splitlines() if l]
print(json.dumps(sorted(set(current))))
" "$current_orphans" > "$STATE_FILE"

total=$(wc -l <<<"$current_orphans" | tr -d ' ')
echo "[audit-orphan-landed-detector] ${new_count} new orphan(s), ${total} total on tree"
exit 0
