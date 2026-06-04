#!/usr/bin/env bash
# mission-scoreboard.sh (MISSION-014) — READ-ONLY scoreboard for the operative
# mission (MISSION-010). The one honest measure of whether Chump is moving
# toward zero-human-touch software delivery. Pairs with docs/MISSION.md.
#
# No state mutation. Safe to run anytime. Exit 0 = HANDS-OFF/ON-TRACK,
# exit 1 = DRIFTING/STALLED (so a conductor loop can gate on $?).
#
# Follow-up: port to `chump kpi mission` (Rust) once metrics stabilize.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" 2>/dev/null || true

BEAST="repairman29/BEAST-MODE"
ACTIVE_MISSION="$(cat "$HOME/.chump/ACTIVE_MISSION" 2>/dev/null || echo MISSION-010)"
now=$(date -u +%s)

# Portable date helpers (BSD/macOS first, GNU fallback)
days_ago() { date -u -v-"$1"d +%Y-%m-%d 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null; }
iso_to_epoch() { date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || echo 0; }

wk="$(days_ago 7)"; day="$(days_ago 1)"

echo "═══ CHUMP MISSION SCOREBOARD ═══  $(date -u +%Y-%m-%dT%H:%MZ)"
echo "Mission: $ACTIVE_MISSION — zero-human-touch software delivery; proof: $BEAST 0→1"
echo "(read-only; see docs/MISSION.md)"
echo

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
