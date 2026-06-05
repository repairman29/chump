#!/usr/bin/env bash
# external-clone-reaper.sh (MISSION-035, Phase-B Tier-1 of MISSION-032)
# — LRU clone GC under ~/.chump/external/<owner>/<repo>/clone/.
#
# Why: MISSION-032 Phase-B scale (10–100 repos → 10,000 repos). Each tracked
# repo can accumulate a git clone under ~/.chump/external/<owner>/<repo>/clone/.
# A clone can be 100s of MB; 100 repos unchecked = multi-GB disk growth.
#
# Strategy: Two independent reap triggers (OR logic):
#   1. AGE  — clone mtime older than CHUMP_EXTERNAL_CLONE_MAX_AGE_D (default 14)
#             days. These are "untouched" repos; safe to evict and re-clone on demand.
#   2. BUDGET — total disk usage of all clones exceeds
#               CHUMP_EXTERNAL_CLONE_BUDGET_GB (default 20) GB. When over budget,
#               reap in LRU order (oldest mtime first) until back under budget.
#
# Safety:
#   - Paranoid path-prefix check: refuses to rm -rf anything that doesn't
#     start with the expected CHUMP_EXTERNAL_ROOT prefix (defense against
#     env-var injection).
#   - Skips repos with an active claim lease.
#   - --dry-run is the default; --execute opts in.
#   - rm -rf uses -- separator to guard against weird filenames.
#   - Bash 3.2 compatible (macOS): no mapfile, no associative arrays.
#
# Usage:
#   ./scripts/ops/external-clone-reaper.sh                 # dry-run
#   ./scripts/ops/external-clone-reaper.sh --execute       # actually reap
#   ./scripts/ops/external-clone-reaper.sh --execute --budget-gb 10 --max-age-d 7
#
# Install daily via launchd:
#   cp scripts/setup/com.chump.external-clone-reaper.plist ~/Library/LaunchAgents/
#   launchctl load -w ~/Library/LaunchAgents/com.chump.external-clone-reaper.plist
#
# Tunable env:
#   CHUMP_EXTERNAL_CLONE_BUDGET_GB   (default 20) — max total GB for all clones
#   CHUMP_EXTERNAL_CLONE_MAX_AGE_D   (default 14) — max days a clone may sit untouched

set -euo pipefail

DRY_RUN=1
BUDGET_GB="${CHUMP_EXTERNAL_CLONE_BUDGET_GB:-20}"
MAX_AGE_D="${CHUMP_EXTERNAL_CLONE_MAX_AGE_D:-14}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --execute) DRY_RUN=0; shift ;;
        --budget-gb) BUDGET_GB="$2"; shift 2 ;;
        --budget-gb=*) BUDGET_GB="${1#--budget-gb=}"; shift ;;
        --max-age-d) MAX_AGE_D="$2"; shift 2 ;;
        --max-age-d=*) MAX_AGE_D="${1#--max-age-d=}"; shift ;;
        -h|--help)
            sed -n '2,40p' "$0"
            exit 0 ;;
        *) echo "[external-clone-reaper] unknown flag: $1" >&2; exit 2 ;;
    esac
done

EXTERNAL_ROOT="${CHUMP_EXTERNAL_ROOT:-$HOME/.chump/external}"
LOCKS_ROOT="${CHUMP_LOCKS_ROOT:-$HOME/Projects/Chump/.chump-locks}"
AMBIENT="${CHUMP_AMBIENT_PATH:-$HOME/Projects/Chump/.chump-locks/ambient.jsonl}"

# ── Root-level safety gate (env-injection defense) ──────────────────────
# EXTERNAL_ROOT must resolve to $HOME/.chump/ or the test-override base
# (CHUMP_EXTERNAL_ROOT_ALLOW_OUTSIDE=1 bypasses for unit tests only).
# In production the gate refuses any root that doesn't live under $HOME/.chump/.
if [[ "${CHUMP_EXTERNAL_ROOT_ALLOW_OUTSIDE:-0}" != "1" ]]; then
    _canon_home_chump="$(cd "$HOME/.chump" 2>/dev/null && pwd)" || _canon_home_chump="$HOME/.chump"
    _canon_root="$(cd "$EXTERNAL_ROOT" 2>/dev/null && pwd)" || _canon_root="$EXTERNAL_ROOT"
    if [[ "$_canon_root" != "$_canon_home_chump"* ]]; then
        echo "[external-clone-reaper] FATAL: CHUMP_EXTERNAL_ROOT ($EXTERNAL_ROOT) is outside \$HOME/.chump/ — refusing to operate (env-injection guard). Set CHUMP_EXTERNAL_ROOT_ALLOW_OUTSIDE=1 to bypass in tests." >&2
        exit 3
    fi
fi

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log() { printf '[external-clone-reaper] %s %s\n' "$(_ts)" "$*"; }

# Emit an ambient event (best-effort; no failure if path absent).
# scanner-anchor: "kind":"external_clone_reaped"
_emit() {
    local kind="$1" payload="$2"
    if [[ -f "$AMBIENT" ]] || [[ -d "$(dirname "$AMBIENT")" ]]; then
        printf '{"ts":"%s","kind":"%s",%s}\n' \
            "$(_ts)" "$kind" "$payload" >> "$AMBIENT" 2>/dev/null || true
    fi
}

# Validate numeric env args.
[[ "$BUDGET_GB" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
    _log "--budget-gb must be a positive number (got: $BUDGET_GB)"; exit 2
}
[[ "$MAX_AGE_D" =~ ^[0-9]+$ ]] || {
    _log "--max-age-d must be a non-negative integer (got: $MAX_AGE_D)"; exit 2
}
# Safety: budget=0 is allowed as a way to say "evict everything over 0 GB",
# which is a valid stress-test / emergency-clear mode. Document it.
if [[ "$BUDGET_GB" == "0" ]]; then
    _log "WARN: --budget-gb 0 — will reap ALL clones to satisfy zero-byte budget"
fi

[[ ! -d "$EXTERNAL_ROOT" ]] && {
    _log "no $EXTERNAL_ROOT — nothing to reap"
    exit 0
}

# ── Portable mtime reader (macOS / Linux) ─────────────────────────────────
# Probe once at startup; same pattern used in mission-scoreboard.sh.
if stat -f %m "$EXTERNAL_ROOT" >/dev/null 2>&1; then
    _mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
else
    _mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
fi

_log "starting (budget_gb=$BUDGET_GB, max_age_d=$MAX_AGE_D, dry_run=$DRY_RUN, root=$EXTERNAL_ROOT)"

NOW_EPOCH=$(date +%s)
MAX_AGE_SECS=$((MAX_AGE_D * 86400))
# Budget in KB (du -sk returns KB).
# Use awk -v to pass the decimal value so the arithmetic is correct.
BUDGET_KB=$(awk -v gb="$BUDGET_GB" 'BEGIN{printf "%d", gb * 1024 * 1024}')

total_repos=0
total_reaped=0
total_freed_kb=0

# ── Safety: verify a path is under the expected root ────────────────────
_safe_path() {
    local p="$1"
    # Resolve leading ~ and ensure it begins with the canonical root.
    local root_real
    root_real="$(cd "$EXTERNAL_ROOT" && pwd)"
    local p_parent
    p_parent="$(dirname "$p")"
    local p_real
    p_real="$(cd "$p_parent" 2>/dev/null && pwd)/$(basename "$p")" || return 1
    [[ "$p_real" == "$root_real"/* ]] || return 1
}

# ── Active-lease check ────────────────────────────────────────────────────
_has_active_lease() {
    local owner="$1" repo="$2"
    # Check .chump-locks/claim-*.json files for a reference to this repo path.
    if compgen -G "$LOCKS_ROOT/claim-*.json" >/dev/null 2>&1; then
        if grep -ql "\"$owner/$repo\"" "$LOCKS_ROOT/claim-*.json" 2>/dev/null; then
            return 0
        fi
    fi
    # Check state.db leases if available.
    local db
    db="$(dirname "$LOCKS_ROOT")/.chump/state.db"
    if [[ -f "$db" ]]; then
        local cnt
        cnt=$(sqlite3 "$db" \
            "SELECT COUNT(*) FROM leases WHERE path LIKE '%/$owner/$repo%' AND status='active';" \
            2>/dev/null || echo 0)
        [[ "$cnt" -gt 0 ]] && return 0
    fi
    return 1
}

# ── Build sorted list: (mtime_epoch clone_dir) for all clone dirs ─────────
# Collect all clone dirs: ~/.chump/external/<owner>/<repo>/clone/
clone_dirs=()
while IFS= read -r -d '' clone_dir; do
    clone_dirs+=("$clone_dir")
done < <(find "$EXTERNAL_ROOT" -mindepth 3 -maxdepth 3 -type d -name clone -print0 2>/dev/null)

total_repos="${#clone_dirs[@]}"
_log "found $total_repos clone dirs"

[[ "$total_repos" -eq 0 ]] && {
    _log "done — repos=0 reaped=0 freed_gb=0 (dry_run=$DRY_RUN)"
    _emit "external_clone_reaped" \
        "\"repos\":0,\"reaped\":0,\"kept_count\":0,\"freed_gb\":0,\"budget_gb\":$BUDGET_GB,\"max_age_d\":$MAX_AGE_D,\"dry_run\":$DRY_RUN"
    exit 0
}

# ── Pass 1: Age-based reap ────────────────────────────────────────────────
# Reap any clone whose mtime is older than max_age_d, regardless of budget.
age_reaped_dirs=()
for clone_dir in "${clone_dirs[@]}"; do
    # Extract owner/repo from path: strip root prefix, then strip /clone suffix.
    rel="${clone_dir#"$EXTERNAL_ROOT"/}"
    owner_repo="${rel%/clone}"
    owner="${owner_repo%/*}"
    repo="${owner_repo#*/}"

    mtime_epoch=$(_mtime "$clone_dir")
    age_secs=$((NOW_EPOCH - mtime_epoch))

    [[ "$age_secs" -le "$MAX_AGE_SECS" ]] && continue

    # Active lease check — skip if repo is in-use.
    if _has_active_lease "$owner" "$repo"; then
        _log "SKIP (active lease): $owner/$repo"
        continue
    fi

    # Safety prefix check.
    if ! _safe_path "$clone_dir"; then
        _log "WARN: path-prefix safety refused to reap $clone_dir"
        continue
    fi

    size_kb=$(du -sk "$clone_dir" 2>/dev/null | awk '{print $1}')
    age_days=$((age_secs / 86400))
    _log "age-reap $owner/$repo (age=${age_days}d, size=${size_kb}KB)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        _log "DRY: would rm -rf -- $clone_dir"
    else
        if rm -rf -- "$clone_dir"; then
            _log "reaped $clone_dir"
            total_freed_kb=$((total_freed_kb + size_kb))
        else
            _log "WARN: failed to remove $clone_dir"
            continue
        fi
    fi
    total_reaped=$((total_reaped + 1))
    age_reaped_dirs+=("$clone_dir")
done

# ── Build mtime-sorted list of REMAINING clones for budget check ──────────
# Items format: "<epoch> <clone_dir>" — sort numerically by epoch (LRU first).
mtime_sorted=()
while IFS= read -r -d '' clone_dir; do
    # Skip already reaped dirs.
    already=0
    for r in "${age_reaped_dirs[@]+"${age_reaped_dirs[@]}"}"; do
        [[ "$r" == "$clone_dir" ]] && { already=1; break; }
    done
    [[ "$already" -eq 1 ]] && continue
    [[ -d "$clone_dir" ]] || continue  # disappeared (dry-run: always exists)
    mt=$(_mtime "$clone_dir")
    mtime_sorted+=("$mt $clone_dir")
done < <(find "$EXTERNAL_ROOT" -mindepth 3 -maxdepth 3 -type d -name clone -print0 2>/dev/null)

# Sort: oldest (smallest epoch) first.
IFS=$'\n' sorted_list=($(printf '%s\n' "${mtime_sorted[@]+"${mtime_sorted[@]}"}" | sort -n))
unset IFS

# ── Pass 2: Budget-based LRU reap ────────────────────────────────────────
# Measure total remaining disk usage. If over budget, reap LRU until under.
total_kb=0
clone_sizes=()   # parallel to sorted_list; holds KB per entry
for item in "${sorted_list[@]+"${sorted_list[@]}"}"; do
    clone_dir="${item#* }"
    sz_kb=$(du -sk "$clone_dir" 2>/dev/null | awk '{print $1}')
    clone_sizes+=("$sz_kb")
    total_kb=$((total_kb + sz_kb))
done

total_gb_str=$(echo "$total_kb" | awk '{printf "%.2f", $1/1024/1024}')
_log "total clone disk usage: ${total_gb_str}GB (budget=${BUDGET_GB}GB)"

if [[ "$total_kb" -gt "$BUDGET_KB" ]]; then
    _log "over budget — evicting LRU clones until under ${BUDGET_GB}GB"
    idx=0
    for item in "${sorted_list[@]+"${sorted_list[@]}"}"; do
        clone_dir="${item#* }"
        [[ "$total_kb" -le "$BUDGET_KB" ]] && break

        # Extract owner/repo.
        rel="${clone_dir#"$EXTERNAL_ROOT"/}"
        owner_repo="${rel%/clone}"
        owner="${owner_repo%/*}"
        repo="${owner_repo#*/}"

        # Skip if active lease.
        if _has_active_lease "$owner" "$repo"; then
            _log "SKIP (active lease): $owner/$repo"
            idx=$((idx + 1))
            continue
        fi

        # Safety prefix check.
        if ! _safe_path "$clone_dir"; then
            _log "WARN: path-prefix safety refused to reap $clone_dir"
            idx=$((idx + 1))
            continue
        fi

        sz_kb="${clone_sizes[$idx]:-0}"
        _log "budget-reap $owner/$repo (size=${sz_kb}KB, total_remaining=${total_kb}KB)"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            _log "DRY: would rm -rf -- $clone_dir"
        else
            if rm -rf -- "$clone_dir"; then
                _log "reaped $clone_dir"
                total_freed_kb=$((total_freed_kb + sz_kb))
            else
                _log "WARN: failed to remove $clone_dir"
                idx=$((idx + 1))
                continue
            fi
        fi
        total_kb=$((total_kb - sz_kb))
        total_reaped=$((total_reaped + 1))
        idx=$((idx + 1))
    done
fi

kept_count=$((total_repos - total_reaped))
freed_gb_str=$(echo "$total_freed_kb" | awk '{printf "%.3f", $1/1024/1024}')

_log "done — repos=$total_repos reaped=$total_reaped kept=$kept_count freed=${freed_gb_str}GB (dry_run=$DRY_RUN)"

_emit "external_clone_reaped" \
    "\"repos\":$total_repos,\"reaped\":$total_reaped,\"kept_count\":$kept_count,\"freed_gb\":$freed_gb_str,\"budget_gb\":$BUDGET_GB,\"max_age_d\":$MAX_AGE_D,\"dry_run\":$DRY_RUN"

exit 0
