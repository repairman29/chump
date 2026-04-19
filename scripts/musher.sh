#!/usr/bin/env bash
# musher.sh — The Chump multi-agent dispatcher.
#
# Instead of every agent independently reading gaps.yaml and colliding, they
# query musher to get a conflict-free work assignment. Musher sees all state
# (active leases, recent INTENTs, open PRs, gap dependencies) and routes each
# agent to a different slice of the work.
#
# Usage:
#   scripts/musher.sh --pick                    # recommend one gap for THIS session
#   scripts/musher.sh --check <GAP-ID>          # full conflict analysis for a gap
#   scripts/musher.sh --assign <N>              # output N non-overlapping assignments
#   scripts/musher.sh --status                  # show dispatch table (no recommendation)
#   scripts/musher.sh --why <GAP-ID>            # explain why a gap is or isn't available
#
# All modes exit 0 on success, 1 if no gaps are assignable (e.g. everything claimed).
#
# Integration points:
#   - war-room.sh   calls --pick at the bottom to append a recommendation
#   - gap-claim.sh  should call --check before writing the lease (see below)
#   - gap-preflight.sh already handles done/lease checks; musher adds PR-scope layer
#
# File-scope conflict detection uses domain heuristics (see gap_files() below).
# These are intentionally conservative — a false positive delays an agent by one
# gap; a false negative causes a stomp. When in doubt, flag the conflict.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
GAPS_YAML="$REPO_ROOT/docs/gaps.yaml"
NOW=$(date +%s)

# ── Resolve session ID ────────────────────────────────────────────────────────
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]]; then
    _WT_CACHE="$LOCK_DIR/.wt-session-id"
    [[ -f "$_WT_CACHE" ]] && SESSION_ID="$(cat "$_WT_CACHE" 2>/dev/null || true)"
fi
if [[ -z "$SESSION_ID" && -f "$HOME/.chump/session_id" ]]; then
    SESSION_ID="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
fi
SESSION_ID="${SESSION_ID:-unknown-$$}"

# ── Helpers ───────────────────────────────────────────────────────────────────
bold()   { printf '\033[1m%s\033[0m' "$*"; }
cyan()   { printf '\033[0;36m%s\033[0m' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m' "$*"; }
red()    { printf '\033[0;31m%s\033[0m' "$*"; }
green()  { printf '\033[0;32m%s\033[0m' "$*"; }
dim()    { printf '\033[2m%s\033[0m' "$*"; }

# ── Domain → file-scope heuristic ────────────────────────────────────────────
# Used to detect conflicts between open gap domains and open PR file lists.
# When a gap's likely files overlap with files in an open PR, starting that
# gap risks a merge conflict or double-implementation.
# Conservative: returns a superset of files the domain likely touches.
gap_files() {
    local gap="${1:-}"
    case "$gap" in
        COG-*)   echo "src/reflection.rs,src/reflection_db.rs,src/consciousness_tests.rs,src/neuromod" ;;
        EVAL-*)  echo "scripts/ab-harness/,tests/fixtures/,docs/CONSCIOUSNESS_AB_RESULTS.md" ;;
        COMP-*)  echo "src/browser_tool.rs,src/acp_server.rs,src/acp.rs,desktop/" ;;
        INFRA-*) echo ".github/workflows/,scripts/" ;;
        AGT-*)   echo "src/agent_loop/,src/autonomy_loop.rs,src/orchestrator" ;;
        MEM-*)   echo "src/memory_db.rs,src/memory_tool.rs,src/memory_graph.rs" ;;
        AUTO-*)  echo "src/tool_middleware.rs,scripts/" ;;
        DOC-*)   echo "docs/,CLAUDE.md,AGENTS.md" ;;
        *)       echo "" ;;
    esac
}

# ── 1. Load open gaps ─────────────────────────────────────────────────────────
# Returns: GAP_IDS array, GAP_TITLE[id], GAP_PRIO[id], GAP_EFFORT[id],
#          GAP_DOMAIN[id], GAP_DEPS[id]
declare -a GAP_IDS=()
declare -A GAP_TITLE GAP_PRIO GAP_EFFORT GAP_DOMAIN GAP_DEPS

if [[ -f "$GAPS_YAML" ]]; then
    while IFS='|' read -r gid title prio effort domain deps; do
        [[ -n "$gid" ]] || continue
        GAP_IDS+=("$gid")
        GAP_TITLE["$gid"]="$title"
        GAP_PRIO["$gid"]="$prio"
        GAP_EFFORT["$gid"]="$effort"
        GAP_DOMAIN["$gid"]="$domain"
        GAP_DEPS["$gid"]="${deps// /}"  # strip whitespace
    done < <(python3 -c "
import re
with open('$GAPS_YAML') as f:
    content = f.read()
blocks = re.split(r'\n  - id: ', content)
for b in blocks:
    if 'status: open' not in b: continue
    gid   = b.split('\n')[0].strip()
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
fi

# ── Priority sort order ───────────────────────────────────────────────────────
prio_rank() {
    case "${1:-}" in
        critical|p0) echo 0 ;;
        high|p1)     echo 1 ;;
        medium|p2|M) echo 2 ;;
        low|p3|S)    echo 3 ;;
        *)           echo 9 ;;
    esac
}

# Sort GAP_IDS by priority
sorted_gaps() {
    local -a pairs=()
    for gid in "${GAP_IDS[@]}"; do
        pairs+=("$(prio_rank "${GAP_PRIO[$gid]}")  $gid")
    done
    printf '%s\n' "${pairs[@]}" | sort -n | awk '{print $2}'
}

# ── 2. Load active leases ─────────────────────────────────────────────────────
declare -A LEASE_GAP LEASE_SESSION LEASE_FILES LEASE_AGE

for f in "$LOCK_DIR"/*.json 2>/dev/null; do
    [[ -f "$f" ]] || continue
    data=$(python3 - "$f" "$NOW" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
path, now_str = sys.argv[1], sys.argv[2]
now = int(now_str)
try:
    with open(path) as fp:
        d = json.load(fp)
except Exception:
    sys.exit(0)
# Skip stale leases
try:
    hb = int(d.get("heartbeat", d.get("heartbeat_at", d.get("created_at", 0))))
    if (now - hb) > 900:
        sys.exit(0)
except Exception:
    pass
sess = d.get("session_id", "")
gap  = d.get("gap_id", "")
files= ",".join(d.get("files", []))
hb2  = d.get("heartbeat", d.get("heartbeat_at", d.get("created_at", 0)))
try:
    age = now - int(hb2)
except Exception:
    age = 0
print(f"{sess}|{gap}|{files}|{age}")
PYEOF
) || true
    [[ -n "$data" ]] || continue
    IFS='|' read -r sess gap files age <<< "$data"
    [[ -n "$sess" ]] || continue
    LEASE_SESSION["$sess"]="$sess"
    LEASE_GAP["$sess"]="$gap"
    LEASE_FILES["$sess"]="$files"
    LEASE_AGE["$sess"]="$age"
done

# ── 3. Load recent INTENTs (last 120 seconds) ─────────────────────────────────
declare -A INTENT_GAP INTENT_FILES INTENT_AGE

if [[ -f "$LOCK_DIR/ambient.jsonl" ]]; then
    CUTOFF=$(( NOW - 120 ))
    while IFS= read -r line; do
        parsed=$(python3 - "$line" "$NOW" "$CUTOFF" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
line, now_str, cutoff_str = sys.argv[1], sys.argv[2], sys.argv[3]
now = int(now_str); cutoff = int(cutoff_str)
try:
    d = json.loads(line)
except Exception:
    sys.exit(0)
if d.get("event") != "INTENT":
    sys.exit(0)
ts_str = d.get("ts", "")
try:
    ts = int(datetime.fromisoformat(ts_str.replace("Z","+00:00")).timestamp())
except Exception:
    sys.exit(0)
if ts < cutoff:
    sys.exit(0)
sess  = d.get("session", "")
gap   = d.get("gap", "")
files = d.get("files", "")
age   = now - ts
print(f"{sess}|{gap}|{files}|{age}")
PYEOF
) || true
        [[ -n "$parsed" ]] || continue
        IFS='|' read -r sess gap files age <<< "$parsed"
        [[ -n "$sess" && -n "$gap" ]] || continue
        INTENT_GAP["$sess"]="$gap"
        INTENT_FILES["$sess"]="$files"
        INTENT_AGE["$sess"]="$age"
    done < <(tail -300 "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true)
fi

# ── 4. Load open PRs with file scopes ─────────────────────────────────────────
declare -A PR_FILES PR_BRANCH
declare -a PR_NUMS=()

while IFS='|' read -r num title branch files; do
    [[ -n "$num" ]] || continue
    PR_NUMS+=("$num")
    PR_FILES["$num"]="$files"
    PR_BRANCH["$num"]="$branch"
done < <(gh pr list --state open --json number,title,headRefName,files \
    --jq '.[] | "\(.number)|\(.title[:45])|\(.headRefName)|" + ([.files[].path] | join(","))' \
    2>/dev/null | head -30 || true)

# ── Conflict detection ────────────────────────────────────────────────────────
# Returns "pr:<num>" or "lease:<session>" or "intent:<session>" or ""
# for the first conflict found against a gap.
first_conflict() {
    local gid="$1"
    local likely
    likely="$(gap_files "$gid")"
    [[ -n "$likely" ]] || { echo ""; return; }

    IFS=',' read -ra gfiles <<< "$likely"

    # Check open PRs
    for prnum in "${PR_NUMS[@]}"; do
        local prfiles="${PR_FILES[$prnum]:-}"
        [[ -n "$prfiles" ]] || continue
        for gf in "${gfiles[@]}"; do
            prefix="${gf%%\**}"  # strip trailing wildcard
            if echo "$prfiles" | grep -q "$prefix"; then
                echo "pr:$prnum"
                return
            fi
        done
    done

    # Check active leases (different session)
    for sess in "${!LEASE_GAP[@]}"; do
        [[ "${LEASE_SESSION[$sess]}" == "$SESSION_ID" ]] && continue
        [[ "${LEASE_GAP[$sess]}" == "$gid" ]] && continue  # same gap = already caught by done-check
        local lease_domain
        lease_domain="$(gap_files "${LEASE_GAP[$sess]:-}")"
        [[ -n "$lease_domain" ]] || continue
        IFS=',' read -ra lfiles <<< "$lease_domain"
        for gf in "${gfiles[@]}"; do
            pfx="${gf%%\**}"
            for lf in "${lfiles[@]}"; do
                lpfx="${lf%%\**}"
                if [[ "$pfx" == "$lpfx"* ]] || [[ "$lpfx" == "$pfx"* ]]; then
                    echo "lease:$sess"
                    return
                fi
            done
        done
    done

    echo ""
}

# Returns "true" if a gap has unclaimed dependencies (a dep still open and not done).
has_unmet_deps() {
    local gid="$1"
    local deps="${GAP_DEPS[$gid]:-}"
    [[ -n "$deps" ]] || { echo "false"; return; }

    # Check if any dep is NOT done on current gaps list (open = unmet).
    while IFS=',' read -ra dep_arr; do
        for dep in "${dep_arr[@]}"; do
            dep="$(echo "$dep" | tr -d ' ')"
            [[ -n "$dep" ]] || continue
            for open_gid in "${GAP_IDS[@]}"; do
                if [[ "$open_gid" == "$dep" ]]; then
                    echo "true"
                    return
                fi
            done
        done
    done <<< "$deps"
    echo "false"
}

# ── Availability classifier ───────────────────────────────────────────────────
# Returns: "available", "claimed:<sess>", "intended:<sess>", "conflict:<detail>",
#          "deps:<dep-id>", or "effort-xl"
classify_gap() {
    local gid="$1"

    # XL effort — never auto-assign
    [[ "${GAP_EFFORT[$gid]:-}" == "XL" ]] && { echo "effort-xl"; return; }

    # Unmet dependencies
    local has_deps
    has_deps="$(has_unmet_deps "$gid")"
    if [[ "$has_deps" == "true" ]]; then
        echo "deps:${GAP_DEPS[$gid]}"
        return
    fi

    # Active lease by a different session
    for sess in "${!LEASE_GAP[@]}"; do
        if [[ "${LEASE_GAP[$sess]}" == "$gid" ]]; then
            if [[ "${LEASE_SESSION[$sess]}" == "$SESSION_ID" ]]; then
                echo "available"  # This session already holds it — still available to us
                return
            fi
            echo "claimed:${LEASE_SESSION[$sess]}"
            return
        fi
    done

    # Recent INTENT by a different session (last 120s)
    for sess in "${!INTENT_GAP[@]}"; do
        if [[ "${INTENT_GAP[$sess]}" == "$gid" && "$sess" != "$SESSION_ID" ]]; then
            echo "intended:$sess"
            return
        fi
    done

    # File-scope conflict with open PR
    local conflict
    conflict="$(first_conflict "$gid")"
    [[ -n "$conflict" ]] && { echo "conflict:$conflict"; return; }

    echo "available"
}

# ── Mode dispatch ─────────────────────────────────────────────────────────────
MODE="${1:---pick}"
shift || true

case "$MODE" in

# ──────────────────────────────────────────────────────────────────────────────
--pick)
    # Print the single best available gap for this session.
    BEST=""
    while IFS= read -r gid; do
        [[ -n "$gid" ]] || continue
        STATUS="$(classify_gap "$gid")"
        if [[ "$STATUS" == "available" ]]; then
            BEST="$gid"
            break
        fi
    done < <(sorted_gaps)

    if [[ -z "$BEST" ]]; then
        printf '  %s\n' "$(red 'No available gaps found — everything claimed, conflicted, or done.')"
        exit 1
    fi

    printf '  %s  %s  %s  %s\n' \
        "$(green '→ PICK')" \
        "$(bold "$BEST")" \
        "(${GAP_PRIO[$BEST]:-?} priority, ${GAP_EFFORT[$BEST]:-?} effort)" \
        "$(dim "${GAP_TITLE[$BEST]:-}")"
    printf '  %s\n' "$(dim "Run: scripts/gap-claim.sh $BEST")"
    ;;

# ──────────────────────────────────────────────────────────────────────────────
--check)
    TARGET="${1:-}"
    [[ -n "$TARGET" ]] || { echo "Usage: $0 --check <GAP-ID>" >&2; exit 1; }

    echo ""
    bold "MUSHER CHECK: $TARGET"
    echo ""

    STATUS="$(classify_gap "$TARGET")"
    case "$STATUS" in
        available)
            printf '  %s\n' "$(green '✓ Available — no conflicts detected.')"
            ;;
        claimed:*)
            HOLDER="${STATUS#claimed:}"
            printf '  %s  claimed by session: %s\n' "$(red '✗ BLOCKED')" "$(yellow "$HOLDER")"
            ;;
        intended:*)
            SESS="${STATUS#intended:}"
            printf '  %s  session %s announced INTENT for this gap in the last 120s\n' \
                "$(yellow '⚠ INTENT')" "$(cyan "$SESS")"
            printf '  %s\n' "$(dim 'Wait 30s and re-check, or coordinate with that session.')"
            ;;
        conflict:pr:*)
            PR="${STATUS#conflict:pr:}"
            printf '  %s  PR #%s touches the same file domains\n' "$(yellow '⚠ CONFLICT')" "$PR"
            printf '  %s\n' "$(dim "Merge or coordinate with PR #$PR before starting.")"
            ;;
        conflict:lease:*)
            SESS="${STATUS#conflict:lease:}"
            printf '  %s  session %s holds a lease on overlapping files\n' "$(yellow '⚠ CONFLICT')" "$SESS"
            ;;
        deps:*)
            DEPS="${STATUS#deps:}"
            printf '  %s  unmet dependencies: %s\n' "$(yellow '⚠ BLOCKED')" "$DEPS"
            printf '  %s\n' "$(dim 'Ship the dependency gaps first.')"
            ;;
        effort-xl)
            printf '  %s  XL effort gap — do not auto-assign (manual decision required)\n' "$(yellow '⚠ XL')"
            ;;
    esac

    # Extra: show PR conflicts explicitly
    likely="$(gap_files "$TARGET")"
    if [[ -n "$likely" ]]; then
        echo ""
        printf '  %s %s\n' "$(dim 'File domains:')" "$(dim "$likely")"
        for prnum in "${PR_NUMS[@]}"; do
            prfiles="${PR_FILES[$prnum]:-}"
            IFS=',' read -ra gfiles <<< "$likely"
            for gf in "${gfiles[@]}"; do
                pfx="${gf%%\**}"
                if echo "$prfiles" | grep -q "$pfx"; then
                    printf '  %s PR #%s (%s) touches %s\n' \
                        "$(yellow '  ↳')" "$prnum" "${PR_BRANCH[$prnum]:-?}" "$pfx"
                fi
            done
        done
    fi
    ;;

# ──────────────────────────────────────────────────────────────────────────────
--assign)
    N="${1:-1}"
    echo ""
    bold "MUSHER ASSIGN: $N slot(s)"
    echo ""

    ASSIGNED=0
    declare -A USED_DOMAINS=()

    while IFS= read -r gid; do
        [[ -n "$gid" ]] || continue
        [[ $ASSIGNED -lt $N ]] || break

        STATUS="$(classify_gap "$gid")"
        [[ "$STATUS" == "available" ]] || continue

        # Also skip if this domain was already assigned in this batch
        domain="${GAP_DOMAIN[$gid]:-}"
        [[ -n "${USED_DOMAINS[$domain]+x}" ]] && continue
        USED_DOMAINS["$domain"]=1

        printf '  %s  [slot %s] %s  %s  %s\n' \
            "$(green '→')" "$(( ASSIGNED + 1 ))" \
            "$(bold "$gid")" \
            "(${GAP_PRIO[$gid]:-?} / ${GAP_EFFORT[$gid]:-?})" \
            "$(dim "${GAP_TITLE[$gid]:-}")"
        (( ASSIGNED++ )) || true
    done < <(sorted_gaps)

    if [[ $ASSIGNED -eq 0 ]]; then
        printf '  %s\n' "$(red 'No available gaps to assign.')"
        exit 1
    fi
    ;;

# ──────────────────────────────────────────────────────────────────────────────
--status)
    echo ""
    bold "MUSHER STATUS TABLE"
    printf '  %-12s %-8s %-6s %-12s %s\n' "GAP" "PRIO" "EFFORT" "STATUS" "DETAIL"
    printf '  %s\n' "$(dim '─────────────────────────────────────────────────────────────')"

    while IFS= read -r gid; do
        [[ -n "$gid" ]] || continue
        STATUS="$(classify_gap "$gid")"
        PRIO="${GAP_PRIO[$gid]:-?}"
        EFFORT="${GAP_EFFORT[$gid]:-?}"
        case "$STATUS" in
            available)
                printf '  %-12s %-8s %-6s %s\n' "$gid" "$PRIO" "$EFFORT" "$(green 'available')"
                ;;
            claimed:*)
                printf '  %-12s %-8s %-6s %s  %s\n' "$gid" "$PRIO" "$EFFORT" \
                    "$(yellow 'claimed')" "$(dim "${STATUS#claimed:}")"
                ;;
            intended:*)
                printf '  %-12s %-8s %-6s %s  %s\n' "$gid" "$PRIO" "$EFFORT" \
                    "$(yellow 'intent')" "$(dim "${STATUS#intended:}")"
                ;;
            conflict:*)
                printf '  %-12s %-8s %-6s %s  %s\n' "$gid" "$PRIO" "$EFFORT" \
                    "$(yellow 'conflict')" "$(dim "${STATUS#conflict:}")"
                ;;
            deps:*)
                printf '  %-12s %-8s %-6s %s  %s\n' "$gid" "$PRIO" "$EFFORT" \
                    "$(dim 'blocked')" "$(dim "deps:${STATUS#deps:}")"
                ;;
            effort-xl)
                printf '  %-12s %-8s %-6s %s\n' "$gid" "$PRIO" "$EFFORT" "$(dim 'XL-skip')"
                ;;
        esac
    done < <(sorted_gaps)
    echo ""
    ;;

# ──────────────────────────────────────────────────────────────────────────────
--why)
    TARGET="${1:-}"
    [[ -n "$TARGET" ]] || { echo "Usage: $0 --why <GAP-ID>" >&2; exit 1; }

    STATUS="$(classify_gap "$TARGET")"
    PRIO="${GAP_PRIO[$TARGET]:-?}"
    EFFORT="${GAP_EFFORT[$TARGET]:-?}"
    TITLE="${GAP_TITLE[$TARGET]:-?}"
    DEPS="${GAP_DEPS[$TARGET]:-none}"

    echo ""
    bold "$TARGET — $TITLE"
    printf '  priority=%s  effort=%s  deps=%s\n' "$PRIO" "$EFFORT" "$DEPS"
    printf '  classification: %s\n\n' "$(bold "$STATUS")"

    case "$STATUS" in
        available)
            green "  ✓ This gap is open, unclaimed, and has no file-scope conflicts."
            echo ""
            ;;
        claimed:*)
            echo "  The lease file for session '${STATUS#claimed:}' lists gap_id='$TARGET'."
            echo "  Check: ls .chump-locks/*.json | xargs grep -l '$TARGET'"
            ;;
        intended:*)
            echo "  Session '${STATUS#intended:}' posted an INTENT event for '$TARGET' in the last 120s."
            echo "  Check: tail -50 .chump-locks/ambient.jsonl | grep INTENT"
            ;;
        conflict:pr:*)
            echo "  PR #${STATUS#conflict:pr:} is open and touches the same file domain as $TARGET."
            echo "  Domain files: $(gap_files "$TARGET")"
            ;;
        conflict:lease:*)
            echo "  Session '${STATUS#conflict:lease:}' holds a lease on overlapping file domains."
            echo "  Domain files: $(gap_files "$TARGET")"
            ;;
        deps:*)
            echo "  The following dependency gaps are still open: ${STATUS#deps:}"
            echo "  Ship those first, then re-run --check $TARGET."
            ;;
        effort-xl)
            echo "  This gap is marked XL effort. musher never auto-assigns XL gaps."
            echo "  Pick it manually when you're confident you have the bandwidth."
            ;;
    esac
    ;;

# ──────────────────────────────────────────────────────────────────────────────
*)
    cat >&2 <<'EOF'
Usage: scripts/musher.sh [MODE]

Modes:
  --pick              Recommend the best available gap for this session
  --check <GAP-ID>    Full conflict analysis for a specific gap
  --assign <N>        Output N non-overlapping gap assignments
  --status            Show dispatch table for all open gaps
  --why <GAP-ID>      Explain why a gap is or isn't available

EOF
    exit 1
    ;;
esac
