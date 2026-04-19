#!/usr/bin/env bash
# war-room.sh — full situational awareness for all active agents.
#
# Run this at session start (after git fetch, before picking a gap) to see
# exactly what every other agent is doing, what files they own, what PRs are
# in flight, and what conflicts exist.
#
# Usage:
#   scripts/war-room.sh           # full view
#   scripts/war-room.sh --json    # machine-readable JSON
#   scripts/war-room.sh --short   # one-line-per-agent summary
#
# The output is designed to be read by both humans and agents in their context.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
SCRIPTS="$REPO_ROOT/scripts"
NOW=$(date +%s)

MODE="full"
[[ "${1:-}" == "--json" ]]  && MODE="json"
[[ "${1:-}" == "--short" ]] && MODE="short"

# ── Helpers ───────────────────────────────────────────────────────────────────
bold()   { printf '\033[1m%s\033[0m' "$*"; }
cyan()   { printf '\033[0;36m%s\033[0m' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m' "$*"; }
red()    { printf '\033[0;31m%s\033[0m' "$*"; }
green()  { printf '\033[0;32m%s\033[0m' "$*"; }
dim()    { printf '\033[2m%s\033[0m' "$*"; }

age_str() {
    local secs=$1
    if   (( secs < 60  )); then echo "${secs}s"
    elif (( secs < 3600 )); then echo "$(( secs/60 ))m"
    else echo "$(( secs/3600 ))h$(( (secs%3600)/60 ))m"
    fi
}

# ── 1. Active leases ──────────────────────────────────────────────────────────
declare -A AGENT_GAP AGENT_FILES AGENT_AGE AGENT_WT

for f in "$LOCK_DIR"/*.json 2>/dev/null; do
    [[ -f "$f" ]] || continue
    sess=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('session_id','?'))" 2>/dev/null || true)
    gap=$(python3  -c "import json; d=json.load(open('$f')); print(d.get('gap_id',''))" 2>/dev/null || true)
    files=$(python3 -c "import json; d=json.load(open('$f')); print(','.join(d.get('files',[])))" 2>/dev/null || true)
    wt=$(python3    -c "import json; d=json.load(open('$f')); print(d.get('worktree',''))" 2>/dev/null || true)
    hb=$(python3    -c "import json; d=json.load(open('$f')); print(d.get('heartbeat',d.get('created_at',0)))" 2>/dev/null || 0)
    [[ -n "$sess" ]] || continue
    AGENT_GAP["$sess"]="$gap"
    AGENT_FILES["$sess"]="$files"
    AGENT_WT["$sess"]="$wt"
    AGENT_AGE["$sess"]=$(( NOW - hb ))
done

# ── 2. Recent INTENT events (last 5 min) ─────────────────────────────────────
declare -A INTENT_GAP INTENT_FILES INTENT_TS

if [[ -f "$LOCK_DIR/ambient.jsonl" ]]; then
    CUTOFF=$(( NOW - 300 ))
    while IFS= read -r line; do
        event=$(python3 -c "import json; d=json.loads('$line'.replace(\"'\",\"'\\\"'\\\"'\")); print(d.get('event',''))" 2>/dev/null || true)
        [[ "$event" == "INTENT" ]] || continue
        sess=$(python3 -c "import json; d=json.loads('''$line'''); print(d.get('session',''))" 2>/dev/null || true)
        gap=$(python3  -c "import json; d=json.loads('''$line'''); print(d.get('gap',''))" 2>/dev/null || true)
        files=$(python3 -c "import json; d=json.loads('''$line'''); print(d.get('files',''))" 2>/dev/null || true)
        ts_str=$(python3 -c "import json; d=json.loads('''$line'''); print(d.get('ts',''))" 2>/dev/null || true)
        ts_epoch=$(python3 -c "import datetime; print(int(datetime.datetime.fromisoformat('${ts_str%Z}'.replace('T',' ')).timestamp()))" 2>/dev/null || 0)
        (( ts_epoch > CUTOFF )) || continue
        INTENT_GAP["$sess"]="$gap"
        INTENT_FILES["$sess"]="$files"
        INTENT_TS["$sess"]=$(( NOW - ts_epoch ))
    done < <(tail -200 "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true)
fi

# ── 3. Open gaps ──────────────────────────────────────────────────────────────
OPEN_GAPS=$(python3 -c "
import re, sys
with open('$REPO_ROOT/docs/gaps.yaml') as f:
    content = f.read()
blocks = re.split(r'\n  - id: ', content)
for b in blocks:
    if 'status: open' not in b: continue
    gid = b.split('\n')[0].strip()
    title = re.search(r'title:\s*[\"\']*([^\"\'\\n]+)', b)
    prio  = re.search(r'priority:\s*(\S+)', b)
    effort= re.search(r'effort:\s*(\S+)', b)
    domain= re.search(r'domain:\s*(\S+)', b)
    deps  = re.search(r'depends_on:\s*\[([^\]]*)\]', b)
    print('|'.join([
        gid,
        title.group(1) if title else '?',
        prio.group(1)  if prio  else '?',
        effort.group(1)if effort else '?',
        domain.group(1)if domain else '?',
        deps.group(1)  if deps   else '',
    ]))
" 2>/dev/null || true)

# ── 4. Open PRs with file scopes ─────────────────────────────────────────────
PR_DATA=$(gh pr list --state open --json number,title,headRefName,files \
    --jq '.[] | "\(.number)|\(.title[:45])|\(.headRefName)|" + ([.files[].path] | join(","))' \
    2>/dev/null | head -30 || true)

# ── 5. File conflict detection ────────────────────────────────────────────────
# Domain → likely files heuristic (also used by musher.sh)
gap_files() {
    local gap="${1:-}"
    case "$gap" in
        COG-*)   echo "src/reflection.rs,src/reflection_db.rs,src/consciousness_tests.rs,src/neuromod" ;;
        EVAL-*)  echo "scripts/ab-harness/,tests/fixtures/" ;;
        COMP-*)  echo "src/browser_tool.rs,src/acp_server.rs,src/acp.rs,desktop/" ;;
        INFRA-*) echo ".github/workflows/,scripts/" ;;
        AGT-*)   echo "src/agent_loop/,src/autonomy_loop.rs,src/orchestrator" ;;
        MEM-*)   echo "src/memory_db.rs,src/memory_tool.rs,src/memory_graph.rs" ;;
        AUTO-*)  echo "src/tool_middleware.rs,scripts/" ;;
        *)       echo "" ;;
    esac
}

# ── Render ────────────────────────────────────────────────────────────────────

if [[ "$MODE" == "short" ]]; then
    echo "WAR ROOM $(date '+%H:%M:%S')"
    for sess in "${!AGENT_GAP[@]}"; do
        gap="${AGENT_GAP[$sess]}"
        age=$(age_str "${AGENT_AGE[$sess]}")
        echo "  ${sess:0:16}  gap=${gap:-none}  age=$age"
    done
    [[ ${#AGENT_GAP[@]} -eq 0 ]] && echo "  (no active agents)"
    exit 0
fi

if [[ "$MODE" == "json" ]]; then
    python3 -c "
import json, time
agents = {}
$(for sess in "${!AGENT_GAP[@]}"; do
    echo "agents['${sess}'] = {'gap': '${AGENT_GAP[$sess]}', 'age_s': ${AGENT_AGE[$sess]}, 'worktree': '${AGENT_WT[$sess]:-}', 'files': '${AGENT_FILES[$sess]:-}'}"
done)
print(json.dumps({'ts': time.time(), 'agents': agents}, indent=2))
"
    exit 0
fi

# ── Full mode ─────────────────────────────────────────────────────────────────
echo ""
bold "═══════════════════════════════════════════════════════"
bold " WAR ROOM  $(date '+%Y-%m-%d %H:%M:%S')"
bold "═══════════════════════════════════════════════════════"

# Active agents
echo ""
bold "ACTIVE AGENTS"
if [[ ${#AGENT_GAP[@]} -eq 0 ]]; then
    dim "  (no active lease files — no agents currently mid-work)"
else
    for sess in "${!AGENT_GAP[@]}"; do
        gap="${AGENT_GAP[$sess]}"
        age=$(age_str "${AGENT_AGE[$sess]}")
        wt="${AGENT_WT[$sess]:-?}"
        files="${AGENT_FILES[$sess]:-}"
        stale=""
        (( AGENT_AGE[$sess] > 600 )) && stale=" $(yellow '⚠ STALE')"
        printf "  $(cyan "${sess:0:20}")  gap=$(bold "$gap")  age=$age  wt=$wt$stale\n"
        [[ -n "$files" ]] && printf "    files: $(dim "$files")\n"
    done
fi

# Recent intents
echo ""
bold "RECENT INTENTS (last 5 min)"
if [[ ${#INTENT_GAP[@]} -eq 0 ]]; then
    dim "  (none)"
else
    for sess in "${!INTENT_GAP[@]}"; do
        age=$(age_str "${INTENT_TS[$sess]}")
        printf "  $(cyan "${sess:0:20}")  considering $(bold "${INTENT_GAP[$sess]}")  ${age} ago\n"
        files="${INTENT_FILES[$sess]:-}"
        [[ -n "$files" ]] && printf "    likely files: $(dim "$files")\n"
    done
fi

# Open gaps
echo ""
bold "OPEN GAPS"
while IFS='|' read -r gid title prio effort domain deps; do
    [[ -n "$gid" ]] || continue
    claimed=""
    for sess in "${!AGENT_GAP[@]}"; do
        [[ "${AGENT_GAP[$sess]}" == "$gid" ]] && claimed=" $(yellow '← CLAIMED')"
    done
    for sess in "${!INTENT_GAP[@]}"; do
        [[ "${INTENT_GAP[$sess]}" == "$gid" ]] && claimed=" $(yellow '← INTENT')"
    done
    dep_str=""
    [[ -n "$deps" ]] && dep_str=" $(dim "deps:[$deps]")"
    printf "  [$(bold "$prio")] $(cyan "$gid")  $domain  $effort$claimed$dep_str\n"
    printf "    $(dim "$title")\n"
done <<< "$OPEN_GAPS"

# Open PRs
echo ""
bold "OPEN PRs"
if [[ -z "$PR_DATA" ]]; then
    dim "  (none / gh not available)"
else
    while IFS='|' read -r num title branch files; do
        printf "  #$num  $(cyan "$branch")\n"
        printf "    $(dim "$title")\n"
        [[ -n "$files" ]] && printf "    files: $(dim "${files:0:100}")\n"
    done <<< "$PR_DATA"
fi

# Conflicts
echo ""
bold "CONFLICT SCAN"
conflicts_found=false
# Check open gaps vs open PRs for file overlap
while IFS='|' read -r gid _ _ _ _ _; do
    [[ -n "$gid" ]] || continue
    gap_likely=$(gap_files "$gid")
    [[ -n "$gap_likely" ]] || continue
    IFS=',' read -ra gfiles <<< "$gap_likely"
    while IFS='|' read -r prnum _ prbranch prfiles; do
        [[ -n "$prfiles" ]] || continue
        for gf in "${gfiles[@]}"; do
            prefix="${gf%%\*}"  # strip trailing wildcard
            if echo "$prfiles" | grep -q "$prefix"; then
                printf "  $(red '⚠') Gap $(bold "$gid") and PR #$prnum both touch $(yellow "$prefix")\n"
                printf "    $(dim "Coordinate or wait for PR #$prnum to merge first")\n"
                conflicts_found=true
            fi
        done
    done <<< "$PR_DATA"
done <<< "$OPEN_GAPS"
$conflicts_found || printf "  $(green '✓') No file-scope conflicts detected\n"

# Recommendation
echo ""
bold "RECOMMENDATION"
"$SCRIPTS/musher.sh" --pick 2>/dev/null || dim "  (musher.sh not yet available)"

echo ""
