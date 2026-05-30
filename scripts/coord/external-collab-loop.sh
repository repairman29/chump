#!/usr/bin/env bash
# scripts/coord/external-collab-loop.sh — META-104
#
# Harness-neutral CLI for the curator-opus-external-collab role.
# Owns: Marcus customer arc + PITCH.md/HIDDEN_GEMS.md/DEMO_5MIN.md voice &
# freshness + partnership pipeline (INFRA-1501 / INFRA-1506 / INFRA-1511).
#
# Subcommands:
#   tick                 — run all checks in sequence (default)
#   marcus-status        — M-A through M-E milestone status + days stalled
#   voice-audit          — ban-list check on operator-facing docs
#   partnership-pipeline — INFRA-1501/1506/1511 days-open report
#   surface-freshness    — git-age check; flag any doc >14d untouched
#
# Emits ambient events:
#   external_collab_finding  {category, surface, detail}
#     categories: voice_drift | surface_stale | marcus_at_risk | partnership_stalled
#
# Bypass:
#   CHUMP_EXTERNAL_COLLAB_DISABLED=1  — exits 0 immediately (test harness)
#
# Tunables:
#   CHUMP_EC_STALE_DAYS        days threshold for surface-freshness (default 14)
#   CHUMP_EC_MARCUS_STALL_DAYS days threshold for marcus-status at-risk (default 7)
#   CHUMP_EC_AMBIENT_LOG       override ambient.jsonl path
#   CHUMP_EC_REPO_ROOT         override repo root
#
# Rust-First-Bypass: bash-glue across git log / grep / chump; coherent with
# other curator-loop.sh shapes. No state mutation beyond ambient emission.

set -uo pipefail

# ── bypass ───────────────────────────────────────────────────────────────────
if [ "${CHUMP_EXTERNAL_COLLAB_DISABLED:-0}" = "1" ]; then
    echo "[external-collab-loop] CHUMP_EXTERNAL_COLLAB_DISABLED=1 — exiting cleanly"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_EC_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT_LOG="${CHUMP_EC_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STALE_DAYS="${CHUMP_EC_STALE_DAYS:-14}"
MARCUS_STALL_DAYS="${CHUMP_EC_MARCUS_STALL_DAYS:-7}"

GAPS_DIR="$REPO_ROOT/docs/gaps"

# ── Phase 0 inbox-drain helpers (META-161 / META-157) ────────────────────────
_GIT_COMMON_EC="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON_EC" == ".git" ]]; then
    _MAIN_REPO_EC="$REPO_ROOT"
else
    _MAIN_REPO_EC="$(cd "$_GIT_COMMON_EC/.." && pwd)"
fi
LOCK_DIR="${CHUMP_EC_LOCK_DIR:-$_MAIN_REPO_EC/.chump-locks}"
SESSION_ID="${CHUMP_SESSION_ID:-external-collab-$$}"

_INBOX_HELPERS="$SCRIPT_DIR/lib/inbox-helpers.sh"
# shellcheck disable=SC1090
[[ -f "$_INBOX_HELPERS" ]] && source "$_INBOX_HELPERS"

SUBCOMMAND="${1:-tick}"

# ── ambient emit helper ───────────────────────────────────────────────────────
emit_finding() {
    local category="$1"
    local surface="$2"
    local detail="$3"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null
    printf '{"ts":"%s","kind":"external_collab_finding","category":"%s","surface":"%s","detail":"%s"}\n' \
        "$ts" "$category" "$surface" "$detail" \
        >> "$AMBIENT_LOG"
    printf '[external-collab] FINDING category=%s surface=%s detail="%s"\n' \
        "$category" "$surface" "$detail"
}

# ── surface-freshness ─────────────────────────────────────────────────────────
cmd_surface_freshness() {
    echo "[external-collab] surface-freshness check (threshold: ${STALE_DAYS}d)"
    local now
    now=$(date +%s)
    local stale_threshold=$(( STALE_DAYS * 86400 ))
    local all_ok=1

    for doc in "docs/PITCH.md" "docs/HIDDEN_GEMS.md" "docs/DEMO_5MIN.md"; do
        local full_path="$REPO_ROOT/$doc"
        if [ ! -f "$full_path" ]; then
            echo "  [WARN] $doc not found — skipping"
            continue
        fi
        # git log -1 --format=%ct gives unix timestamp of last commit touching the file
        local last_commit_ts
        last_commit_ts=$(git -C "$REPO_ROOT" log -1 --format="%ct" -- "$doc" 2>/dev/null || echo "0")
        if [ -z "$last_commit_ts" ] || [ "$last_commit_ts" = "0" ]; then
            echo "  [INFO] $doc — no git history found"
            continue
        fi
        local age_s=$(( now - last_commit_ts ))
        local age_d=$(( age_s / 86400 ))
        if [ "$age_s" -gt "$stale_threshold" ]; then
            all_ok=0
            emit_finding "surface_stale" "$doc" "last touched ${age_d} days ago (threshold: ${STALE_DAYS}d)"
        else
            printf '  [OK] %s — last touched %dd ago\n' "$doc" "$age_d"
        fi
    done

    if [ "$all_ok" = "1" ]; then
        echo "[external-collab] surface-freshness: all docs within threshold"
    fi
}

# ── voice-audit ───────────────────────────────────────────────────────────────
# Ban-list per INFRA-1728. Terms that erode operator credibility in public docs.
# Use grep -i (POSIX/BSD/GNU compatible) not -P (Perl-only — unavailable on macOS /usr/bin/grep).
# Hyphen variants handled by listing both forms.
BANNED_TERMS=(
    "synergy"
    "revolutionary"
    "disruptive"
    "game-changing"
    "game changing"
    "paradigm"
    "holistic"
    "seamless"
    "cutting-edge"
    "cutting edge"
    "state-of-the-art"
    "state of the art"
    "best-in-class"
    "best in class"
)

cmd_voice_audit() {
    echo "[external-collab] voice-audit (ban-list check per INFRA-1728)"
    local any_drift=0

    for doc in "docs/PITCH.md" "docs/HIDDEN_GEMS.md" "docs/DEMO_5MIN.md"; do
        local full_path="$REPO_ROOT/$doc"
        if [ ! -f "$full_path" ]; then
            echo "  [WARN] $doc not found — skipping"
            continue
        fi
        local doc_drift=0
        for term in "${BANNED_TERMS[@]}"; do
            # grep -iP for case-insensitive perl regex (handles dot as wildcard for hyphens)
            local matches
            matches=$(grep -ci "$term" "$full_path" 2>/dev/null || echo "0")
            if [ "$matches" -gt "0" ]; then
                doc_drift=1
                any_drift=1
                # Show the friendly term (replace . with -)
                local friendly_term="${term//./-}"
                emit_finding "voice_drift" "$doc" "banned term '${friendly_term}' found (${matches} occurrence(s))"
            fi
        done
        if [ "$doc_drift" = "0" ]; then
            echo "  [OK] $doc — no banned terms found"
        fi
    done

    if [ "$any_drift" = "0" ]; then
        echo "[external-collab] voice-audit: all docs clean"
    fi
}

# ── marcus-status ─────────────────────────────────────────────────────────────
# Track M-A through M-E milestones from ROADMAP_MARCUS.md.
# For each milestone, check if its listed gaps are all open (stalled).
cmd_marcus_status() {
    echo "[external-collab] marcus-status (ROADMAP_MARCUS.md milestone tracker)"
    local roadmap="$REPO_ROOT/docs/strategy/ROADMAP_MARCUS.md"
    if [ ! -f "$roadmap" ]; then
        echo "  [WARN] ROADMAP_MARCUS.md not found at $roadmap — using hardcoded milestone map"
    fi

    local now
    now=$(date +%s)
    local stall_threshold=$(( MARCUS_STALL_DAYS * 86400 ))

    # Milestone → gap mapping (baseline 2026-05-24)
    # Format: "MILESTONE:GAP1,GAP2,..."
    local milestones=(
        "M-A:INFRA-1486"
        "M-B:INFRA-1483,INFRA-1484,INFRA-1487"
        "M-C:INFRA-1488"
        "M-D:INFRA-1473,INFRA-1475"
        "M-E:INFRA-1489,INFRA-1479,INFRA-1480,INFRA-1491"
    )

    for entry in "${milestones[@]}"; do
        local milestone="${entry%%:*}"
        local gaps_csv="${entry#*:}"
        local all_open=1
        local any_shipped=0
        local oldest_activity=0

        IFS=',' read -ra gap_ids <<< "$gaps_csv"
        for gap_id in "${gap_ids[@]}"; do
            local gap_file="$GAPS_DIR/${gap_id}.yaml"
            if [ ! -f "$gap_file" ]; then
                echo "  [WARN] $milestone — gap file $gap_id.yaml not found"
                continue
            fi
            # Check status via grep (avoid chump CLI dep in CI)
            local status
            status=$(grep -m1 '^\s*status:' "$gap_file" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "unknown")
            if [ "$status" = "shipped" ] || [ "$status" = "closed" ]; then
                any_shipped=1
                all_open=0
            fi
            # Find last git activity on this gap file
            local last_ts
            last_ts=$(git -C "$REPO_ROOT" log -1 --format="%ct" -- "docs/gaps/${gap_id}.yaml" 2>/dev/null || echo "0")
            [ -z "$last_ts" ] && last_ts=0
            if [ "$last_ts" -gt "$oldest_activity" ]; then
                oldest_activity="$last_ts"
            fi
        done

        local age_s=0
        local age_d=0
        if [ "$oldest_activity" -gt 0 ]; then
            age_s=$(( now - oldest_activity ))
            age_d=$(( age_s / 86400 ))
        fi

        if [ "$any_shipped" = "1" ]; then
            printf '  [SHIPPED] %s — at least one gap shipped\n' "$milestone"
        elif [ "$all_open" = "1" ] && [ "$oldest_activity" -gt 0 ] && [ "$age_s" -gt "$stall_threshold" ]; then
            emit_finding "marcus_at_risk" "ROADMAP_MARCUS.md" \
                "milestone ${milestone} stalled — ${age_d} days since last progress on gaps: ${gaps_csv}"
        else
            printf '  [ACTIVE] %s — gaps: %s (last touched: %dd ago)\n' \
                "$milestone" "$gaps_csv" "$age_d"
        fi
    done
}

# ── partnership-pipeline ──────────────────────────────────────────────────────
# Track INFRA-1501 (Anthropic), INFRA-1506 (license), INFRA-1511 (founding-customer).
cmd_partnership_pipeline() {
    echo "[external-collab] partnership-pipeline status"
    local now
    now=$(date +%s)

    # Format: "GAP:LABEL:STALL_THRESHOLD_DAYS:ESCALATION_MSG"
    local pipeline=(
        "INFRA-1501:Anthropic outreach:30:no reply — escalate per INFRA-1501 AC (Twitter DM or HN mention)"
        "INFRA-1506:License decision:14:license decision awaiting operator sign-off (legal-sensitive)"
        "INFRA-1511:Founding-customer offer:30:founding-customer offer depends on INFRA-1500 launch readiness"
    )

    for entry in "${pipeline[@]}"; do
        IFS=':' read -r gap_id label stall_days escalation_msg <<< "$entry"
        local gap_file="$GAPS_DIR/${gap_id}.yaml"

        if [ ! -f "$gap_file" ]; then
            echo "  [WARN] $gap_id — gap file not found"
            continue
        fi

        local status
        status=$(grep -m1 '^\s*status:' "$gap_file" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "unknown")

        if [ "$status" = "shipped" ] || [ "$status" = "closed" ]; then
            printf '  [SHIPPED] %s — %s\n' "$gap_id" "$label"
            continue
        fi

        # Days since last git activity on the gap file
        local last_ts
        last_ts=$(git -C "$REPO_ROOT" log -1 --format="%ct" -- "docs/gaps/${gap_id}.yaml" 2>/dev/null || echo "0")
        [ -z "$last_ts" ] && last_ts=0

        local age_d=0
        if [ "$last_ts" -gt 0 ]; then
            local age_s=$(( now - last_ts ))
            age_d=$(( age_s / 86400 ))
        fi

        local stall_threshold=$(( stall_days * 86400 ))
        local age_s_actual=0
        [ "$last_ts" -gt 0 ] && age_s_actual=$(( now - last_ts ))

        if [ "$age_s_actual" -gt "$stall_threshold" ]; then
            emit_finding "partnership_stalled" "${gap_id}.yaml" \
                "${gap_id} ${label}: ${escalation_msg} (${age_d} days since last progress)"
        else
            printf '  [OPEN] %s — %s: %dd since last activity (threshold: %dd)\n' \
                "$gap_id" "$label" "$age_d" "$stall_days"
        fi
    done
}

# ── tick (all checks) ─────────────────────────────────────────────────────────
cmd_tick() {
    echo "[external-collab] tick — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "──────────────────────────────────────────"

    # Phase 0: inbox-drain + feedback-peek (META-161 / META-157)
    # Feature flag: CHUMP_FLEET_RECV_SIDE_V0=1
    if [[ "${CHUMP_FLEET_RECV_SIDE_V0:-0}" == "1" ]] && declare -f _phase0_inbox_drain >/dev/null 2>&1; then
        local _ec_actionable=0
        _phase0_inbox_drain "$LOCK_DIR" "$SESSION_ID" "$AMBIENT_LOG" "external-collab" _ec_actionable
        echo "──────────────────────────────────────────"
    fi

    cmd_surface_freshness
    echo "──────────────────────────────────────────"
    cmd_voice_audit
    echo "──────────────────────────────────────────"
    cmd_marcus_status
    echo "──────────────────────────────────────────"
    cmd_partnership_pipeline
    echo "──────────────────────────────────────────"
    echo "[external-collab] tick complete"
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "$SUBCOMMAND" in
    tick|status)         cmd_tick ;;
    marcus-status)       cmd_marcus_status ;;
    voice-audit)         cmd_voice_audit ;;
    partnership-pipeline) cmd_partnership_pipeline ;;
    surface-freshness)   cmd_surface_freshness ;;
    *)
        echo "Usage: $0 {tick|marcus-status|voice-audit|partnership-pipeline|surface-freshness}" >&2
        exit 1
        ;;
esac
