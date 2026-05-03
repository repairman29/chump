#!/usr/bin/env bash
# ship-audit.sh — INFRA-341: end-to-end pipeline visibility.
#
# Answers the question "is the work I'm doing actually making it to the
# repo?" by walking the 5 gates between "agent edited a file" and "code
# on origin/main", reporting failure modes at each:
#
#   1. Pushed              local commits not on remote
#   2. PR open             commits pushed but no PR opened
#   3. Auto-merge armed    PR open but won't land on its own
#   4. CI green            armed but blocked by failing required check
#   5. Landed              the only ground truth (recent commits on main)
#
# Plus two derived signals:
#   - Stuck PRs: auto-merge armed > 2h, still open (CI fail or queue jam)
#   - Throughput: commits landed in the last N hours (default 12)
#
# Read-only; no mutations. Safe to run anytime.
#
# Origin: surfaced during a "how do we know our work is making it to the
# repo" debugging session that found INFRA-329 (status:open ghost after
# PR #928 landed) and PR #910 stuck (CI fail since 01:33Z) — neither
# would have been visible without walking these gates.
#
# Usage:
#   scripts/dev/ship-audit.sh              # default 12h window
#   scripts/dev/ship-audit.sh --since 24h  # custom window
#   scripts/dev/ship-audit.sh --quiet      # only print FAILURES (silent on healthy)
#
set -euo pipefail

SINCE="12 hours ago"
QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) SINCE="$2"; shift 2 ;;
        --quiet|-q) QUIET=1; shift ;;
        --help|-h)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "ship-audit: unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO"

# Color (only if stdout is a tty).
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; YEL=$'\033[1;33m'; GRN=$'\033[0;32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
    RED=""; YEL=""; GRN=""; DIM=""; OFF=""
fi

# Buffer findings so we can suppress healthy sections under --quiet.
HEADER_PRINTED=0
print_header() {
    if [[ $HEADER_PRINTED -eq 0 ]]; then
        echo "${DIM}=== ship-audit (since: $SINCE) ===${OFF}"
        HEADER_PRINTED=1
    fi
    echo "$1"
}

FAILURES=0
note_failure() { FAILURES=$((FAILURES+1)); }

# ── Gate 1: UNPUSHED COMMITS ────────────────────────────────────────────────
unpushed=""
while IFS= read -r wt; do
    [[ -z "$wt" ]] && continue
    br=$(git -C "$wt" branch --show-current 2>/dev/null) || continue
    [[ -z "$br" ]] && continue
    # Only flag commits ahead of THE SAME REMOTE BRANCH (not main) — those
    # are the actually-orphaned ones. Ahead-of-main is normal during PR life.
    ahead=$(git -C "$wt" rev-list --count "origin/$br..HEAD" 2>/dev/null) || ahead=0
    if [[ "$ahead" -gt 0 ]]; then
        unpushed+="  ${RED}${ahead}${OFF} ahead of origin/${br}  [$(basename "$wt")]"$'\n'
        note_failure
    fi
done < <(git worktree list --porcelain | awk '/^worktree/{print $2}')
if [[ -n "$unpushed" ]]; then
    print_header ""
    print_header "${RED}🚨 GATE 1 — UNPUSHED COMMITS:${OFF}"
    echo -n "$unpushed"
elif [[ $QUIET -eq 0 ]]; then
    print_header ""
    print_header "${GRN}✓ Gate 1 (pushed)${OFF}"
fi

# ── Gate 2-4: OPEN PRs (state, CI, auto-merge) ───────────────────────────────
pr_json=$(gh pr list --state open --limit 50 --json number,title,headRefName,statusCheckRollup,autoMergeRequest,mergeable,isDraft 2>/dev/null || echo "[]")

stuck=$(echo "$pr_json" | python3 -c '
import json, sys
prs = json.load(sys.stdin)
out = []
for p in prs:
    if p.get("isDraft"): continue
    rollup = p.get("statusCheckRollup") or []
    failing = [c for c in rollup if c.get("conclusion") == "FAILURE"]
    running = [c for c in rollup if c.get("status") in ("IN_PROGRESS", "QUEUED")]
    auto = p.get("autoMergeRequest")
    pr_state = "FAIL" if failing else ("RUN" if running else "OK")
    n, br, t = p["number"], p["headRefName"], p["title"][:60]
    if pr_state == "FAIL" and auto:
        out.append(f"PR #{n} [auto-merge armed but CI:FAIL] {br} — {t}")
    elif not auto and pr_state != "FAIL":
        out.append(f"PR #{n} [no auto-merge] CI:{pr_state} {br} — {t}")
print("\n".join(out))
')

if [[ -n "$stuck" ]]; then
    print_header ""
    print_header "${YEL}⚠️  GATES 3-4 — PR HEALTH ISSUES:${OFF}"
    echo "$stuck" | while IFS= read -r line; do
        if [[ "$line" == *"CI:FAIL"* ]]; then
            echo "  ${RED}$line${OFF}"
            note_failure
        else
            echo "  ${YEL}$line${OFF}"
        fi
    done
elif [[ $QUIET -eq 0 ]]; then
    print_header ""
    print_header "${GRN}✓ Gates 2-4 (open PRs healthy)${OFF}"
fi

# ── Gate 4b: STUCK PRs (auto-merge armed > 2h) ───────────────────────────────
stuck_age=$(echo "$pr_json" | python3 -c '
import json, sys
from datetime import datetime, timezone
prs = json.load(sys.stdin)
now = datetime.now(timezone.utc)
out = []
for p in prs:
    auto = p.get("autoMergeRequest") or {}
    enabled = auto.get("enabledAt")
    if not enabled: continue
    age = (now - datetime.fromisoformat(enabled.replace("Z", "+00:00"))).total_seconds() / 3600
    if age > 2:
        n, br = p["number"], p["headRefName"]
        out.append(f"  PR #{n} armed {age:.1f}h ago — {br}")
print("\n".join(out))
')

if [[ -n "$stuck_age" ]]; then
    print_header ""
    print_header "${YEL}⚠️  STUCK PRs (auto-merge armed > 2h):${OFF}"
    echo "$stuck_age"
fi

# ── Gate 5: LANDED ON MAIN (throughput) ──────────────────────────────────────
git fetch origin main --quiet 2>/dev/null || true
landed=$(git log "origin/main" --since="$SINCE" --oneline | wc -l | tr -d ' ')
if [[ $QUIET -eq 0 ]]; then
    print_header ""
    print_header "${GRN}✓ Gate 5 — landed on main (last $SINCE):${OFF} $landed commits"
    # -n 5 instead of `| head -5` avoids SIGPIPE → 141 under set -o pipefail.
    git log "origin/main" --since="$SINCE" --oneline -n 5 | sed 's/^/  /'
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo "${GRN}━━ ship-audit OK ━━${OFF}"
    exit 0
else
    echo "${RED}━━ ship-audit found $FAILURES failure(s) ━━${OFF}"
    exit 1
fi
