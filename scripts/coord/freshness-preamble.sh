#!/usr/bin/env bash
# freshness-preamble.sh — META-115 (sub-gap of META-114 freshness discipline cluster)
#
# Per-session source-freshness preamble. Runs at curator session-start and
# classifies the local state into FRESH / STALE / CRITICAL_STALE based on
# four signals:
#
#   (a) commits-behind     — git rev-list HEAD..origin/main --count
#                            (after `git fetch origin main --quiet`)
#   (b) binary-age         — unix-now - stat-mtime $(which chump)
#   (c) cron-health        — `chump cron health` if the binary supports it;
#                            fail-soft to "unavailable" if not.
#   (d) bootstrap-check    — `chump fleet-bootstrap --check` exit code;
#                            fail-soft to "unavailable" if not.
#
# Phase 1 ships the script but DOES NOT integrate into SessionStart hooks or
# chump fleet-bootstrap --check. Integration is a separate sub-gap. This file
# is invokable as a stand-alone command.
#
# Why this exists (real-world precedent, 2026-05-27):
#   The shepherd hit 3+ stale-tree false-positives in a single session —
#   `recovery-queue-emit.sh phantom-missing` was the worst (local main
#   was 48-63 commits behind origin/main, so a file that exists on origin
#   appeared missing locally). This preamble surfaces that staleness
#   BEFORE the operator/curator files a "file missing" gap or runs a
#   destructive op.
#
# Usage:
#   bash scripts/coord/freshness-preamble.sh                 # exits 0/1/2
#   bash scripts/coord/freshness-preamble.sh --json          # JSON output
#
# Exit codes:
#   0 — FRESH
#   1 — STALE
#   2 — CRITICAL_STALE
#
# Output (one-line stdout):
#   Freshness: FRESH|STALE|CRITICAL_STALE (commits-behind=N, binary-age=Ns, cron-health=PASS|WARN|FAIL|unavailable)
#
# Env overrides:
#   CHUMP_FRESHNESS_COMMITS_THRESHOLD  (default 50)  — CRITICAL_STALE above this
#   CHUMP_FRESHNESS_BINARY_AGE_S       (default 14400 = 4h) — CRITICAL_STALE above this
#   CHUMP_FRESHNESS_STALE_COMMITS      (default 15)  — STALE above this (below CRITICAL)
#   CHUMP_FRESHNESS_STALE_BINARY_AGE_S (default 3600 = 1h) — STALE above this
#   CHUMP_FRESHNESS_DISABLE_FETCH      (default 0; 1 skips `git fetch`, useful for offline tests)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── thresholds (env-tunable) ───────────────────────────────────────────────────
FRESH_COMMITS_MAX="${CHUMP_FRESHNESS_STALE_COMMITS:-15}"
CRITICAL_COMMITS_MIN="${CHUMP_FRESHNESS_COMMITS_THRESHOLD:-50}"
FRESH_BINARY_AGE_MAX="${CHUMP_FRESHNESS_STALE_BINARY_AGE_S:-3600}"
CRITICAL_BINARY_AGE_MIN="${CHUMP_FRESHNESS_BINARY_AGE_S:-14400}"

# ── arg parsing ────────────────────────────────────────────────────────────────
EMIT_JSON=0
for arg in "$@"; do
    case "$arg" in
        --json) EMIT_JSON=1 ;;
        --help|-h)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *) ;;
    esac
done

# ── signal (a): commits-behind via git fetch + rev-list ────────────────────────
commits_behind="unknown"
if [[ -d "$REPO_ROOT/.git" ]] || git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ "${CHUMP_FRESHNESS_DISABLE_FETCH:-0}" != "1" ]]; then
        git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
    fi
    commits_behind="$(git -C "$REPO_ROOT" rev-list HEAD..origin/main --count 2>/dev/null || echo unknown)"
fi

# ── signal (b): binary-age via stat mtime ──────────────────────────────────────
binary_age_s="unknown"
chump_path="$(command -v chump 2>/dev/null || true)"
if [[ -n "$chump_path" && -f "$chump_path" ]]; then
    # macOS stat vs Linux stat
    if [[ "$(uname -s)" == "Darwin" ]]; then
        mtime="$(stat -f %m "$chump_path" 2>/dev/null || echo "")"
    else
        mtime="$(stat -c %Y "$chump_path" 2>/dev/null || echo "")"
    fi
    if [[ -n "$mtime" ]]; then
        now="$(date +%s)"
        binary_age_s="$(( now - mtime ))"
    fi
fi

# ── signal (c): chump cron health (fail-soft) ──────────────────────────────────
# Per META-110/INFRA-2046 the `chump cron health` subcommand may or may not
# exist. We try it with a short timeout; any failure → "unavailable".
cron_health="unavailable"
if [[ -n "$chump_path" ]]; then
    # Probe: does the binary respond to `chump cron health`?
    # We do NOT trust stdout when stderr indicates an unrecognized subcommand.
    set +e
    cron_out="$("$chump_path" cron health --json 2>/dev/null)"
    cron_rc=$?
    set -e
    if [[ $cron_rc -eq 0 && -n "$cron_out" ]]; then
        # Parse JSON status field if present (PASS|WARN|FAIL). Fall through
        # to "unavailable" if the JSON shape is unexpected.
        parsed="$(printf '%s' "$cron_out" | python3 -c \
            'import json,sys; d=json.load(sys.stdin); print(d.get("status","unavailable"))' 2>/dev/null || echo "unavailable")"
        case "$parsed" in
            PASS|WARN|FAIL) cron_health="$parsed" ;;
            *) cron_health="unavailable" ;;
        esac
    fi
fi

# ── signal (d): fleet-bootstrap --check (fail-soft) ────────────────────────────
bootstrap_check="unavailable"
bootstrap_script="$REPO_ROOT/scripts/setup/chump-fleet-bootstrap.sh"
if [[ -x "$bootstrap_script" || -f "$bootstrap_script" ]]; then
    set +e
    bash "$bootstrap_script" --check >/dev/null 2>&1
    bs_rc=$?
    set -e
    if [[ $bs_rc -eq 0 ]]; then
        bootstrap_check="PASS"
    else
        bootstrap_check="FAIL"
    fi
fi

# ── classification ─────────────────────────────────────────────────────────────
# CRITICAL_STALE iff:
#   - commits_behind known AND > CRITICAL_COMMITS_MIN  OR
#   - binary_age_s known AND > CRITICAL_BINARY_AGE_MIN OR
#   - cron_health == FAIL
#
# STALE iff:
#   - commits_behind known AND > FRESH_COMMITS_MAX  OR
#   - binary_age_s known AND > FRESH_BINARY_AGE_MAX OR
#   - cron_health == WARN
#
# FRESH otherwise.
state="FRESH"

if [[ "$commits_behind" =~ ^[0-9]+$ ]] && [[ "$commits_behind" -gt "$CRITICAL_COMMITS_MIN" ]]; then
    state="CRITICAL_STALE"
elif [[ "$binary_age_s" =~ ^[0-9]+$ ]] && [[ "$binary_age_s" -gt "$CRITICAL_BINARY_AGE_MIN" ]]; then
    state="CRITICAL_STALE"
elif [[ "$cron_health" == "FAIL" ]]; then
    state="CRITICAL_STALE"
elif [[ "$commits_behind" =~ ^[0-9]+$ ]] && [[ "$commits_behind" -gt "$FRESH_COMMITS_MAX" ]]; then
    state="STALE"
elif [[ "$binary_age_s" =~ ^[0-9]+$ ]] && [[ "$binary_age_s" -gt "$FRESH_BINARY_AGE_MAX" ]]; then
    state="STALE"
elif [[ "$cron_health" == "WARN" ]]; then
    state="STALE"
fi

# ── emit ───────────────────────────────────────────────────────────────────────
if [[ $EMIT_JSON -eq 1 ]]; then
    printf '{"state":"%s","commits_behind":"%s","binary_age_s":"%s","cron_health":"%s","bootstrap_check":"%s"}\n' \
        "$state" "$commits_behind" "$binary_age_s" "$cron_health" "$bootstrap_check"
else
    printf 'Freshness: %s (commits-behind=%s, binary-age=%ss, cron-health=%s, bootstrap=%s)\n' \
        "$state" "$commits_behind" "$binary_age_s" "$cron_health" "$bootstrap_check"
fi

# ── trunk-red surface (META-177 Lane C / META-179) ────────────────────────────
# If the trunk-red-detector state file exists, trunk is currently RED.
# Surface a warning line in the session digest so the operator sees it
# immediately at session-start rather than discovering it hours later.
_TRUNK_RED_STATE="${CHUMP_TRUNK_RED_STATE_FILE:-$REPO_ROOT/.chump-locks/trunk-red-detector-state.json}"
if [[ -f "$_TRUNK_RED_STATE" ]]; then
    _red_since="$(python3 -c \
        "import json,sys; d=json.load(open('$_TRUNK_RED_STATE')); print(d.get('red_since_ts','unknown'))" \
        2>/dev/null || echo "unknown")"
    # Compute elapsed hours for operator situational awareness.
    _red_hours="?"
    if [[ "$_red_since" != "unknown" ]]; then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            _red_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$_red_since" '+%s' 2>/dev/null || echo "")"
        else
            _red_epoch="$(date -u -d "$_red_since" '+%s' 2>/dev/null || echo "")"
        fi
        [[ -n "${_red_epoch:-}" ]] && _red_hours="$(( ( $(date -u +%s) - _red_epoch ) / 3600 ))"
    fi
    printf 'WARNING: TRUNK-RED for ~%sh (since %s). Check https://github.com/repairman29/chump/actions\n' \
        "$_red_hours" "$_red_since"
fi

case "$state" in
    FRESH)          exit 0 ;;
    STALE)          exit 1 ;;
    CRITICAL_STALE) exit 2 ;;
    *)              exit 0 ;;  # defensive: should not be reachable
esac
