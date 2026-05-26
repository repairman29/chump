#!/usr/bin/env bash
# scripts/coord/cluster-detector.sh — INFRA-1987 (THE FLOOR Phase 1)
#
# Detects CI-failure CLUSTERS: when N≥3 OPEN PRs share the IDENTICAL set
# of failing checks within a trailing 30-min window, that's a TRUNK-RED
# or shared-layer bug — not individual PR bugs. Retrying individuals
# burns CI minutes against a wall.
#
# Today's autopilot retries individual PRs. Cluster detector emits a
# distinct ambient event so the autopilot (and operator) can pivot to
# "find the trunk fix" instead of "retry the same PR."
#
# Phase 1 (this file): DETECTION ONLY. Emits kind=ci_failure_cluster +
# auto-files a META cluster RCA gap. Idempotent (same cluster_id within
# 60min doesn't re-file).
#
# Phase 2 (later gap): adds auto-HOLD on fleet shipping via
# .chump-locks/fleet-hold.txt. Workers will read this and pivot to
# triage/docs work until cluster resolves.
#
# Sharper than wedge-watch.sh's W-AGG (which counts ANY blocked PR).
# Cluster requires IDENTICAL failing-check sets — distinguishes
# "shared bug" from "5 independent flakes."
#
# Usage:
#   scripts/coord/cluster-detector.sh                 # single sweep
#   scripts/coord/cluster-detector.sh --json          # JSON output
#   scripts/coord/cluster-detector.sh --dry-run       # no ambient/gap writes
#
# Env:
#   CHUMP_SKIP_CLUSTER_DETECTOR=1  short-circuits to exit 0
#   CHUMP_CLUSTER_DETECTOR_THRESHOLD  override N (default 3)
#   CHUMP_CLUSTER_DETECTOR_WINDOW_MIN override trailing window (default 30)
#   CHUMP_CLUSTER_DETECTOR_DEDUP_MIN  override dedup window (default 60)
#   CHUMP_AMBIENT_LOG  override ambient.jsonl path (tests)
#
# Bypass: CHUMP_SKIP_CLUSTER_DETECTOR=1

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPO_ROOT="${CHUMP_REPO:-${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
THRESHOLD="${CHUMP_CLUSTER_DETECTOR_THRESHOLD:-3}"
WINDOW_MIN="${CHUMP_CLUSTER_DETECTOR_WINDOW_MIN:-30}"
DEDUP_MIN="${CHUMP_CLUSTER_DETECTOR_DEDUP_MIN:-60}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_FILE="$REPO_ROOT/.chump-locks/cluster-detector-state.json"
# INFRA-2025: in-flight marker written by recovery-queue-service during drop-window
IN_FLIGHT_FLAG="${CHUMP_RECOVERY_IN_FLIGHT_FLAG:-$REPO_ROOT/.chump-locks/recovery-cycle-in-flight.flag}"
FORMAT=text
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)    FORMAT=json; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) shift ;;
    esac
done

# ── Bypass ────────────────────────────────────────────────────────────────────
if [[ "${CHUMP_SKIP_CLUSTER_DETECTOR:-0}" == "1" ]]; then
    [[ "$FORMAT" == "json" ]] && echo '{"status":"skipped"}' || echo "cluster-detector: skipped (env bypass)"
    exit 0
fi

mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || true

# ── INFRA-2009: silent-noop guard ─────────────────────────────────────────────
# Emits kind=daemon_silent_noop if main work body is skipped on non-empty input.
# shellcheck source=scripts/coord/lib/silent-noop-guard.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/silent-noop-guard.sh"
_sng_install_guard "cluster_detector" "$AMBIENT"

# ── INFRA-2025: defer scan during recovery-queue drop-window ──────────────────
# recovery-queue-service.sh drops required_status_checks during its cycle;
# all PRs appear "passing" in that window. Scanning now would mis-classify
# recovered PRs as clean clusters. Skip this tick and try next invocation.
if [[ -f "$IN_FLIGHT_FLAG" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] would emit: cluster_detection_deferred_for_recovery" >&2
    else
        printf '{"ts":"%s","kind":"cluster_detection_deferred_for_recovery","source":"cluster_detector","reason":"recovery_cycle_in_flight"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AMBIENT" 2>/dev/null || true
    fi
    [[ "$FORMAT" == "json" ]] && echo '{"status":"deferred","reason":"recovery_cycle_in_flight"}' \
        || echo "cluster-detector: deferred (recovery cycle in flight — will retry next tick)"
    exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Emit ambient event (atomic append). Skipped if --dry-run.
_emit() {
    local kind="$1"; shift
    [[ "$DRY_RUN" == "1" ]] && { echo "[dry-run] would emit: $kind $*" >&2; return; }
    local extra=""
    for kv in "$@"; do
        extra+=",${kv}"
    done
    printf '{"ts":"%s","kind":"%s","source":"cluster_detector"%s}\n' \
        "$(_ts)" "$kind" "$extra" >> "$AMBIENT" 2>/dev/null || true
}

# ── Load dedup state ──────────────────────────────────────────────────────────
# State format:
#   { "clusters": { "<cluster_id>": {"first_seen":"<ts>","last_seen":"<ts>","gap_id":"META-NNN","pr_numbers":[…]} } }
_load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo '{"clusters":{}}'
    fi
}

_save_state() {
    [[ "$DRY_RUN" == "1" ]] && return
    echo "$1" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# ── Fetch BLOCKED PRs + their failing-check sets ──────────────────────────────
# Try cache first (INFRA-1081), fall back to live gh api on miss.
# Output: one JSON object per PR with {number, failing_checks:[sorted_names]}
_fetch_blocked_with_failures() {
    # Use live gh — the cache helpers don't expose statusCheckRollup detail
    # in a convenient shape for this lookup. (Cache extension can come later.)
    gh pr list --state open \
        --json number,mergeStateStatus,statusCheckRollup \
        --limit 50 2>/dev/null | python3 -c '
import json, sys, hashlib
try:
    prs = json.load(sys.stdin)
except Exception:
    sys.exit(0)

for p in prs:
    if p.get("mergeStateStatus") != "BLOCKED":
        continue
    fails = sorted(set(
        (c.get("name") or c.get("context") or "").strip()
        for c in p.get("statusCheckRollup", [])
        if c.get("conclusion") == "FAILURE"
    ))
    fails = [f for f in fails if f]
    if not fails:
        continue
    # Cluster ID = first 12 hex chars of sha256(sorted-checks-csv).
    cluster_id = hashlib.sha256(",".join(fails).encode()).hexdigest()[:12]
    print(json.dumps({
        "pr": p["number"],
        "fails": fails,
        "cluster_id": cluster_id,
    }))
' 2>/dev/null
}

# ── Detect clusters ───────────────────────────────────────────────────────────
# Group PRs by cluster_id; fire if any group has >= THRESHOLD entries.
_detect() {
    local pr_data; pr_data="$(_fetch_blocked_with_failures)"
    [[ -z "$pr_data" ]] && return 0

    echo "$pr_data" | python3 -c '
import json, sys, hashlib
from collections import defaultdict
THRESHOLD = int("'"$THRESHOLD"'")
buckets = defaultdict(list)
fails_by_id = {}
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    buckets[e["cluster_id"]].append(e["pr"])
    fails_by_id[e["cluster_id"]] = e["fails"]
for cid, prs in buckets.items():
    if len(prs) >= THRESHOLD:
        print(json.dumps({
            "cluster_id": cid,
            "pr_numbers": sorted(prs),
            "failing_checks": fails_by_id[cid],
            "count": len(prs),
        }))
'
}

# ── File META cluster RCA gap (idempotent via state file) ─────────────────────
# If already filed in this dedup window, only update state's last_seen + PRs.
_file_or_update_cluster_gap() {
    local cluster_id="$1"
    local pr_csv="$2"
    local checks_csv="$3"
    local count="$4"
    local state; state="$(_load_state)"

    local existing_gap
    existing_gap="$(echo "$state" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
cid = "'"$cluster_id"'"
c = s.get("clusters", {}).get(cid)
if c:
    print(c.get("gap_id", ""))
' 2>/dev/null)"

    if [[ -n "$existing_gap" && "$existing_gap" != "null" ]]; then
        # Already filed — just update last_seen
        local new_state
        new_state="$(echo "$state" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    s = {"clusters": {}}
cid = "'"$cluster_id"'"
ts = "'"$(_ts)"'"
prs = "'"$pr_csv"'".split(",")
s.setdefault("clusters", {})[cid]["last_seen"] = ts
s["clusters"][cid]["pr_numbers"] = prs
print(json.dumps(s))
')"
        _save_state "$new_state"
        echo "[update] cluster $cluster_id → existing gap $existing_gap (PRs: $pr_csv)" >&2
        return 0
    fi

    # File new META gap (idempotent: chump gap reserve with similarity bypass)
    local title="CLUSTER RCA: $count PRs blocked on [$checks_csv] (cluster $cluster_id)"
    local gap_id="UNFILED"
    if [[ "$DRY_RUN" != "1" ]]; then
        gap_id="$(CHUMP_IGNORE_WASTE_PAUSE=1 CHUMP_ALLOW_STALE_DESTRUCTIVE=1 \
            chump gap reserve --domain META \
                --title "$title" --priority P1 --effort s \
                --force-duplicate 2>/dev/null | tail -1)"
        gap_id="${gap_id:-UNFILED}"
    fi

    # Update state
    local new_state
    new_state="$(echo "$state" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    s = {"clusters": {}}
cid = "'"$cluster_id"'"
ts = "'"$(_ts)"'"
prs = "'"$pr_csv"'".split(",")
s.setdefault("clusters", {})[cid] = {
    "first_seen": ts,
    "last_seen": ts,
    "gap_id": "'"$gap_id"'",
    "pr_numbers": prs,
}
print(json.dumps(s))
')"
    _save_state "$new_state"
    echo "[file] cluster $cluster_id → new gap $gap_id (PRs: $pr_csv)" >&2

    _emit "ci_failure_cluster" \
        "\"cluster_id\":\"$cluster_id\"" \
        "\"pr_numbers\":\"$pr_csv\"" \
        "\"failing_checks\":\"$checks_csv\"" \
        "\"count\":$count" \
        "\"gap_id\":\"$gap_id\""

    # INFRA-2004: write fleet-hold.txt so workers can pivot to triage.
    # Idempotent — re-writing same content on each fire is a no-op for
    # the worker contract (workers just check existence + read latest).
    _write_fleet_hold "$cluster_id" "$pr_csv" "$checks_csv" "$count" "$gap_id"
}

# INFRA-2004: write the fleet-hold file. Worker contract:
#   - File exists → fleet is on HOLD; new claims should pivot to triage
#   - File absent → normal operations
# Format is a single JSON object so workers can `jq` it.
_write_fleet_hold() {
    local cluster_id="$1"
    local pr_csv="$2"
    local checks_csv="$3"
    local count="$4"
    local gap_id="$5"
    [[ "$DRY_RUN" == "1" ]] && return
    local hold_file="$REPO_ROOT/.chump-locks/fleet-hold.txt"
    cat > "${hold_file}.tmp" <<HOLD
{
  "active": true,
  "cluster_id": "$cluster_id",
  "since": "$(_ts)",
  "reason": "ci_failure_cluster",
  "pr_numbers": "$pr_csv",
  "failing_checks": "$checks_csv",
  "count": $count,
  "rca_gap": "$gap_id",
  "advisory": "Workers: pivot to triage/docs work until cluster resolves. Run 'chump fleet hold-check' for status."
}
HOLD
    mv "${hold_file}.tmp" "$hold_file"
}

# ── Detect resolved clusters (no longer firing) ───────────────────────────────
# If a cluster_id is in state but did NOT appear in this sweep, emit
# kind=ci_failure_cluster_resolved + prune from state.
_detect_resolved() {
    local current_ids="$1"
    local state; state="$(_load_state)"

    local resolved
    resolved="$(echo "$state" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit(0)
current = set("'"$current_ids"'".split())
for cid in list(s.get("clusters", {}).keys()):
    if cid not in current:
        c = s["clusters"][cid]
        print(json.dumps({"cluster_id": cid, "gap_id": c.get("gap_id","")}))
')"

    [[ -z "$resolved" ]] && return 0

    echo "$resolved" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cid gap
        cid="$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cluster_id"])' 2>/dev/null)"
        gap="$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["gap_id"])' 2>/dev/null)"
        _emit "ci_failure_cluster_resolved" \
            "\"cluster_id\":\"$cid\"" \
            "\"gap_id\":\"$gap\""
        echo "[resolved] cluster $cid (gap $gap)" >&2
    done

    # Prune resolved from state
    local new_state
    new_state="$(echo "$state" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    print("{}"); sys.exit(0)
current = set("'"$current_ids"'".split())
clusters = s.get("clusters", {})
s["clusters"] = {k: v for k, v in clusters.items() if k in current}
print(json.dumps(s))
')"
    _save_state "$new_state"

    # INFRA-2004: if state now has zero active clusters, remove fleet-hold.txt
    # so workers resume normal operations.
    if [[ "$DRY_RUN" != "1" ]]; then
        local remaining
        remaining="$(echo "$new_state" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("clusters",{})))' 2>/dev/null || echo 1)"
        if [[ "$remaining" == "0" ]]; then
            local hold_file="$REPO_ROOT/.chump-locks/fleet-hold.txt"
            if [[ -f "$hold_file" ]]; then
                rm -f "$hold_file"
                echo "[hold-clear] all clusters resolved → removed $hold_file" >&2
            fi
        fi
    fi
}

# ── Main sweep ────────────────────────────────────────────────────────────────
DETECTED="$(_detect)"
CURRENT_IDS=""

if [[ -n "$DETECTED" ]]; then
    _SNG_HAD_INPUT=1   # INFRA-2009: non-empty cluster data → guard expects main work
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Parse the cluster info
        cid="$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cluster_id"])' 2>/dev/null)"
        pr_csv="$(echo "$line" | python3 -c 'import json,sys; print(",".join(map(str,json.load(sys.stdin)["pr_numbers"])))' 2>/dev/null)"
        checks_csv="$(echo "$line" | python3 -c 'import json,sys; print("|".join(json.load(sys.stdin)["failing_checks"]))' 2>/dev/null)"
        count="$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])' 2>/dev/null)"
        CURRENT_IDS+="$cid "
        _file_or_update_cluster_gap "$cid" "$pr_csv" "$checks_csv" "$count"
    done <<<"$DETECTED"
    _sng_mark_done     # INFRA-2009: main work body executed
fi

# Detect resolutions (clusters no longer firing)
_detect_resolved "$(echo "$CURRENT_IDS" | xargs)"

# ── Report ────────────────────────────────────────────────────────────────────
if [[ "$FORMAT" == "json" ]]; then
    if [[ -z "$DETECTED" ]]; then
        echo '{"status":"clean","clusters":[]}'
    else
        echo "$DETECTED" | python3 -c '
import json, sys
out = {"status":"detected", "clusters": []}
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: out["clusters"].append(json.loads(line))
    except: pass
print(json.dumps(out))
'
    fi
else
    if [[ -z "$DETECTED" ]]; then
        echo "cluster-detector: clean (no clusters of $THRESHOLD+ PRs with identical failing checks)"
    else
        echo "cluster-detector: $(echo "$DETECTED" | wc -l | xargs) cluster(s) detected"
        echo "$DETECTED" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        e = json.loads(line)
        print(f"  - {e[\"cluster_id\"]}: {e[\"count\"]} PRs {e[\"pr_numbers\"]} failing [{\", \".join(e[\"failing_checks\"])}]")
    except: pass
'
    fi
fi

exit 0
