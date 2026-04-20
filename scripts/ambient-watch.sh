#!/usr/bin/env bash
# ambient-watch.sh — anomaly detector daemon for the peripheral-vision stream
#
# Runs as a background daemon. Polls .chump-locks/ every POLL_SECS (default 10)
# and emits ALERT events to .chump-locks/ambient.jsonl for three anomaly classes:
#
#   lease_overlap  — two live sessions claim the same file path
#   silent_agent   — a live lease's heartbeat hasn't refreshed in >STALE_WARN_SECS
#   edit_burst     — >BURST_THRESHOLD file_edit/bash_call events in last BURST_WINDOW_SECS
#
# Usage:
#   scripts/ambient-watch.sh &           # ad-hoc background
#   scripts/start-ambient-watch.sh       # managed start (writes PID file)
#
# Environment:
#   POLL_SECS          check interval in seconds (default: 10)
#   STALE_WARN_SECS    heartbeat age that triggers silent_agent ALERT (default: 600)
#   BURST_THRESHOLD    edit events in BURST_WINDOW_SECS to trigger alert (default: 20)
#   BURST_WINDOW_SECS  rolling window for burst detection (default: 60)
#   CHUMP_AMBIENT_LOG  override log path (default: <repo>/.chump-locks/ambient.jsonl)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
EMIT="$REPO_ROOT/scripts/ambient-emit.sh"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
mkdir -p "$LOCK_DIR"

POLL_SECS="${POLL_SECS:-10}"
STALE_WARN_SECS="${STALE_WARN_SECS:-600}"
BURST_THRESHOLD="${BURST_THRESHOLD:-20}"
BURST_WINDOW_SECS="${BURST_WINDOW_SECS:-60}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

[ -x "$EMIT" ] || { echo "[ambient-watch] ERROR: $EMIT not found or not executable" >&2; exit 1; }

# ── Python helper ─────────────────────────────────────────────────────────────
# Inline Python for the logic that's too hairy in shell.
PYTHON_CHECKER=$(cat <<'PYEOF'
import json, os, sys, glob, datetime

lock_dir = sys.argv[1]
ambient_log = sys.argv[2]
stale_warn_secs = int(sys.argv[3])
burst_threshold = int(sys.argv[4])
burst_window_secs = int(sys.argv[5])

now = datetime.datetime.now(datetime.timezone.utc)

def parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None

# ── Load live leases ──────────────────────────────────────────────────────────
leases = []
for path in glob.glob(os.path.join(lock_dir, "*.json")):
    basename = os.path.basename(path)
    if basename.startswith("."):
        continue
    try:
        with open(path) as f:
            d = json.load(f)
        # is_live check: not expired, heartbeat fresh
        expires = parse_ts(d.get("expires_at", ""))
        heartbeat = parse_ts(d.get("heartbeat_at", ""))
        if expires is None or heartbeat is None:
            continue
        expired = now > expires + datetime.timedelta(seconds=30)
        stale = (now - heartbeat).total_seconds() > 15 * 60
        if not expired and not stale:
            leases.append(d)
    except Exception:
        pass

alerts = []

# ── Check 1: lease overlap ────────────────────────────────────────────────────
def path_matches(pattern, candidate):
    if pattern == "**":
        return True
    if pattern.endswith("/") or pattern.endswith("/**"):
        prefix = pattern.rstrip("/*")
        return candidate == prefix or candidate.startswith(prefix + "/")
    return pattern == candidate

for i, a in enumerate(leases):
    for b in leases[i+1:]:
        if a["session_id"] == b["session_id"]:
            continue
        paths_a = a.get("paths", [])
        paths_b = b.get("paths", [])
        if not paths_a or not paths_b:
            continue
        for pa in paths_a:
            for pb in paths_b:
                if path_matches(pa, pb) or path_matches(pb, pa) or pa == pb:
                    alerts.append({
                        "kind": "lease_overlap",
                        "sessions": [a["session_id"], b["session_id"]],
                        "path": pa,
                    })
                    break

# ── Check 2: silent agent ─────────────────────────────────────────────────────
for lease in leases:
    heartbeat = parse_ts(lease.get("heartbeat_at", ""))
    if heartbeat is None:
        continue
    age = (now - heartbeat).total_seconds()
    if age > stale_warn_secs:
        alerts.append({
            "kind": "silent_agent",
            "session": lease["session_id"],
            "heartbeat_age_secs": int(age),
            "gap": lease.get("gap_id", ""),
        })

# ── Check 3: edit burst ───────────────────────────────────────────────────────
if os.path.exists(ambient_log):
    burst_kinds = {"file_edit", "bash_call"}
    cutoff = now - datetime.timedelta(seconds=burst_window_secs)
    recent_count = 0
    try:
        with open(ambient_log) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                    ts = parse_ts(ev.get("ts", ""))
                    if ts and ts >= cutoff and ev.get("event") in burst_kinds:
                        recent_count += 1
                except Exception:
                    pass
    except Exception:
        pass
    if recent_count >= burst_threshold:
        alerts.append({
            "kind": "edit_burst",
            "count": recent_count,
            "window_secs": burst_window_secs,
        })

print(json.dumps(alerts))
PYEOF
)

# ── Dedup state: track already-alerted keys to avoid spam ────────────────────
# Use a temp file (bash 3.2 compat — no associative arrays on macOS default bash)
ALERTED_FILE="$(mktemp)"
trap 'rm -f "$ALERTED_FILE"' EXIT

emit_alert() {
    local kind="$1" key="$2"
    shift 2
    # Only emit each unique alert key once per daemon run (resets on restart).
    if grep -qxF "$key" "$ALERTED_FILE" 2>/dev/null; then
        return
    fi
    echo "$key" >> "$ALERTED_FILE"
    "$EMIT" ALERT "kind=$kind" "$@" 2>/dev/null || true
}

echo "[ambient-watch] started (pid=$$, poll=${POLL_SECS}s, repo=$(basename "$REPO_ROOT"))" >&2

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do
    ALERTS="$(python3 - "$LOCK_DIR" "$AMBIENT_LOG" "$STALE_WARN_SECS" "$BURST_THRESHOLD" "$BURST_WINDOW_SECS" <<< "$PYTHON_CHECKER" 2>/dev/null || echo "[]")"

    # Parse and emit each alert
    COUNT="$(python3 -c "import json,sys; a=json.loads(sys.argv[1]); print(len(a))" "$ALERTS" 2>/dev/null || echo 0)"

    if [[ "$COUNT" -gt 0 ]]; then
        python3 - "$ALERTS" <<'EMIT_PY'
import json, sys
alerts = json.loads(sys.argv[1])
for a in alerts:
    kind = a.get("kind","")
    if kind == "lease_overlap":
        sessions = ",".join(a.get("sessions", []))
        path = a.get("path", "")
        print(f"OVERLAP\x1f{sessions}\x1f{path}")
    elif kind == "silent_agent":
        session = a.get("session","")
        age = a.get("heartbeat_age_secs",0)
        gap = a.get("gap","")
        print(f"SILENT\x1f{session}\x1f{age}\x1f{gap}")
    elif kind == "edit_burst":
        count = a.get("count",0)
        window = a.get("window_secs",60)
        print(f"BURST\x1f{count}\x1f{window}")
EMIT_PY
    fi | while IFS=$'\x1f' read -r kind rest; do
        case "$kind" in
            OVERLAP)
                IFS=$'\x1f' read -r sessions path <<< "$rest"
                emit_alert "lease_overlap" "overlap:${sessions}:${path}" "sessions=$sessions" "path=$path"
                ;;
            SILENT)
                IFS=$'\x1f' read -r session age gap <<< "$rest"
                emit_alert "silent_agent" "silent:$session" "session=$session" "heartbeat_age_secs=$age" "gap=$gap"
                ;;
            BURST)
                IFS=$'\x1f' read -r count window <<< "$rest"
                # Burst alerts reset every window so they don't spam. Use minute bucket as key.
                bucket="$(date +%H%M)"
                emit_alert "edit_burst" "burst:$bucket" "count=$count" "window_secs=$window"
                ;;
        esac
    done

    sleep "$POLL_SECS"
done
