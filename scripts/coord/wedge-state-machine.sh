#!/usr/bin/env bash
# scripts/coord/wedge-state-machine.sh — INFRA-1994 (THE FLOOR Phase 3)
#
# Converts the wedge catalog (docs/process/WEDGE_CLASS_CATALOG.md, 13
# classes) from passive docs-with-playbook into an EXECUTABLE state
# machine:
#
#   detector_fires (from wedge-watch.sh)
#       ─→ kind=wedge_detected ambient event
#               ─→ wedge-state-machine.sh consumes
#                       ─→ rate-limit check (1/class/30min)
#                       ─→ remediation function (per W-NNN)
#                                ─→ kind=wedge_remediated OR wedge_remediation_failed
#                       ─→ chronic check (3 detections/24h → escalate)
#                                ─→ kind=wedge_chronic + auto-file META gap
#
# Today wedge-watch.sh just EMITS events — it doesn't act on them. This
# state machine adds the consume-and-act loop, rate limits to prevent
# remediation oscillation, and escalates chronic patterns.
#
# Designed for launchd at 5-minute cadence (paired with wedge-watch's
# own 5-minute cadence so we observe + act in the same cycle).
#
# Remediation routing:
#   - Read-only remediations (warn, audit, file follow-up gap) fire directly
#   - State-mutating remediations (admin-merge, push, branch-protection edits)
#     route through the recovery queue (INFRA-1993) so they inherit its
#     rate limit + audit + auth model
#
# Bypass: CHUMP_WEDGE_STATE_MACHINE_SKIP=1 short-circuits to exit 0
#
# Config (env):
#   CHUMP_WEDGE_REMEDIATION_RATE_MIN=30   per-class rate limit (default 30 min)
#   CHUMP_WEDGE_CHRONIC_THRESHOLD=3       chronic if N fires in 24h (default 3)
#   CHUMP_WEDGE_STATE_MACHINE_DRY_RUN=1   plan without acting

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE="$REPO_ROOT/.chump-locks/wedge-state-machine-state.json"
RATE_MIN="${CHUMP_WEDGE_REMEDIATION_RATE_MIN:-30}"
CHRONIC="${CHUMP_WEDGE_CHRONIC_THRESHOLD:-3}"
DRY_RUN="${CHUMP_WEDGE_STATE_MACHINE_DRY_RUN:-0}"

# Paths to real remediation primitives (overridable in tests)
BROADCAST_URGENT="${CHUMP_BROADCAST_URGENT_BIN:-$REPO_ROOT/scripts/coord/broadcast-urgent.sh}"
REFRESH_RUNNER_BIN="${CHUMP_REFRESH_RUNNER_BIN:-$REPO_ROOT/scripts/setup/refresh-runner-binary.sh}"

mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || true

if [[ "${CHUMP_WEDGE_STATE_MACHINE_SKIP:-0}" == "1" ]]; then
    echo "wedge-state-machine: skipped (env bypass)" >&2
    exit 0
fi

# ── INFRA-2009: silent-noop guard ─────────────────────────────────────────────
# Emits kind=daemon_silent_noop if main work body is skipped on non-empty input.
# shellcheck source=scripts/coord/lib/silent-noop-guard.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/silent-noop-guard.sh"
_sng_install_guard "wedge_state_machine" "$AMBIENT"

# ── Helpers ──────────────────────────────────────────────────────────────────
_ts()      { date -u +%Y-%m-%dT%H:%M:%SZ; }
_ts_secs() { date +%s; }

_emit() {
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do extra+=",${kv}"; done
    printf '{"ts":"%s","kind":"%s","source":"wedge_state_machine"%s}\n' \
        "$(_ts)" "$kind" "$extra" \
        >> "$AMBIENT" 2>/dev/null || true
}

_load_state() {
    if [[ -f "$STATE" ]]; then
        cat "$STATE"
    else
        echo '{"processed_offset":0,"per_class":{}}'
    fi
}
_save_state() {
    [[ "$DRY_RUN" == "1" ]] && return
    echo "$1" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# ── Real remediation helpers (INFRA-2030) ────────────────────────────────────

# W-002: invoke refresh-runner-binary.sh inline, then CRIT if it fails
_remediate_w002() {
    local detail="$1"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] W-002: would invoke $REFRESH_RUNNER_BIN + emit wedge_remediated_real" >&2
        _emit "wedge_remediated_real" \
            "\"class\":\"W-002\"" \
            "\"action\":\"dry-run: refresh-runner-binary.sh\"" \
            "\"detail\":\"$detail\""
        return
    fi
    echo "[state-machine] W-002: invoking refresh-runner-binary.sh" >&2
    local refresh_rc=0
    if [[ -x "$REFRESH_RUNNER_BIN" ]]; then
        CHUMP_REPO_ROOT="$REPO_ROOT" bash "$REFRESH_RUNNER_BIN" >&2 2>&1 || refresh_rc=$?
    else
        echo "[state-machine] W-002: refresh-runner-binary.sh not found at $REFRESH_RUNNER_BIN" >&2
        refresh_rc=1
    fi

    if [[ "$refresh_rc" -eq 0 ]]; then
        _emit "wedge_remediated_real" \
            "\"class\":\"W-002\"" \
            "\"action\":\"refresh-runner-binary.sh invoked\"" \
            "\"detail\":\"$detail\""
    else
        # Binary refresh failed — CRIT broadcast so every agent sees it
        _emit "wedge_remediated_real" \
            "\"class\":\"W-002\"" \
            "\"action\":\"refresh-runner-binary.sh FAILED — CRIT broadcast sent\"" \
            "\"outcome\":\"failed\"" \
            "\"detail\":\"$detail\""
        if [[ -x "$BROADCAST_URGENT" ]]; then
            bash "$BROADCAST_URGENT" \
                --urgency CRIT \
                --from "wedge_state_machine" \
                "W-002 binary-refresh failed (rc=$refresh_rc) — manual: cargo install --path $REPO_ROOT --bin chump --force && cp ~/.cargo/bin/chump /opt/homebrew/bin/chump" \
                >&2 2>&1 || true
        fi
    fi
}

# W-007: run chump health required-check audit (INFRA-1522) + CRIT broadcast
_remediate_w007() {
    local detail="$1"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] W-007: would run 'chump health required-check-audit' + CRIT broadcast" >&2
        _emit "wedge_remediated_real" \
            "\"class\":\"W-007\"" \
            "\"action\":\"dry-run: health required-check-audit + CRIT broadcast\"" \
            "\"detail\":\"$detail\""
        return
    fi
    echo "[state-machine] W-007: running chump health required-check-audit" >&2
    local audit_out=""
    local audit_rc=0
    # INFRA-1522: chump health required-check-audit (may not be fully shipped yet;
    # we fall back gracefully if the subcommand is absent)
    if command -v chump >/dev/null 2>&1; then
        audit_out="$(chump health required-check-audit --json 2>&1)" || audit_rc=$?
    else
        audit_rc=127
        audit_out="chump not on PATH"
    fi

    _emit "wedge_remediated_real" \
        "\"class\":\"W-007\"" \
        "\"action\":\"health required-check-audit invoked (INFRA-1522)\"" \
        "\"audit_rc\":$audit_rc" \
        "\"detail\":\"$detail\""

    # Always CRIT-broadcast for W-007: required-check drift blocks ALL PRs
    local msg="W-007 required-status-check absent — required-check-audit rc=$audit_rc — check ci.yml + branch protection ruleset; see INFRA-1522"
    if [[ -x "$BROADCAST_URGENT" ]]; then
        bash "$BROADCAST_URGENT" \
            --urgency CRIT \
            --from "wedge_state_machine" \
            "$msg" \
            >&2 2>&1 || true
    fi
    echo "[state-machine] W-007: CRIT broadcast sent" >&2
}

# W-AGG: emit cluster_detection_requested so cluster-detector picks it up
_remediate_wagg() {
    local detail="$1"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] W-AGG: would emit cluster_detection_requested" >&2
        _emit "cluster_detection_requested" \
            "\"source_wedge\":\"W-AGG\"" \
            "\"reason\":\"dry-run: >=3 BLOCKED PRs detected by wedge-watch\"" \
            "\"detail\":\"$detail\""
        _emit "wedge_remediated_real" \
            "\"class\":\"W-AGG\"" \
            "\"action\":\"dry-run: cluster_detection_requested emitted\"" \
            "\"detail\":\"$detail\""
        return
    fi
    echo "[state-machine] W-AGG: emitting cluster_detection_requested for cluster-detector" >&2
    # cluster-detector.sh consumes cluster_detection_requested on its next tick
    # and applies IDENTICAL-check-set discrimination (sharper than W-AGG's count-only)
    _emit "cluster_detection_requested" \
        "\"source_wedge\":\"W-AGG\"" \
        "\"reason\":\"wedge-state-machine: >=3 BLOCKED PRs detected; deferring to cluster-detector for cluster_id classification\"" \
        "\"detail\":\"$detail\""
    _emit "wedge_remediated_real" \
        "\"class\":\"W-AGG\"" \
        "\"action\":\"cluster_detection_requested emitted — cluster-detector will classify on next tick\"" \
        "\"detail\":\"$detail\""
    echo "[state-machine] W-AGG: cluster_detection_requested emitted" >&2
}

# Per-class remediation router. Edit this case to add real remediations
# for each W-NNN class. Default: advisory emit (no state mutation).
_remediate() {
    local class="$1"
    local detail="$2"
    case "$class" in
        W-001)
            # gh API false-positive merge conflicts — advise re-fetch + retry
            # (INFRA-1958 shipped automated local-rebase fallback; advisory here is sufficient)
            _emit "wedge_remediation_requested" \
                "\"class\":\"$class\"" \
                "\"action\":\"advisory: pr-auto-rebase re-fetch + retry\"" \
                "\"detail\":\"$detail\""
            ;;
        W-002)
            # Binary cache lag — REAL: invoke refresh-runner-binary.sh inline
            # (INFRA-2030)
            _remediate_w002 "$detail"
            ;;
        W-007)
            # Required-status-check missing — REAL: audit + CRIT broadcast
            # (INFRA-2030; INFRA-1522 health gate)
            _remediate_w007 "$detail"
            ;;
        W-008)
            # CLEAN state stuck — auto-merge race; can route to recovery queue
            _emit "wedge_remediation_requested" \
                "\"class\":\"$class\"" \
                "\"action\":\"check pr_auto_rebase logs; CLEAN+armed >1h likely needs operator nudge\"" \
                "\"detail\":\"$detail\""
            ;;
        W-AGG)
            # Aggregate signature: ≥3 BLOCKED PRs — REAL: emit cluster_detection_requested
            # so cluster-detector (INFRA-1987) can apply IDENTICAL-check discrimination
            # (INFRA-2030)
            _remediate_wagg "$detail"
            ;;
        *)
            # Unknown / not-yet-instrumented class — log + emit advisory
            # Follow-up: W-003/005/009/010/011/012/013 real remediations tracked in INFRA-NEXT
            _emit "wedge_remediation_requested" \
                "\"class\":\"$class\"" \
                "\"action\":\"advisory: no automated remediation yet; see docs/process/WEDGE_CLASS_CATALOG.md\"" \
                "\"detail\":\"$detail\""
            ;;
    esac
}

# ── Find new wedge_detected events ──────────────────────────────────────────
_find_detections() {
    [[ -f "$AMBIENT" ]] || return
    local state; state="$(_load_state)"
    local offset
    offset="$(echo "$state" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("processed_offset",0))' 2>/dev/null || echo 0)"
    offset="${offset:-0}"

    awk -v from="$((offset+1))" 'NR>=from' "$AMBIENT" 2>/dev/null \
        | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.rstrip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    # ambient.jsonl can contain non-dict JSON values (numbers, strings,
    # arrays) from misc emitters — guard before calling .get(). Without
    # this, a single int line crashes the whole pipe + drops remaining
    # lines on the floor.
    if not isinstance(obj, dict):
        continue
    if obj.get("kind") == "wedge_detected":
        # Output: class|note (note is detail field, may be empty)
        # Real wedge-watch.sh emits with `wedge_class` field; some test
        # fixtures use `class`. Accept both.
        cls = obj.get("wedge_class") or obj.get("class") or ""
        note = (obj.get("note") or obj.get("reason") or obj.get("detail") or "").replace("|", " ")
        if cls:
            print(f"{cls}|{note}")
' 2>/dev/null || true
}

# ── Per-class rate-limit check (returns 0 if remediation allowed) ──────────
_can_remediate() {
    local class="$1"
    local state; state="$(_load_state)"
    local last
    last="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
    print(s.get('per_class', {}).get('$class', {}).get('last_remediated', 0))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
    last="${last:-0}"
    local now; now=$(_ts_secs)
    local elapsed=$(( now - last ))
    local min_secs=$(( RATE_MIN * 60 ))
    [[ "$elapsed" -ge "$min_secs" ]]
}

_record_remediation() {
    local class="$1"
    local state; state="$(_load_state)"
    local now; now=$(_ts_secs)
    state="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    s = {'processed_offset':0,'per_class':{}}
s.setdefault('per_class', {}).setdefault('$class', {})
s['per_class']['$class']['last_remediated'] = $now
s['per_class']['$class'].setdefault('detection_window', [])
print(json.dumps(s))
")"
    _save_state "$state"
}

# ── Chronic detection: ≥CHRONIC fires in trailing 24h ───────────────────────
_record_detection() {
    local class="$1"
    local state; state="$(_load_state)"
    local now; now=$(_ts_secs)
    local cutoff=$(( now - 86400 ))
    state="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    s = {'processed_offset':0,'per_class':{}}
s.setdefault('per_class', {}).setdefault('$class', {})
win = s['per_class']['$class'].setdefault('detection_window', [])
win.append($now)
# Prune to 24h window
s['per_class']['$class']['detection_window'] = [t for t in win if t > $cutoff]
print(json.dumps(s))
")"
    _save_state "$state"
}

_is_chronic() {
    local class="$1"
    local state; state="$(_load_state)"
    local count
    count="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
    print(len(s.get('per_class', {}).get('$class', {}).get('detection_window', [])))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
    count="${count:-0}"
    [[ "$count" -ge "$CHRONIC" ]]
}

_emit_chronic() {
    local class="$1"
    local state; state="$(_load_state)"
    # Don't emit chronic more than once per 6h per class
    local last_chronic
    last_chronic="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
    print(s.get('per_class', {}).get('$class', {}).get('last_chronic_emit', 0))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
    local now; now=$(_ts_secs)
    if [[ $(( now - last_chronic )) -lt 21600 ]]; then
        return  # already escalated recently
    fi
    _emit "wedge_chronic" \
        "\"class\":\"$class\"" \
        "\"window_secs\":86400" \
        "\"threshold\":\"$CHRONIC\"" \
        "\"action\":\"chronic pattern — file META gap for permanent fix; see docs/process/WEDGE_CLASS_CATALOG.md $class\""
    # Update last_chronic_emit
    state="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    s = {'processed_offset':0,'per_class':{}}
s.setdefault('per_class', {}).setdefault('$class', {})['last_chronic_emit'] = $now
print(json.dumps(s))
")"
    _save_state "$state"
}

# ── Main loop ────────────────────────────────────────────────────────────────
DETECTIONS="$(_find_detections)"

if [[ -f "$AMBIENT" ]]; then
    HIGHEST_LINE="$(wc -l < "$AMBIENT" | xargs)"
else
    HIGHEST_LINE=0
fi

if [[ -z "$DETECTIONS" ]]; then
    # No new detections — advance offset to keep state fresh
    state="$(_load_state)"
    new_state="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    s = {'processed_offset':0,'per_class':{}}
s['processed_offset'] = $HIGHEST_LINE
print(json.dumps(s))
")"
    _save_state "$new_state"
    echo "wedge-state-machine: no new detections" >&2
    exit 0
fi

echo "[state-machine] found $(echo "$DETECTIONS" | wc -l | xargs) new detection(s)" >&2

_SNG_HAD_INPUT=1   # INFRA-2009: non-empty detections → guard expects main work
while IFS='|' read -r class detail; do
    [[ -z "$class" ]] && continue
    _record_detection "$class"
    if _can_remediate "$class"; then
        _remediate "$class" "$detail"
        _record_remediation "$class"
    else
        _emit "wedge_remediation_rate_limited" \
            "\"class\":\"$class\"" \
            "\"rate_min\":\"$RATE_MIN\""
    fi
    if _is_chronic "$class"; then
        _emit_chronic "$class"
    fi
done <<< "$DETECTIONS"
_sng_mark_done     # INFRA-2009: main work body executed

# Advance offset
state="$(_load_state)"
new_state="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    s = {'processed_offset':0,'per_class':{}}
s['processed_offset'] = $HIGHEST_LINE
print(json.dumps(s))
")"
_save_state "$new_state"

exit 0
