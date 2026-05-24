#!/usr/bin/env bash
# opus-slot-tracker.sh — META-093
#
# Parallel sub-fleet slot tracker for the Opus shepherd /loop. Manages up to 3
# concurrent Sonnet sub-agent dispatches with 15-min fail-fast per-slot budget.
#
# Subcommands:
#   status                       — print current 3-slot state from .chump-locks/opus-slots.json
#   dispatch <GAP-ID>            — claim a free slot, record metadata, print dispatch envelope
#   reap                         — check fail-fast triggers on all in-flight slots, kill stalled
#   release <slot_id>            — manually release a slot (slot number 1-3)
#
# Fail-fast triggers (checked by reap):
#   (a) No lease created within 5 min of dispatch → kill + emit opus_slot_reaped
#   (b) No PR opened within 10 min of dispatch   → kill + emit opus_slot_reaped
#   (c) 15-min total budget exceeded              → kill + emit opus_slot_reaped
#
# Bypass:
#   CHUMP_OPUS_MAX_SLOTS=0   — disable slot dispatch entirely (self-implement only)
#   CHUMP_OPUS_MAX_SLOTS=1   — single-slot legacy mode
#
# Cap discipline: never exceeds 3 slots per Opus session.
#
# State file: .chump-locks/opus-slots.json
#   Array of up to 3 objects: {slot_id, agent_id, gap_id, dispatched_ts, last_progress_ts, pr_number}
#
# Usage:
#   bash scripts/coord/opus-slot-tracker.sh status
#   bash scripts/coord/opus-slot-tracker.sh dispatch INFRA-1234
#   bash scripts/coord/opus-slot-tracker.sh reap
#   bash scripts/coord/opus-slot-tracker.sh release 2

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

SLOTS_FILE="${CHUMP_OPUS_SLOTS_FILE:-$REPO_ROOT/.chump-locks/opus-slots.json}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-$(cat .chump-locks/.wt-session-id 2>/dev/null || echo opus-unknown)}"

# Bypass controls
MAX_SLOTS="${CHUMP_OPUS_MAX_SLOTS:-3}"

# Fail-fast thresholds (seconds)
LEASE_TIMEOUT_S="${CHUMP_OPUS_LEASE_TIMEOUT_S:-300}"    # 5 min — no lease created
PR_TIMEOUT_S="${CHUMP_OPUS_PR_TIMEOUT_S:-600}"           # 10 min — no PR opened
BUDGET_S="${CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S:-900}"     # 15 min — total budget

# ── Helpers ───────────────────────────────────────────────────────────────────

emit_ambient() {
    local kind="$1"; shift
    python3 -c "
import json, datetime, sys
payload = dict(zip(sys.argv[1::2], sys.argv[2::2]))
payload['ts'] = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
payload['kind'] = '$kind'
payload['session'] = '$SESSION_ID'
print(json.dumps(payload, separators=(',', ':')))
" "$@" >> "$AMBIENT" 2>/dev/null || true
}

now_epoch() {
    python3 -c "import time; print(int(time.time()))"
}

iso_to_epoch() {
    python3 -c "import datetime; print(int(datetime.datetime.fromisoformat('$1'.replace('Z','+00:00')).timestamp()))"
}

now_iso() {
    python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

load_slots() {
    if [[ -f "$SLOTS_FILE" ]]; then
        python3 -c "import json, sys; data=json.load(open('$SLOTS_FILE')); [print(json.dumps(s)) for s in data]" 2>/dev/null || true
    fi
}

load_slots_json() {
    if [[ -f "$SLOTS_FILE" ]]; then
        cat "$SLOTS_FILE"
    else
        echo "[]"
    fi
}

save_slots_json() {
    local json="$1"
    python3 -c "import json; data=json.loads('$json'); open('$SLOTS_FILE','w').write(json.dumps(data, indent=2))" 2>/dev/null || \
        python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
open('$SLOTS_FILE','w').write(json.dumps(data, indent=2))
" <<< "$json"
}

count_slots() {
    python3 -c "import json; print(len(json.load(open('$SLOTS_FILE'))))" 2>/dev/null || echo 0
}

# ── status subcommand ─────────────────────────────────────────────────────────

cmd_status() {
    if [[ "$MAX_SLOTS" == "0" ]]; then
        echo "[opus-slot-tracker] BYPASS: CHUMP_OPUS_MAX_SLOTS=0 — slot dispatch disabled (self-implement only)"
        return 0
    fi

    local now_ts
    now_ts=$(now_epoch)

    echo "=== opus-slot-tracker status (max_slots=$MAX_SLOTS) ==="
    echo "  slots_file: $SLOTS_FILE"
    echo "  session:    $SESSION_ID"
    echo ""

    if [[ ! -f "$SLOTS_FILE" ]]; then
        echo "  No active slots. All $(( MAX_SLOTS )) slot(s) free."
        return 0
    fi

    local slots_json
    slots_json=$(load_slots_json)

    local count
    count=$(python3 -c "import json; print(len(json.loads(open('$SLOTS_FILE').read())))" 2>/dev/null || echo 0)

    if [[ "$count" == "0" ]]; then
        echo "  No active slots. All $MAX_SLOTS slot(s) free."
        return 0
    fi

    echo "  In-flight slots: $count / $MAX_SLOTS"
    echo ""

    python3 - <<PYEOF
import json, time, datetime

SLOTS_FILE = "$SLOTS_FILE"
now = $now_ts
budget_s = $BUDGET_S
lease_timeout_s = $LEASE_TIMEOUT_S
pr_timeout_s = $PR_TIMEOUT_S

try:
    slots = json.load(open(SLOTS_FILE))
except Exception:
    slots = []

for s in slots:
    slot_id = s.get("slot_id", "?")
    gap_id = s.get("gap_id", "?")
    agent_id = s.get("agent_id", "?")
    dispatched_ts = s.get("dispatched_ts", "")
    last_progress_ts = s.get("last_progress_ts", dispatched_ts)
    pr_number = s.get("pr_number", None)
    lease_confirmed = s.get("lease_confirmed", False)

    age_s = 0
    if dispatched_ts:
        try:
            dt = datetime.datetime.fromisoformat(dispatched_ts.replace("Z", "+00:00"))
            age_s = now - int(dt.timestamp())
        except Exception:
            pass

    budget_remaining = max(0, budget_s - age_s)
    flags = []
    if not lease_confirmed and age_s >= lease_timeout_s:
        flags.append("NO_LEASE")
    if not pr_number and age_s >= pr_timeout_s:
        flags.append("NO_PR")
    if age_s >= budget_s:
        flags.append("BUDGET_EXCEEDED")

    status_str = "STALLED" if flags else "OK"
    flag_str = ",".join(flags) if flags else "-"

    print(f"  Slot {slot_id}: [{status_str}] gap={gap_id} agent={agent_id}")
    print(f"    dispatched:   {dispatched_ts}")
    print(f"    age:          {age_s}s  budget_remaining: {budget_remaining}s")
    print(f"    lease:        {'confirmed' if lease_confirmed else 'pending'}")
    print(f"    pr_number:    {pr_number or 'none'}")
    print(f"    flags:        {flag_str}")
    print()
PYEOF
}

# ── dispatch subcommand ───────────────────────────────────────────────────────

cmd_dispatch() {
    local gap_id="${1:-}"
    if [[ -z "$gap_id" ]]; then
        echo "[opus-slot-tracker] ERROR: dispatch requires <GAP-ID>" >&2
        exit 2
    fi

    if [[ "$MAX_SLOTS" == "0" ]]; then
        echo "[opus-slot-tracker] BYPASS: CHUMP_OPUS_MAX_SLOTS=0 — slot dispatch disabled" >&2
        exit 0
    fi

    local max_slots="$MAX_SLOTS"
    if [[ "$MAX_SLOTS" == "1" ]]; then
        max_slots=1
        echo "[opus-slot-tracker] LEGACY MODE: CHUMP_OPUS_MAX_SLOTS=1 — single-slot mode" >&2
    fi

    # Check current capacity
    local current_count=0
    if [[ -f "$SLOTS_FILE" ]]; then
        current_count=$(python3 -c "import json; print(len(json.load(open('$SLOTS_FILE'))))" 2>/dev/null || echo 0)
    fi

    if (( current_count >= max_slots )); then
        echo "[opus-slot-tracker] CAPACITY FULL: $current_count / $max_slots slots in use for gap $gap_id" >&2
        echo "  Run 'reap' first to free stalled slots, or wait for completion." >&2
        exit 1
    fi

    # Find next available slot number (1-indexed, fill gaps)
    local slot_id
    slot_id=$(python3 - <<PYEOF
import json

SLOTS_FILE = "$SLOTS_FILE"
max_slots = $max_slots

try:
    slots = json.load(open(SLOTS_FILE))
except Exception:
    slots = []

used = {s.get("slot_id") for s in slots}
for n in range(1, max_slots + 1):
    if n not in used:
        print(n)
        break
PYEOF
)

    if [[ -z "$slot_id" ]]; then
        echo "[opus-slot-tracker] ERROR: could not determine slot_id (all $max_slots slots in use?)" >&2
        exit 1
    fi

    local now_iso_val
    now_iso_val=$(now_iso)
    local agent_id="sonnet-slot-${slot_id}-$(date +%s)"

    # Build new slot record
    local new_slot
    new_slot=$(python3 -c "
import json
slot = {
    'slot_id': $slot_id,
    'agent_id': '$agent_id',
    'gap_id': '$gap_id',
    'dispatched_ts': '$now_iso_val',
    'last_progress_ts': '$now_iso_val',
    'lease_confirmed': False,
    'pr_number': None,
}
print(json.dumps(slot))
")

    # Append to slots file atomically
    python3 - <<PYEOF
import json

SLOTS_FILE = "$SLOTS_FILE"

try:
    slots = json.load(open(SLOTS_FILE))
except Exception:
    slots = []

new_slot = json.loads('$new_slot')
slots.append(new_slot)

with open(SLOTS_FILE, 'w') as f:
    json.dump(slots, f, indent=2)
PYEOF

    # Emit dispatch event to ambient
    emit_ambient "opus_slot_dispatched" \
        "gap_id" "$gap_id" \
        "slot_id" "$slot_id" \
        "agent_id" "$agent_id" \
        "budget_s" "$BUDGET_S"

    echo "[opus-slot-tracker] Dispatched slot $slot_id for $gap_id"
    echo ""
    echo "=== Dispatch envelope (paste into Agent tool prompt) ==="
    echo ""
    echo "SLOT_ID=$slot_id GAP_ID=$gap_id AGENT_ID=$agent_id"
    echo "Budget: ${BUDGET_S}s (15-min wall-clock)"
    echo ""
    echo "After gap completes, run:"
    echo "  bash scripts/coord/opus-slot-tracker.sh release $slot_id"
    echo ""
    echo "Reap check (fail-fast thresholds):"
    echo "  No lease within ${LEASE_TIMEOUT_S}s → killed"
    echo "  No PR within ${PR_TIMEOUT_S}s → killed"
    echo "  Budget ${BUDGET_S}s exceeded → killed"
}

# ── reap subcommand ───────────────────────────────────────────────────────────

cmd_reap() {
    if [[ "$MAX_SLOTS" == "0" ]]; then
        echo "[opus-slot-tracker] BYPASS: CHUMP_OPUS_MAX_SLOTS=0 — no slots to reap"
        return 0
    fi

    if [[ ! -f "$SLOTS_FILE" ]]; then
        echo "[opus-slot-tracker] No slots file — nothing to reap."
        return 0
    fi

    local now_ts
    now_ts=$(now_epoch)

    python3 - <<PYEOF
import json, time, datetime, subprocess, os, sys

SLOTS_FILE = "$SLOTS_FILE"
AMBIENT = "$AMBIENT"
SESSION_ID = "$SESSION_ID"
now = $now_ts
budget_s = $BUDGET_S
lease_timeout_s = $LEASE_TIMEOUT_S
pr_timeout_s = $PR_TIMEOUT_S

def emit(kind, **kwargs):
    import datetime as dt
    payload = {"ts": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
               "kind": kind, "session": SESSION_ID}
    payload.update(kwargs)
    try:
        with open(AMBIENT, "a") as f:
            f.write(json.dumps(payload, separators=(",", ":")) + "\n")
    except Exception:
        pass

def calc_age(ts_str):
    if not ts_str:
        return 0
    try:
        dt = datetime.datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        return now - int(dt.timestamp())
    except Exception:
        return 0

try:
    slots = json.load(open(SLOTS_FILE))
except Exception:
    slots = []

live_slots = []
reaped = []

for s in slots:
    slot_id = s.get("slot_id", "?")
    gap_id = s.get("gap_id", "?")
    agent_id = s.get("agent_id", "?")
    dispatched_ts = s.get("dispatched_ts", "")
    lease_confirmed = s.get("lease_confirmed", False)
    pr_number = s.get("pr_number", None)

    age_s = calc_age(dispatched_ts)

    reap_reason = None
    if not lease_confirmed and age_s >= lease_timeout_s:
        reap_reason = f"no_lease_in_{lease_timeout_s}s (age={age_s}s)"
    elif not pr_number and age_s >= pr_timeout_s:
        reap_reason = f"no_pr_in_{pr_timeout_s}s (age={age_s}s)"
    elif age_s >= budget_s:
        reap_reason = f"budget_{budget_s}s_exceeded (age={age_s}s)"

    if reap_reason:
        print(f"[opus-slot-tracker] REAPING slot {slot_id} ({gap_id}): {reap_reason}")
        emit("opus_slot_reaped",
             gap_id=str(gap_id),
             slot_id=str(slot_id),
             agent_id=str(agent_id),
             reap_reason=reap_reason,
             age_s=age_s)
        reaped.append(slot_id)
        # TaskStop pattern: print the kill instruction for the operator/caller to action
        print(f"  TaskStop: kill agent_id={agent_id} (slot {slot_id}, gap {gap_id})")
        print(f"  Action: dispatch a replacement for {gap_id} if still needed")
    else:
        live_slots.append(s)
        budget_remaining = max(0, budget_s - age_s)
        print(f"[opus-slot-tracker] Slot {slot_id} ({gap_id}): OK (age={age_s}s, budget_remaining={budget_remaining}s)")

if reaped:
    with open(SLOTS_FILE, "w") as f:
        json.dump(live_slots, f, indent=2)
    print(f"\n[opus-slot-tracker] Reaped {len(reaped)} slot(s): {reaped}. Remaining: {len(live_slots)}.")
elif slots:
    print(f"\n[opus-slot-tracker] All {len(slots)} slot(s) healthy.")
else:
    print("[opus-slot-tracker] No active slots.")
PYEOF
}

# ── release subcommand ────────────────────────────────────────────────────────

cmd_release() {
    local slot_id="${1:-}"
    if [[ -z "$slot_id" ]]; then
        echo "[opus-slot-tracker] ERROR: release requires <slot_id>" >&2
        exit 2
    fi

    if [[ ! -f "$SLOTS_FILE" ]]; then
        echo "[opus-slot-tracker] No slots file — nothing to release."
        return 0
    fi

    python3 - <<PYEOF
import json, sys

SLOTS_FILE = "$SLOTS_FILE"
slot_id = int("$slot_id")

try:
    slots = json.load(open(SLOTS_FILE))
except Exception:
    slots = []

original_count = len(slots)
remaining = [s for s in slots if s.get("slot_id") != slot_id]

if len(remaining) == original_count:
    print(f"[opus-slot-tracker] Slot {slot_id} not found — already released or never existed.")
    sys.exit(0)

with open(SLOTS_FILE, "w") as f:
    json.dump(remaining, f, indent=2)

print(f"[opus-slot-tracker] Released slot {slot_id}. Remaining slots: {len(remaining)}.")
PYEOF
}

# ── Main dispatch ─────────────────────────────────────────────────────────────

SUBCMD="${1:-}"
case "$SUBCMD" in
    status)
        cmd_status
        ;;
    dispatch)
        cmd_dispatch "${2:-}"
        ;;
    reap)
        cmd_reap
        ;;
    release)
        cmd_release "${2:-}"
        ;;
    -h|--help|"")
        sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "opus-slot-tracker: unknown subcommand '$SUBCMD'" >&2
        echo "Usage: $0 {status|dispatch <GAP-ID>|reap|release <slot_id>}" >&2
        exit 2
        ;;
esac
