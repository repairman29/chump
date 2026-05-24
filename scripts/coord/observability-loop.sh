#!/usr/bin/env bash
# scripts/coord/observability-loop.sh — META-103
#
# curator-opus-observability harness-neutral CLI.
# Audits ambient event-registry hygiene, reaper cadence coherence,
# api-cost leaderboard, and halt-class detector noise.
#
# Usage:
#   observability-loop.sh [tick]                # one full cycle (default)
#   observability-loop.sh audit-event-registry  # zero-emit / high-volume kinds
#   observability-loop.sh reaper-cadence-audit  # launchd daemon interval audit
#   observability-loop.sh cost-leaderboard-rollup  # top-3 api burners last 24h
#   observability-loop.sh detector-noise-rank   # top-20 kinds by emit-count 24h
#   observability-loop.sh status               # print last findings summary
#
# All findings emit kind=observability_finding to ambient.jsonl with:
#   {ts, kind="observability_finding", category, severity, kind_or_subject, detail}
#
# Rust-First-Bypass: bash-glue across event-registry / launchd / api-cost-leaderboard;
#   one-shot coordination script, < 200 LOC per function, no state mutation beyond
#   ambient emit.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_OVERRIDE:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
EVENT_REGISTRY="${CHUMP_OBS_EVENT_REGISTRY:-$REPO_ROOT/scripts/ci/event-registry-reserved.txt}"
COST_LEADERBOARD="$REPO_ROOT/scripts/dev/api-cost-leaderboard.sh"
LAUNCHAGENTS_DIR="${CHUMP_LAUNCHAGENTS_OVERRIDE:-$HOME/Library/LaunchAgents}"

# Thresholds (overridable via env)
ZERO_EMIT_DAYS="${CHUMP_OBS_ZERO_EMIT_DAYS:-7}"
HIGH_VOLUME_PER_DAY="${CHUMP_OBS_HIGH_VOLUME_PER_DAY:-100}"
BURNER_THRESHOLD="${CHUMP_OBS_BURNER_THRESHOLD:-500}"
NOISE_TOP_N="${CHUMP_OBS_NOISE_TOP_N:-20}"

# ── Helpers ──────────────────────────────────────────────────────────────────

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_emit_finding() {
    local category="$1" severity="$2" kind_or_subject="$3" detail="$4"
    local line
    line="$(printf '{"ts":"%s","kind":"observability_finding","category":"%s","severity":"%s","kind_or_subject":"%s","detail":"%s"}\n' \
        "$(_ts)" "$category" "$severity" "$kind_or_subject" "$detail")"
    echo "$line"
    if [[ -n "${AMBIENT}" && "${CHUMP_OBS_DRY_RUN:-0}" != "1" ]]; then
        echo "$line" >> "$AMBIENT"
    fi
}

_ambient_window_start() {
    # Returns a unix timestamp N days ago (portable: python3 fallback)
    local days="$1"
    python3 -c "import time; print(int(time.time() - ${days}*86400))"
}

# ── audit-event-registry ─────────────────────────────────────────────────────

cmd_audit_event_registry() {
    echo "=== audit-event-registry ==="

    if [[ ! -f "$EVENT_REGISTRY" ]]; then
        echo "WARN: event-registry-reserved.txt not found at $EVENT_REGISTRY" >&2
        return 0
    fi

    if [[ ! -f "$AMBIENT" ]]; then
        echo "INFO: no ambient.jsonl at $AMBIENT — skipping emit-count check"
        return 0
    fi

    # Parse registered kinds (skip blank + comment lines)
    local -a registered_kinds=()
    while IFS= read -r line; do
        # Strip inline comment, trim whitespace
        local kind
        kind="$(echo "$line" | sed 's/#.*//' | tr -d '[:space:]')"
        [[ -n "$kind" ]] && registered_kinds+=("$kind")
    done < "$EVENT_REGISTRY"

    # Count emits per kind in the last $ZERO_EMIT_DAYS days using python3
    local cutoff_ts
    cutoff_ts="$(_ambient_window_start "$ZERO_EMIT_DAYS")"

    # Build emit-count map from ambient.jsonl (python3 for speed on large files)
    local counts_json
    counts_json="$(python3 - "$AMBIENT" "$cutoff_ts" <<'PY'
import json, sys, collections
ambient_path, cutoff_str = sys.argv[1], int(sys.argv[2])
import time, datetime
counts = collections.Counter()
try:
    with open(ambient_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                ts_str = obj.get("ts", "")
                if ts_str:
                    try:
                        dt = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ")
                        epoch = int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())
                        if epoch >= cutoff_str:
                            k = obj.get("kind", "")
                            if k:
                                counts[k] += 1
                    except ValueError:
                        pass
            except json.JSONDecodeError:
                pass
except FileNotFoundError:
    pass
print(json.dumps(dict(counts)))
PY
)"

    local findings=0
    local per_day_window
    per_day_window="$ZERO_EMIT_DAYS"

    for kind in "${registered_kinds[@]}"; do
        local count
        count="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get(sys.argv[2], 0))" "$counts_json" "$kind" 2>/dev/null || echo 0)"

        if [[ "$count" -eq 0 ]]; then
            _emit_finding "zero_emit_kind" "proposal" "$kind" \
                "zero emits in last ${ZERO_EMIT_DAYS}d — consider removing from registry"
            findings=$((findings + 1))
        else
            # Check per-day rate
            local per_day
            per_day="$(python3 -c "print(int($count / max($per_day_window, 1)))")"
            if [[ "$per_day" -gt "$HIGH_VOLUME_PER_DAY" ]]; then
                _emit_finding "high_volume_kind" "warn" "$kind" \
                    "${per_day}/day over last ${ZERO_EMIT_DAYS}d exceeds threshold ${HIGH_VOLUME_PER_DAY}/day — consider cadence tighten"
                findings=$((findings + 1))
            fi
        fi
    done

    echo "audit-event-registry: ${#registered_kinds[@]} kinds checked, $findings finding(s)"
}

# ── reaper-cadence-audit ──────────────────────────────────────────────────────

cmd_reaper_cadence_audit() {
    echo "=== reaper-cadence-audit ==="

    # Find reaper/prune plists
    local -a plists=()
    if [[ -d "$LAUNCHAGENTS_DIR" ]]; then
        while IFS= read -r p; do
            plists+=("$p")
        done < <(find "$LAUNCHAGENTS_DIR" \( -name "com.chump.*reaper*.plist" -o -name "com.chump.*prune*.plist" \) 2>/dev/null | sort)
    fi

    if [[ "${#plists[@]}" -eq 0 ]]; then
        echo "INFO: no chump reaper/prune plists found in $LAUNCHAGENTS_DIR"
        return 0
    fi

    # Extract daemon name → interval (seconds) using python3 plistlib
    # Use parallel arrays (not associative) for bash 3.2 compat (macOS ships 3.2)
    local -a daemon_names=()
    local -a daemon_secs=()
    for plist in "${plists[@]}"; do
        local name
        name="$(basename "$plist" .plist)"
        local interval
        interval="$(python3 - "$plist" <<'PY' 2>/dev/null || echo ""
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        data = plistlib.load(f)
    si = data.get("StartInterval")
    if si is not None:
        print(int(si))
    else:
        # StartCalendarInterval: report as 86400 (daily) for comparison
        sci = data.get("StartCalendarInterval")
        if sci:
            print(86400)
        else:
            print("")
except Exception:
    print("")
PY
)"
        if [[ -n "$interval" ]]; then
            daemon_names+=("$name")
            daemon_secs+=("$interval")
            echo "  $name: ${interval}s"
        fi
    done

    local num_daemons="${#daemon_names[@]}"
    if [[ "$num_daemons" -lt 2 ]]; then
        echo "INFO: fewer than 2 daemons found — no cadence comparison possible"
        return 0
    fi

    # Flag incoherence: any two reapers with interval ratio > 4× are flagged
    local findings=0
    for ((i=0; i<num_daemons; i++)); do
        for ((j=i+1; j<num_daemons; j++)); do
            local a_name="${daemon_names[$i]}" b_name="${daemon_names[$j]}"
            local a_int="${daemon_secs[$i]}" b_int="${daemon_secs[$j]}"
            # Compute ratio (python3 for float division)
            local ratio
            ratio="$(python3 -c "
a,b = int('$a_int'), int('$b_int')
hi = max(a,b); lo = min(a,b)
if lo > 0:
    print(f'{hi/lo:.1f}')
else:
    print('0')
")"
            local ratio_int
            ratio_int="$(python3 -c "print(int(float('$ratio')))")"
            if [[ "$ratio_int" -gt 4 ]]; then
                _emit_finding "reaper_cadence_drift" "warn" "${a_name}/${b_name}" \
                    "interval ratio ${ratio}x (${a_int}s vs ${b_int}s) — reapers targeting similar populations should be within 4x"
                findings=$((findings + 1))
            fi
        done
    done

    echo "reaper-cadence-audit: ${#daemon_names[@]} daemons checked, $findings finding(s)"
}

# ── cost-leaderboard-rollup ───────────────────────────────────────────────────

cmd_cost_leaderboard_rollup() {
    echo "=== cost-leaderboard-rollup ==="

    if [[ ! -x "$COST_LEADERBOARD" ]]; then
        echo "WARN: $COST_LEADERBOARD not executable — skipping" >&2
        return 0
    fi

    local json_out
    json_out="$(CHUMP_AMBIENT_OVERRIDE="$AMBIENT" "$COST_LEADERBOARD" --window 24h --json 2>/dev/null || echo "[]")"

    if [[ "$json_out" == "[]" || -z "$json_out" ]]; then
        echo "INFO: no api-cost data in last 24h"
        return 0
    fi

    local findings=0
    # Parse top 3 by api_calls; flag if > BURNER_THRESHOLD
    python3 - "$json_out" "$BURNER_THRESHOLD" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
threshold = int(sys.argv[2])
sorted_data = sorted(data, key=lambda x: x.get("api_calls", x.get("calls", 0)), reverse=True)
for i, row in enumerate(sorted_data[:3]):
    calls = row.get("api_calls", row.get("calls", 0))
    script = row.get("script", "unknown")
    print(f"  #{i+1} {script}: {calls} calls/24h")
PY

    # Emit findings for top 3 burners above threshold
    python3 - <<PY
import json, sys, subprocess, os
data = json.loads('''$json_out''')
threshold = $BURNER_THRESHOLD
sorted_data = sorted(data, key=lambda x: x.get("api_calls", x.get("calls", 0)), reverse=True)
top3 = [r for r in sorted_data[:3] if r.get("api_calls", r.get("calls", 0)) > threshold]
for row in top3:
    calls = row.get("api_calls", row.get("calls", 0))
    script = row.get("script", "unknown")
    detail = f"{calls} api_calls/24h exceeds threshold {threshold} — audit for cache-first migration"
    print(f"FINDING api_burner alert {script} {detail}")
PY
    local burner_output
    burner_output="$(python3 - <<PY
import json
data = json.loads('''$json_out''')
threshold = $BURNER_THRESHOLD
sorted_data = sorted(data, key=lambda x: x.get("api_calls", x.get("calls", 0)), reverse=True)
top3 = [r for r in sorted_data[:3] if r.get("api_calls", r.get("calls", 0)) > threshold]
print(len(top3))
PY
)"
    findings="$burner_output"

    # Emit each burner as a finding
    while IFS= read -r line; do
        if [[ "$line" == FINDING* ]]; then
            read -r _ category severity kind_or_subject detail <<< "$line"
            _emit_finding "$category" "$severity" "$kind_or_subject" "$detail"
        fi
    done < <(python3 - <<PY
import json
data = json.loads('''$json_out''')
threshold = $BURNER_THRESHOLD
sorted_data = sorted(data, key=lambda x: x.get("api_calls", x.get("calls", 0)), reverse=True)
for row in sorted_data[:3]:
    calls = row.get("api_calls", row.get("calls", 0))
    if calls > threshold:
        script = row.get("script", "unknown")
        print(f"FINDING api_burner alert {script} {calls}_api_calls_per_24h_exceeds_threshold_{threshold}")
PY
)

    echo "cost-leaderboard-rollup: $findings finding(s) above ${BURNER_THRESHOLD} threshold"
}

# ── detector-noise-rank ───────────────────────────────────────────────────────

cmd_detector_noise_rank() {
    echo "=== detector-noise-rank ==="

    if [[ ! -f "$AMBIENT" ]]; then
        echo "INFO: no ambient.jsonl at $AMBIENT"
        return 0
    fi

    local cutoff_ts
    cutoff_ts="$(_ambient_window_start 1)"

    local findings=0
    local output
    output="$(python3 - "$AMBIENT" "$cutoff_ts" "$NOISE_TOP_N" "$HIGH_VOLUME_PER_DAY" <<'PY'
import json, sys, collections, datetime

ambient_path = sys.argv[1]
cutoff_ts = int(sys.argv[2])
top_n = int(sys.argv[3])
threshold = int(sys.argv[4])

counts = collections.Counter()
try:
    with open(ambient_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                ts_str = obj.get("ts", "")
                if ts_str:
                    try:
                        dt = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ")
                        epoch = int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())
                        if epoch >= cutoff_ts:
                            k = obj.get("kind", "")
                            if k:
                                counts[k] += 1
                    except ValueError:
                        pass
            except json.JSONDecodeError:
                pass
except FileNotFoundError:
    pass

findings = 0
print(f"Top {top_n} ambient kinds (last 24h):")
for i, (kind, count) in enumerate(counts.most_common(top_n), 1):
    flag = " [NOISY]" if count > threshold else ""
    print(f"  #{i:2d} {kind}: {count}/24h{flag}")
    if count > threshold:
        findings += 1

print(f"__findings__{findings}")
PY
)"

    echo "$output" | grep -v "^__findings__"
    findings="$(echo "$output" | grep "^__findings__" | cut -d_ -f3- | tr -d '_' || echo 0)"

    # Re-run to emit findings to ambient
    python3 - "$AMBIENT" "$cutoff_ts" "$NOISE_TOP_N" "$HIGH_VOLUME_PER_DAY" <<PY
import json, sys, collections, datetime

ambient_path = sys.argv[1]
cutoff_ts = int(sys.argv[2])
top_n = int(sys.argv[3])
threshold = int(sys.argv[4])

counts = collections.Counter()
try:
    with open(ambient_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                ts_str = obj.get("ts", "")
                if ts_str:
                    try:
                        dt = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ")
                        epoch = int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())
                        if epoch >= cutoff_ts:
                            k = obj.get("kind", "")
                            if k:
                                counts[k] += 1
                    except ValueError:
                        pass
            except json.JSONDecodeError:
                pass
except FileNotFoundError:
    pass

for kind, count in counts.most_common(top_n):
    if count > threshold:
        print(f"EMIT high_volume_kind warn {kind} {count}_emits_per_24h_exceeds_threshold_{threshold}_consider_cadence_tighten")
PY
    # Capture and emit findings
    while IFS= read -r line; do
        if [[ "$line" == EMIT* ]]; then
            read -r _ category severity kind_or_subject detail <<< "$line"
            _emit_finding "$category" "$severity" "$kind_or_subject" "$detail"
        fi
    done < <(python3 - "$AMBIENT" "$cutoff_ts" "$NOISE_TOP_N" "$HIGH_VOLUME_PER_DAY" <<'PY'
import json, sys, collections, datetime
ambient_path = sys.argv[1]
cutoff_ts = int(sys.argv[2])
top_n = int(sys.argv[3])
threshold = int(sys.argv[4])
counts = collections.Counter()
try:
    with open(ambient_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                ts_str = obj.get("ts", "")
                if ts_str:
                    try:
                        dt = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ")
                        epoch = int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())
                        if epoch >= cutoff_ts:
                            k = obj.get("kind", "")
                            if k:
                                counts[k] += 1
                    except ValueError:
                        pass
            except json.JSONDecodeError:
                pass
except FileNotFoundError:
    pass
for kind, count in counts.most_common(top_n):
    if count > threshold:
        print(f"EMIT high_volume_kind warn {kind} {count}_emits_per_24h_exceeds_threshold_{threshold}_consider_cadence_tighten")
PY
)

    echo "detector-noise-rank: $findings kind(s) above ${HIGH_VOLUME_PER_DAY}/day threshold"
}

# ── status ────────────────────────────────────────────────────────────────────

cmd_status() {
    echo "=== observability-loop status ==="
    echo "Lane: MEASUREMENT/TUNING of fleet-internal telemetry"
    echo "Event registry: $EVENT_REGISTRY"
    echo "Ambient: $AMBIENT"
    echo "LaunchAgents: $LAUNCHAGENTS_DIR"
    echo "Thresholds: zero_emit_days=${ZERO_EMIT_DAYS} high_volume/day=${HIGH_VOLUME_PER_DAY} burner=${BURNER_THRESHOLD} noise_top_n=${NOISE_TOP_N}"
    echo ""
    if [[ -f "$AMBIENT" ]]; then
        local recent_findings
        recent_findings="$(grep '"kind":"observability_finding"' "$AMBIENT" 2>/dev/null | tail -5 || true)"
        if [[ -n "$recent_findings" ]]; then
            echo "Recent findings (last 5):"
            echo "$recent_findings" | python3 -c "
import json,sys
for line in sys.stdin:
    try:
        obj = json.loads(line)
        print(f\"  [{obj.get('severity','?')}] {obj.get('category','?')}: {obj.get('kind_or_subject','?')} — {obj.get('detail','')}\" )
    except: pass
"
        else
            echo "No recent observability_finding events in ambient.jsonl"
        fi
    fi
}

# ── tick (full cycle) ─────────────────────────────────────────────────────────

cmd_tick() {
    echo "=== observability-loop tick: $(_ts) ==="
    cmd_audit_event_registry
    echo ""
    cmd_reaper_cadence_audit
    echo ""
    cmd_cost_leaderboard_rollup
    echo ""
    cmd_detector_noise_rank
    echo ""
    echo "=== tick complete: $(_ts) ==="
}

# ── Main dispatch ─────────────────────────────────────────────────────────────

SUBCOMMAND="${1:-tick}"
shift || true

case "$SUBCOMMAND" in
    tick)                   cmd_tick ;;
    audit-event-registry)   cmd_audit_event_registry ;;
    reaper-cadence-audit)   cmd_reaper_cadence_audit ;;
    cost-leaderboard-rollup) cmd_cost_leaderboard_rollup ;;
    detector-noise-rank)    cmd_detector_noise_rank ;;
    status)                 cmd_status ;;
    -h|--help)
        sed -n '1,/^set /p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
        exit 0 ;;
    *)
        echo "unknown subcommand: $SUBCOMMAND" >&2
        echo "usage: $0 [tick|audit-event-registry|reaper-cadence-audit|cost-leaderboard-rollup|detector-noise-rank|status]" >&2
        exit 2 ;;
esac
