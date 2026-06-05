#!/usr/bin/env bash
# mission-scoreboard.sh (MISSION-014) — READ-ONLY scoreboard for the operative
# mission (MISSION-010). The one honest measure of whether Chump is moving
# toward zero-human-touch software delivery. Pairs with docs/MISSION.md.
#
# No state mutation. Safe to run anytime. Exit 0 = HANDS-OFF/ON-TRACK,
# exit 1 = DRIFTING/STALLED (so a conductor loop can gate on $?).
#
# Modes:
#   (default)     single-repo view focused on BEAST (the proof)
#   --per-repo    per-repo block for every row in `chump repos list` + aggregate
#   --aggregate   aggregate-only rollup (no per-repo blocks)
#
# Follow-up: port to `chump kpi mission` (Rust) once metrics stabilize.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" 2>/dev/null || true

MODE="default"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --per-repo)  MODE="per-repo"; shift ;;
        --aggregate) MODE="aggregate"; shift ;;
        -h|--help)
            sed -n '2,15p' "$0"
            exit 0 ;;
        *) echo "[mission-scoreboard] unknown flag: $1" >&2; exit 2 ;;
    esac
done

BEAST="repairman29/BEAST-MODE"
ACTIVE_MISSION="$(cat "$HOME/.chump/ACTIVE_MISSION" 2>/dev/null || echo MISSION-010)"
now=$(date -u +%s)

# Portable date helpers (BSD/macOS first, GNU fallback)
days_ago() { date -u -v-"$1"d +%Y-%m-%d 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null; }
iso_to_epoch() { date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || echo 0; }

wk="$(days_ago 7)"; day="$(days_ago 1)"

# MISSION-037: per-repo block. Prints ①/②/③ for one repo.
# Args: $1 = owner/repo
score_one_repo() {
    local repo="$1"
    local beast_ships ratio_str="n/a" linked_count=0 last_ship_age="?"

    # ① binary: zero-touch ship this week (we don't differentiate touched vs zero-touch
    # at the per-repo grain — just "did Chump merge anything there?")
    beast_ships=$(gh pr list -R "$repo" --state merged --search "merged:>=$wk" --json number --jq 'length' 2>/dev/null)
    beast_ships="${beast_ships:-0}"

    # ② mission-link rate for THIS repo (count gaps tagged for this repo)
    if command -v sqlite3 >/dev/null 2>&1 && [[ -f .chump/state.db ]]; then
        linked_count=$(sqlite3 .chump/state.db \
            "SELECT COUNT(*) FROM gaps WHERE skills_required LIKE '%external_repo:${repo}%' AND status='open';" \
            2>/dev/null || echo 0)
    fi

    # ④ last-merge age in this repo (in days, to keep output tight)
    local last_merge_iso
    last_merge_iso=$(gh pr list -R "$repo" --state merged --limit 1 --json mergedAt --jq '.[0].mergedAt' 2>/dev/null)
    if [[ -n "$last_merge_iso" ]]; then
        local last_ep age_days
        last_ep=$(iso_to_epoch "$last_merge_iso")
        age_days=$(( (now - last_ep) / 86400 ))
        last_ship_age="${age_days}d"
    fi

    printf "  %-35s  ships(7d)=%-3s  open_gaps_tagged=%-3s  last_ship=%s\n" \
        "$repo" "$beast_ships" "$linked_count" "$last_ship_age"

    # Return aggregate state via stdout-only-channel? Use external accumulators.
    AGG_SHIPS_WK=$((AGG_SHIPS_WK + beast_ships))
    AGG_TAGGED=$((AGG_TAGGED + linked_count))
    if [[ "$beast_ships" -gt 0 ]]; then
        AGG_REPOS_SHIPPED_WK=$((AGG_REPOS_SHIPPED_WK + 1))
    fi
}

# Enumerate tracked repos. Returns owner/repo per line, or empty if unavailable.
list_tracked_repos() {
    if command -v chump >/dev/null 2>&1; then
        # chump repos list --json gives well-shaped output; fall back to raw column scan
        chump repos list --json 2>/dev/null \
            | python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin)
    if isinstance(rows, list):
        for r in rows:
            rid = r.get('id') if isinstance(r, dict) else None
            if rid: print(rid)
except Exception:
    pass
" 2>/dev/null
    fi
    # Fallback: direct SQL (works even if CLI subcommand not wired in old binary)
    if command -v sqlite3 >/dev/null 2>&1 && [[ -f .chump/state.db ]]; then
        sqlite3 .chump/state.db "SELECT id FROM repos WHERE status='active';" 2>/dev/null
    fi
}

echo "═══ CHUMP MISSION SCOREBOARD ═══  $(date -u +%Y-%m-%dT%H:%MZ)"
echo "Mission: $ACTIVE_MISSION — zero-human-touch software delivery; proof: $BEAST 0→1"
echo "(read-only; see docs/MISSION.md)"
echo

# ── MISSION-037: per-repo + aggregate rollup ─────────────────────────────────
# When --per-repo or --aggregate, scoreboard rolls up across every active repo
# (from `chump repos list`, the MISSION-033 derived index) instead of focusing
# solely on BEAST. Exits 0 when at least one repo has shipped this week AND
# tagged-gap coverage is non-zero across the fleet; exits 1 otherwise.
if [[ "$MODE" == "per-repo" || "$MODE" == "aggregate" ]]; then
    AGG_SHIPS_WK=0
    AGG_TAGGED=0
    AGG_REPOS_SHIPPED_WK=0
    AGG_REPO_COUNT=0

    # Pre-flight: enumerate. Always include BEAST as the canonical repo even
    # if the repos table is empty (today's reality before MISSION-041 backfill
    # flows through gap import).
    repo_list_tmp="$(list_tracked_repos 2>/dev/null || true)"
    if [[ -z "$repo_list_tmp" ]]; then
        repo_list_tmp="$BEAST"
        echo "(no repos in registry — falling back to BEAST canonical: $BEAST)"
        echo
    fi

    if [[ "$MODE" == "per-repo" ]]; then
        echo "═══ PER-REPO ═══"
        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            AGG_REPO_COUNT=$((AGG_REPO_COUNT + 1))
            score_one_repo "$r"
        done <<< "$repo_list_tmp"
        echo
    else
        # aggregate-only: still iterate but suppress per-repo output by redirecting
        # the printf inside score_one_repo. Cheaper: just count + sum directly.
        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            AGG_REPO_COUNT=$((AGG_REPO_COUNT + 1))
            ships_q=$(gh pr list -R "$r" --state merged --search "merged:>=$wk" --json number --jq 'length' 2>/dev/null)
            ships_q="${ships_q:-0}"
            AGG_SHIPS_WK=$((AGG_SHIPS_WK + ships_q))
            if [[ "$ships_q" -gt 0 ]]; then
                AGG_REPOS_SHIPPED_WK=$((AGG_REPOS_SHIPPED_WK + 1))
            fi
            if command -v sqlite3 >/dev/null 2>&1 && [[ -f .chump/state.db ]]; then
                tagged_q=$(sqlite3 .chump/state.db \
                    "SELECT COUNT(*) FROM gaps WHERE skills_required LIKE '%external_repo:${r}%' AND status='open';" \
                    2>/dev/null || echo 0)
                AGG_TAGGED=$((AGG_TAGGED + tagged_q))
            fi
        done <<< "$repo_list_tmp"
    fi

    echo "═══ AGGREGATE (across $AGG_REPO_COUNT tracked repos) ═══"
    if [[ "$AGG_REPO_COUNT" -gt 0 ]]; then
        pct=$(( AGG_REPOS_SHIPPED_WK * 100 / AGG_REPO_COUNT ))
    else
        pct=0
    fi
    echo "  ① mission ratio (repo-coverage): $AGG_REPOS_SHIPPED_WK of $AGG_REPO_COUNT shipped this week (${pct}%)"
    echo "  ② total ships across fleet (7d):  $AGG_SHIPS_WK"
    echo "  ③ open gaps with external_repo: tag: $AGG_TAGGED"
    echo

    echo "═══ VERDICT ═══"
    if [[ "$AGG_REPOS_SHIPPED_WK" -gt 0 && "$AGG_TAGGED" -gt 0 ]]; then
        echo "  🟢 MISSION ACTIVE — $AGG_REPOS_SHIPPED_WK repo(s) shipping, $AGG_TAGGED open routable gaps. Watch BEAST for zero-touch."
        exit 0
    elif [[ "$AGG_REPOS_SHIPPED_WK" -gt 0 ]]; then
        echo "  🟡 SHIPPING-BUT-UNROUTED — repos active, but $AGG_TAGGED gaps tagged for routing. Backfill external_repo: tags (MISSION-041)."
        exit 1
    else
        echo "  🔴 NO REPO ACTIVITY — no tracked repo merged a PR this week. The mission isn't moving."
        exit 1
    fi
fi

# ── ① THE BINARY: zero-touch BEAST ship this week ───────────────────────────
beast=$(gh pr list -R "$BEAST" --state merged --search "merged:>=$wk" --json number --jq 'length' 2>/dev/null)
echo "① THE BINARY — zero-human-touch PR merged in $BEAST this week?"
if [ -z "$beast" ] || [ "$beast" = "0" ]; then
  echo "     ❌ NO  (BEAST merges last 7d: ${beast:-0})  ← the mission is NOT yet achieved"
  beast=0
else
  echo "     ✅ YES — $beast BEAST merge(s) last 7d  (verify zero-touch + repeatable until instrumented)"
fi
echo

# ── ② Mission-ship ratio (24h) ──────────────────────────────────────────────
total=0; mission=0
while IFS= read -r t; do
  [ -z "$t" ] && continue
  total=$((total+1))
  gid=$(printf '%s' "$t" | grep -oE '[A-Z]+-[0-9]+' | head -1)
  [ -z "$gid" ] && continue
  case "$gid" in MISSION-*) mission=$((mission+1)); continue;; esac
  if chump gap show "$gid" --json 2>/dev/null \
       | grep -qiE "\"domain\":[[:space:]]*\"MISSION\"|$ACTIVE_MISSION|\"outcome_id\":[[:space:]]*\"[^\"]"; then
    mission=$((mission+1))
  fi
done < <(gh pr list --state merged --search "merged:>=$day" --json title --jq '.[].title' 2>/dev/null)
ratio="n/a"; [ "$total" -gt 0 ] && ratio="$mission/$total"
echo "② Mission-ship ratio (24h): $ratio   (target ≥ 2/3 — mission-linked merges ÷ total)"
echo

# ── ③ Deploy-lag (Goal 1 / MISSION-012 proxy) ───────────────────────────────
bin="$(command -v chump 2>/dev/null || echo /opt/homebrew/bin/chump)"
binep=$(stat -f %m "$bin" 2>/dev/null || stat -c %Y "$bin" 2>/dev/null || echo 0)
binbuilt=$(date -u -r "$binep" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$binep" +%Y-%m-%dT%H:%MZ 2>/dev/null || echo '?')
# Structural signal: do merges auto-deploy? Tied to MISSION-012's status, NOT a fuzzy
# mtime diff (main commits constantly, so binary-mtime < latest-commit is almost always
# true and meaningless). The real question is whether an auto-deploy path exists at all.
autodeploy=0
chump gap show MISSION-012 --json 2>/dev/null | grep -qiE '"status":[[:space:]]*"(done|closed|shipped)"' && autodeploy=1
echo "③ Deploy — do merged fixes reach the running binary automatically?  (binary built $binbuilt)"
if [ "$autodeploy" -eq 1 ]; then
  echo "     ✅ auto-deploy in place (MISSION-012 done)"
  stale=0
else
  echo "     ❌ NO auto-deploy (MISSION-012 open) — merges are inert until a manual rebuild. THE MULTIPLIER."
  stale=1
fi
echo

# ── ④ Fleet liveness ────────────────────────────────────────────────────────
lm=$(gh pr list --state merged --limit 1 --json mergedAt --jq '.[0].mergedAt' 2>/dev/null)
lmep=$(iso_to_epoch "$lm"); agem=$(( (now - lmep) / 60 ))
ships=$(gh pr list --state merged --search "merged:>=$day" --json number --jq 'length' 2>/dev/null)
echo "④ Fleet liveness: last merge ${agem}m ago | merges last 24h: ${ships:-?}"
echo

# ── Verdict ─────────────────────────────────────────────────────────────────
echo "═══ VERDICT ═══"
rc=0
need=$(( (total + 2) / 3 ))   # ceil(total*2/3) lower bound for "mission-weighted"
if [ "$beast" -gt 0 ]; then
  echo "  🟢 HANDS-OFF territory — BEAST is shipping. Verify zero-touch + repeatability, then dial autonomy up."
elif [ "$agem" -gt 180 ] && [ "$lmep" -gt 0 ]; then
  echo "  🔴 STALLED — no merge in ${agem}m. Unblock the queue before anything else."; rc=1
elif [ "$stale" -eq 1 ]; then
  echo "  🟠 DRIFTING — fleet ships but fixes don't DEPLOY (MISSION-012). The mission is inert until self-deploy lands."; rc=1
elif [ "$total" -gt 0 ] && [ "$mission" -lt "$need" ]; then
  echo "  🟠 DRIFTING — work-mix is mostly self-maintenance ($ratio mission). Refill the backlog with mission gaps."; rc=1
else
  echo "  🟡 ON-TRACK — mission-weighted + deploying, but BEAST not yet shipping. Push the onboard→BEAST path."
fi
echo "  Next lever: MISSION-012 (self-deploy) — until merges go live, the scoreboard can't move."
exit "$rc"
