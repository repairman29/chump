#!/usr/bin/env bash
# scripts/coord/quartermaster-audit-loop.sh — META-205 (curator-opus-quartermaster).
#
# Harness-neutral CLI for the quartermaster shelfware-audit daemon. Ticks every
# 5 min via launchd (com.chump.quartermaster-audit.plist). Most ticks exit
# silently after the trigger check.
#
# scanner-anchor: "kind":"shelfware_detected"
# scanner-anchor: "kind":"shelfware_audit_run"
# scanner-anchor: "kind":"quartermaster_heartbeat"
#
# Trigger rule (ship-count-triggered, 30m floor):
#   Fire when: (ships_since_last_audit >= 5)
#           OR (now - last_audit_ts >= 1800s AND ships_since_last_audit >= 1)
#   Never fire when ships == 0.
#
# Checkpoint: .chump/quartermaster-checkpoint.json
#   {"last_audit_sha":"<sha>","last_audit_ts":<epoch>}
#   First run: seeds from HEAD~5 on origin/main.
#
# Self-throttle: max 5 follow-up gaps per audit run; overflow to
#   .chump/quartermaster-deferred.jsonl (one JSON line per finding).
#
# Usage:
#   scripts/coord/quartermaster-audit-loop.sh tick           # full tick (trigger-check + run if FIRE)
#   scripts/coord/quartermaster-audit-loop.sh run            # force an audit run
#   scripts/coord/quartermaster-audit-loop.sh trigger-check  # print FIRE or HOLD + exit 0
#   scripts/coord/quartermaster-audit-loop.sh drain-deferred # file next batch from deferred queue
#   scripts/coord/quartermaster-audit-loop.sh heartbeat      # emit heartbeat + exit 0
#   scripts/coord/quartermaster-audit-loop.sh help           # print this
#
# Exit codes:
#   0 — success (or HOLD / zero ships)
#   1 — missing required arg
#   2 — bad subcommand
#   3 — git unavailable / not in a repo
#
# Rust-First-Bypass: bash daemon + plist + docs only; no state.db / canonical-store mutation
#   (writes are ambient.jsonl appends and chump gap reserve calls — canonical mutators)
# Rust-First-Bypass-Accept: loc,state,hot

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi

LOCK_DIR="$MAIN_REPO/.chump-locks"
CHUMP_DIR="${CHUMP_DIR:-$MAIN_REPO/.chump}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-quartermaster-audit-$$}"
CHECKPOINT_FILE="$CHUMP_DIR/quartermaster-checkpoint.json"
DEFERRED_FILE="$CHUMP_DIR/quartermaster-deferred.jsonl"

# Max follow-up gaps per audit run (self-throttle, AC#6).
MAX_GAPS_PER_RUN="${CHUMP_QUARTERMASTER_MAX_GAPS:-5}"

# Trigger thresholds
SHIP_THRESHOLD="${CHUMP_QUARTERMASTER_SHIP_THRESHOLD:-5}"
AGE_THRESHOLD_S="${CHUMP_QUARTERMASTER_AGE_THRESHOLD_S:-1800}"

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift || true

# ── helpers ────────────────────────────────────────────────────────────────

ambient_emit() {
    local kind="$1" payload="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$AMBIENT_LOG")"
    if [[ -n "$payload" ]]; then
        printf '{"ts":"%s","session":"%s","kind":"%s",%s}\n' \
            "$ts" "$SESSION_ID" "$kind" "$payload" >> "$AMBIENT_LOG"
    else
        printf '{"ts":"%s","session":"%s","kind":"%s"}\n' \
            "$ts" "$SESSION_ID" "$kind" >> "$AMBIENT_LOG"
    fi
}

# Read checkpoint → sets LAST_SHA and LAST_TS (epoch seconds).
read_checkpoint() {
    LAST_SHA=""
    LAST_TS=0
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        LAST_SHA="$(python3 -c "import json; d=json.load(open('$CHECKPOINT_FILE')); print(d.get('last_audit_sha',''))" 2>/dev/null || echo "")"
        LAST_TS="$(python3 -c "import json; d=json.load(open('$CHECKPOINT_FILE')); print(d.get('last_audit_ts',0))" 2>/dev/null || echo "0")"
    fi

    # Seed on first run: use HEAD~5 of origin/main.
    if [[ -z "$LAST_SHA" ]]; then
        git fetch origin main --quiet 2>/dev/null || true
        LAST_SHA="$(git rev-parse "origin/main~5" 2>/dev/null || git rev-parse "origin/main" 2>/dev/null || echo "")"
        LAST_TS=0
    fi
}

# Write checkpoint atomically (via tmp file).
write_checkpoint() {
    local sha="$1" ts="$2"
    mkdir -p "$CHUMP_DIR"
    local tmp
    tmp="$(mktemp "$CHUMP_DIR/qm-checkpoint-XXXXXX.json")"
    printf '{"last_audit_sha":"%s","last_audit_ts":%s}\n' "$sha" "$ts" > "$tmp"
    mv "$tmp" "$CHECKPOINT_FILE"
}

# Count commits between LAST_SHA and origin/main.
count_ships() {
    local last_sha="$1"
    if [[ -z "$last_sha" ]]; then
        echo "0"
        return
    fi
    git fetch origin main --quiet 2>/dev/null || true
    git log "${last_sha}..origin/main" --oneline 2>/dev/null | wc -l | tr -d ' '
}

# ── role-doc grep targets ─────────────────────────────────────────────────

ROLE_DOC_PATHS=(
    ".claude/agents"
    "CLAUDE.md"
    "AGENTS.md"
    "docs/process"
    "docs/agents"
)

grep_role_docs() {
    local pattern="$1"
    local found=0
    for target in "${ROLE_DOC_PATHS[@]}"; do
        local abs_target="$MAIN_REPO/$target"
        if [[ -d "$abs_target" ]]; then
            if grep -rl "$pattern" "$abs_target" 2>/dev/null | head -1 | grep -q .; then
                found=1
                break
            fi
        elif [[ -f "$abs_target" ]]; then
            if grep -q "$pattern" "$abs_target" 2>/dev/null; then
                found=1
                break
            fi
        fi
    done
    echo "$found"
}

# Guess the best curator for a given artifact basename.
guess_curator() {
    local artifact="$1"
    case "$artifact" in
        *-loop.sh)                   echo "curator-opus-decompose" ;;
        test-*.sh)                   echo "curator-opus-ci-audit" ;;
        install-*-launchd.sh|*.plist) echo "curator-opus-infra-watcher" ;;
        rotate-*.sh)                 echo "curator-opus-quartermaster" ;;
        *.md)                        echo "curator-opus-md-links" ;;
        *)                           echo "curator-opus-target" ;;
    esac
}

# ── trigger-check ─────────────────────────────────────────────────────────

cmd_trigger_check() {
    read_checkpoint
    local ships
    ships="$(count_ships "$LAST_SHA")"
    local now
    now="$(date +%s)"
    local age=$(( now - LAST_TS ))

    if [[ "$ships" -eq 0 ]]; then
        echo "HOLD (ships=0 — nothing to audit)"
        return 0
    fi

    if [[ "$ships" -ge "$SHIP_THRESHOLD" ]]; then
        echo "FIRE (ships=$ships >= threshold=$SHIP_THRESHOLD)"
        return 0
    fi

    if [[ "$age" -ge "$AGE_THRESHOLD_S" ]]; then
        echo "FIRE (age=${age}s >= ${AGE_THRESHOLD_S}s AND ships=$ships >= 1)"
        return 0
    fi

    echo "HOLD (ships=$ships < $SHIP_THRESHOLD, age=${age}s < ${AGE_THRESHOLD_S}s)"
    return 0
}

# ── run (full audit) ─────────────────────────────────────────────────────

cmd_run() {
    read_checkpoint
    local ships
    ships="$(count_ships "$LAST_SHA")"

    if [[ "$ships" -eq 0 ]]; then
        echo "quartermaster-audit: no new ships since last audit — exiting cleanly"
        return 0
    fi

    echo "quartermaster-audit: auditing $ships commit(s) since $LAST_SHA"

    git fetch origin main --quiet 2>/dev/null || true
    local new_head
    new_head="$(git rev-parse origin/main 2>/dev/null)"

    # Collect all commit SHAs since last_sha (oldest first).
    local commits_file
    commits_file="$(mktemp)"
    git log "${LAST_SHA}..origin/main" --reverse --format="%H %s" 2>/dev/null > "$commits_file" || true

    local ships_checked=0
    local shelfware_found=0
    local gaps_filed=0
    local deferred_count=0

    mkdir -p "$CHUMP_DIR"

    while IFS=" " read -r sha rest || [[ -n "$sha" ]]; do
        [[ -z "$sha" ]] && continue
        ships_checked=$(( ships_checked + 1 ))

        # Extract gap_id from commit subject.
        local gap_id=""
        gap_id="$(echo "$rest" | grep -oE '(INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|FLEET|DOC|MEM|VOA|SCALE)-[0-9]+' | head -1 || true)"

        # Get touched files under watched prefixes.
        local touched_file
        touched_file="$(mktemp)"
        git show --stat "$sha" 2>/dev/null \
            | grep -E '^\s+(scripts/|docs/|crates/|\.claude/agents/)' \
            | awk '{print $1}' \
            | xargs -I{} basename {} 2>/dev/null \
            | sort -u > "$touched_file" || true

        # Check each (gap_id, artifact) pair.
        local artifact
        while IFS= read -r artifact || [[ -n "$artifact" ]]; do
            [[ -z "$artifact" ]] && continue

            local gap_hit=0 artifact_hit=0
            [[ -n "$gap_id" ]] && gap_hit="$(grep_role_docs "$gap_id")"
            artifact_hit="$(grep_role_docs "$artifact")"

            # Shelfware: both gap_id AND artifact_basename absent from role docs.
            if [[ "$gap_hit" -eq 0 && "$artifact_hit" -eq 0 ]]; then
                shelfware_found=$(( shelfware_found + 1 ))
                local role_candidate
                role_candidate="$(guess_curator "$artifact")"

                local finding_json
                finding_json="$(printf '{"sha":"%s","gap_id":"%s","artifact":"%s","role_candidate":"%s"}' \
                    "$sha" "${gap_id:-unknown}" "$artifact" "$role_candidate")"

                if [[ "$gaps_filed" -lt "$MAX_GAPS_PER_RUN" ]]; then
                    # Emit shelfware_detected ambient event.
                    ambient_emit "shelfware_detected" \
                        "\"gap_id\":\"${gap_id:-unknown}\",\"artifact\":\"$artifact\",\"role_candidate\":\"$role_candidate\",\"sha\":\"${sha:0:12}\""

                    # File a follow-up gap via chump.
                    local gap_title="EFFECTIVE: Wire ${artifact} into role ${role_candidate}"
                    local gap_ac="1. Edit the role-doc for ${role_candidate} to reference ${artifact} (shipped in ${gap_id:-commit ${sha:0:12}}) — add it to the Lane scope section or the Cross-references table. 2. Verify with: grep -l '${artifact}' .claude/agents/*.md CLAUDE.md AGENTS.md docs/process/*.md — must return at least one hit. 3. Smoke-test: bash scripts/ci/test-quartermaster-audit-loop.sh."
                    local new_gap_id=""
                    if command -v chump >/dev/null 2>&1; then
                        new_gap_id="$(CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
                            chump gap reserve \
                            --domain EFFECTIVE \
                            --title "$gap_title" \
                            --acceptance-criteria "$gap_ac" \
                            --effort xs \
                            --priority P2 \
                            2>/dev/null | grep -oE '(INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|FLEET|DOC|MEM|VOA|SCALE)-[0-9]+' | head -1 || echo "")"
                    fi
                    gaps_filed=$(( gaps_filed + 1 ))
                    echo "  filed gap ${new_gap_id:-?} for shelfware: $artifact (${gap_id:-unknown})"
                else
                    # Overflow to deferred queue.
                    printf '%s\n' "$finding_json" >> "$DEFERRED_FILE"
                    deferred_count=$(( deferred_count + 1 ))
                fi
            fi
        done < "$touched_file"
        rm -f "$touched_file"
    done < "$commits_file"
    rm -f "$commits_file"

    # Emit summary event.
    ambient_emit "shelfware_audit_run" \
        "\"ships_checked\":$ships_checked,\"shelfware_found\":$shelfware_found,\"gaps_filed\":$gaps_filed,\"deferred_count\":$deferred_count"

    # Write new checkpoint.
    write_checkpoint "$new_head" "$(date +%s)"

    echo "quartermaster-audit: done. ships=$ships_checked shelfware=$shelfware_found gaps_filed=$gaps_filed deferred=$deferred_count"
    return 0
}

# ── drain-deferred ────────────────────────────────────────────────────────

cmd_drain_deferred() {
    if [[ ! -f "$DEFERRED_FILE" ]]; then
        echo "quartermaster-audit: no deferred findings"
        return 0
    fi

    local total
    total="$(wc -l < "$DEFERRED_FILE" | tr -d ' ')"
    echo "quartermaster-audit: draining up to $MAX_GAPS_PER_RUN of $total deferred findings"

    local count=0
    local remaining_file
    remaining_file="$(mktemp)"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$count" -ge "$MAX_GAPS_PER_RUN" ]]; then
            printf '%s\n' "$line" >> "$remaining_file"
            continue
        fi

        local gap_id artifact role_candidate
        gap_id="$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('gap_id','unknown'))" 2>/dev/null || echo "unknown")"
        artifact="$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('artifact',''))" 2>/dev/null || echo "")"
        role_candidate="$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('role_candidate','curator-opus-target'))" 2>/dev/null || echo "curator-opus-target")"

        [[ -z "$artifact" ]] && continue

        ambient_emit "shelfware_detected" \
            "\"gap_id\":\"$gap_id\",\"artifact\":\"$artifact\",\"role_candidate\":\"$role_candidate\",\"source\":\"deferred\""

        if command -v chump >/dev/null 2>&1; then
            CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
                chump gap reserve \
                --domain EFFECTIVE \
                --title "EFFECTIVE: Wire ${artifact} into role ${role_candidate}" \
                --acceptance-criteria "1. Edit ${role_candidate} role-doc to reference ${artifact} (shipped in ${gap_id}). 2. Verify: grep -l '${artifact}' .claude/agents/*.md CLAUDE.md AGENTS.md docs/process/*.md — must return at least one hit." \
                --effort xs \
                --priority P2 \
                >/dev/null 2>&1 || true
        fi
        count=$(( count + 1 ))
        echo "  filed deferred finding: $artifact ($gap_id)"
    done < "$DEFERRED_FILE"

    mv "$remaining_file" "$DEFERRED_FILE"
    echo "quartermaster-audit: drained $count findings; $(wc -l < "$DEFERRED_FILE" | tr -d ' ') remaining"
    return 0
}

# ── heartbeat ─────────────────────────────────────────────────────────────

cmd_heartbeat() {
    ambient_emit "quartermaster_heartbeat" "\"role\":\"curator-opus-quartermaster\""

    if [[ -x "$MAIN_REPO/scripts/coord/broadcast.sh" ]] \
       && [[ "${CHUMP_QUARTERMASTER_NO_BROADCAST:-0}" != "1" ]]; then
        local today
        today="$(date -u +%Y-%m-%d)"
        "$MAIN_REPO/scripts/coord/broadcast.sh" \
            --to "orchestrator-opus-$today" \
            INFO "quartermaster-audit heartbeat" >/dev/null 2>&1 || true
    fi
    echo "quartermaster-audit: heartbeat emitted"
    return 0
}

# ── tick (full cron entry point) ──────────────────────────────────────────

cmd_tick() {
    local decision
    decision="$(cmd_trigger_check)"
    echo "quartermaster-audit trigger-check: $decision"

    if echo "$decision" | grep -q "^FIRE"; then
        cmd_run
    fi
    return 0
}

# ── dispatcher ────────────────────────────────────────────────────────────

case "$cmd" in
    tick)            cmd_tick ;;
    run)             cmd_run ;;
    trigger-check)   cmd_trigger_check ;;
    drain-deferred)  cmd_drain_deferred ;;
    heartbeat)       cmd_heartbeat ;;
    help|-h|--help)
        grep '^#' "$0" | sed -n '2,35p' | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "quartermaster-audit-loop: unknown subcommand '$cmd' (try: help)" >&2
        exit 2
        ;;
esac
