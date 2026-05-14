#!/usr/bin/env bash
# scripts/dispatch/operator-leverage.sh — CREDIBLE-049
#
# Computes the operator-leverage ratio: how much fleet time do we get per
# unit of operator attention?
#
#   leverage_ratio = fleet_active_time / operator_attention_time
#
# fleet_active_time   — sum of session elapsed_seconds for sessions tagged to
#                       the gap (from session_end events in ambient.jsonl)
# operator_attention_time — sum of 5-min windows around any operator action
#                           on the PR (comments, reviews, commits), plus
#                           operator_recall events in ambient.jsonl
#
# Usage:
#   scripts/dispatch/operator-leverage.sh                  # run now
#   scripts/dispatch/operator-leverage.sh --daily          # for cron (daily)
#   scripts/dispatch/operator-leverage.sh --weekly         # for cron (weekly)
#   scripts/dispatch/operator-leverage.sh --window 7       # last N days
#
# Output:
#   ~/.chump/metrics/operator-leverage.jsonl  (per-PR rows)
#   ~/.chump/metrics/operator-leverage-weekly.jsonl  (--weekly only)
#
# Emits ambient kind=leverage_regression when ratio drops >20% w/w.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO/.chump-locks/ambient.jsonl}"
METRICS_DIR="${CHUMP_METRICS_DIR:-$HOME/.chump/metrics}"
BOT_LOGINS="${CHUMP_BOT_LOGINS:-repairman29}"  # comma-separated; these count as fleet, not operator

WINDOW_DAYS=7
MODE="run"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --daily)  MODE="daily"; shift ;;
        --weekly) MODE="weekly"; shift ;;
        --window) WINDOW_DAYS="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0" | grep '^#' | sed 's/^# //'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$METRICS_DIR"

REPO_NWO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")"

python3 - "$AMBIENT" "$METRICS_DIR" "$REPO_NWO" "$BOT_LOGINS" \
         "$WINDOW_DAYS" "$MODE" <<'PY'
import json, sys, os, subprocess, datetime, math

ambient_path, metrics_dir, repo_nwo, bot_logins_str, window_days_str, mode = sys.argv[1:7]
window_days = int(window_days_str)
bot_logins = set(b.strip() for b in bot_logins_str.split(",") if b.strip())
now = datetime.datetime.now(datetime.timezone.utc)
window_start = now - datetime.timedelta(days=window_days)

def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None

def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

# ── 1. Collect fleet-active time per gap_id from ambient session_end events ──
fleet_active_by_gap = {}  # gap_id → total elapsed_seconds
session_rows = []

if os.path.exists(ambient_path):
    with open(ambient_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("kind") != "session_end":
                continue
            gap_id = e.get("gap_id")
            if not gap_id:
                continue
            ts = parse_ts(e.get("ts"))
            if not ts or ts < window_start:
                continue
            elapsed = int(e.get("elapsed_seconds") or 0)
            fleet_active_by_gap[gap_id] = fleet_active_by_gap.get(gap_id, 0) + elapsed
            session_rows.append({"ts": iso(ts), "gap_id": gap_id,
                                  "session_id": e.get("session_id", "?"),
                                  "elapsed_s": elapsed})

# ── 2. For each gap with fleet time, find associated PR number ─────────────
def get_pr_for_gap(gap_id):
    """Return PR number (int) or None."""
    try:
        r = subprocess.run(
            ["chump", "gap", "show", gap_id],
            capture_output=True, text=True, timeout=10,
        )
        for line in r.stdout.splitlines():
            if "merged_pr:" in line or "open_pr:" in line or "pr:" in line:
                parts = line.strip().split()
                for p in parts:
                    if p.isdigit():
                        return int(p)
    except Exception:
        pass
    # Try gh pr list fallback
    branch = gap_id.lower().replace("-", "-").replace("_", "-")
    try:
        r = subprocess.run(
            ["gh", "pr", "list", "--state", "all", "--search", gap_id,
             "--json", "number", "--jq", ".[0].number"],
            capture_output=True, text=True, timeout=15,
        )
        val = r.stdout.strip()
        if val and val.isdigit():
            return int(val)
    except Exception:
        pass
    return None

# ── 3. For each gap's PR, compute operator-attention-time ─────────────────
def get_operator_attention_s(pr_number):
    """
    Fetch PR timeline events (comments, reviews, commits) and compute
    the total span of operator attention: union of 5-min windows around
    each operator action, then sum their lengths.
    """
    if not repo_nwo or not pr_number:
        return 0
    action_ts = []
    try:
        # PR commits
        r = subprocess.run(
            ["gh", "api", f"repos/{repo_nwo}/pulls/{pr_number}/commits",
             "--jq", "[.[] | select(.author.login != null) | {login: .author.login, ts: .commit.committer.date}]"],
            capture_output=True, text=True, timeout=20,
        )
        items = json.loads(r.stdout or "[]")
        for it in items:
            if it.get("login") not in bot_logins:
                t = parse_ts(it.get("ts"))
                if t and t >= window_start:
                    action_ts.append(t)
    except Exception:
        pass
    try:
        # PR comments
        r = subprocess.run(
            ["gh", "api", f"repos/{repo_nwo}/issues/{pr_number}/comments",
             "--jq", "[.[] | {login: .user.login, ts: .created_at}]"],
            capture_output=True, text=True, timeout=20,
        )
        items = json.loads(r.stdout or "[]")
        for it in items:
            if it.get("login") not in bot_logins:
                t = parse_ts(it.get("ts"))
                if t and t >= window_start:
                    action_ts.append(t)
    except Exception:
        pass
    try:
        # PR reviews
        r = subprocess.run(
            ["gh", "api", f"repos/{repo_nwo}/pulls/{pr_number}/reviews",
             "--jq", "[.[] | {login: .user.login, ts: .submitted_at}]"],
            capture_output=True, text=True, timeout=20,
        )
        items = json.loads(r.stdout or "[]")
        for it in items:
            if it.get("login") not in bot_logins:
                t = parse_ts(it.get("ts"))
                if t and t >= window_start:
                    action_ts.append(t)
    except Exception:
        pass

    if not action_ts:
        return 0

    # Union of 5-min windows around each action timestamp
    action_ts.sort()
    WINDOW = datetime.timedelta(minutes=5)
    intervals = []
    for t in action_ts:
        start = t - WINDOW
        end = t + WINDOW
        if intervals and start <= intervals[-1][1]:
            intervals[-1] = (intervals[-1][0], max(intervals[-1][1], end))
        else:
            intervals.append((start, end))
    total_s = sum(int((e - s).total_seconds()) for s, e in intervals)
    return total_s

# ── 4. Also add operator_recall events from ambient ────────────────────────
# Each operator_recall event counts as a 5-min attention window.
recall_windows = []
if os.path.exists(ambient_path):
    with open(ambient_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("kind") != "operator_recall":
                continue
            ts = parse_ts(e.get("ts"))
            if ts and ts >= window_start:
                recall_windows.append(ts)

recall_attention_s = len(recall_windows) * 300  # each recall = 5 min

# ── 5. Compute per-PR rows ─────────────────────────────────────────────────
rows = []
all_pr_attention = {}  # pr_number → attention_s (avoid duplicate gh calls)

for gap_id, fleet_s in sorted(fleet_active_by_gap.items()):
    if fleet_s == 0:
        continue
    pr_number = get_pr_for_gap(gap_id)
    if pr_number and pr_number not in all_pr_attention:
        all_pr_attention[pr_number] = get_operator_attention_s(pr_number)
    operator_s = all_pr_attention.get(pr_number, 0)
    # Add a proportional share of recall attention to each gap
    operator_s_with_recall = operator_s + (recall_attention_s // max(len(fleet_active_by_gap), 1))
    leverage = round(fleet_s / max(operator_s_with_recall, 60), 2)

    rows.append({
        "ts": iso(now),
        "gap_id": gap_id,
        "pr_number": pr_number,
        "fleet_active_s": fleet_s,
        "operator_attention_s": operator_s_with_recall,
        "leverage_ratio": leverage,
    })

# ── 6. Write per-PR metrics ────────────────────────────────────────────────
out_path = os.path.join(metrics_dir, "operator-leverage.jsonl")
with open(out_path, "a", encoding="utf-8") as f:
    for row in rows:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")

print(f"operator-leverage: {len(rows)} gaps processed → {out_path}")
if rows:
    mean_lev = sum(r["leverage_ratio"] for r in rows) / len(rows)
    p50 = sorted(rows, key=lambda x: x["leverage_ratio"])[len(rows) // 2]["leverage_ratio"]
    print(f"  mean leverage: {mean_lev:.1f}x  p50: {p50:.1f}x")

# ── 7. Weekly aggregate (--weekly mode or --mode weekly) ──────────────────
if mode == "weekly" and rows:
    week_path = os.path.join(metrics_dir, "operator-leverage-weekly.jsonl")
    week_str = now.strftime("%Y-W%W")
    mean_lev = sum(r["leverage_ratio"] for r in rows) / len(rows)
    sorted_lev = sorted(r["leverage_ratio"] for r in rows)
    p50 = sorted_lev[len(sorted_lev) // 2]
    p90 = sorted_lev[int(len(sorted_lev) * 0.9)]
    week_row = {
        "ts": iso(now),
        "week": week_str,
        "count_prs": len(rows),
        "mean_leverage": round(mean_lev, 2),
        "p50_leverage": round(p50, 2),
        "p90_leverage": round(p90, 2),
        "fleet_active_s_total": sum(r["fleet_active_s"] for r in rows),
        "operator_attention_s_total": sum(r["operator_attention_s"] for r in rows),
    }
    with open(week_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(week_row, separators=(",", ":")) + "\n")
    print(f"  weekly row written → {week_path}")

    # ── 8. Regression detection ──────────────────────────────────────────
    # Read last two weekly rows; if ratio dropped >20%, emit ambient event.
    try:
        with open(week_path, encoding="utf-8") as f:
            weeks = [json.loads(l) for l in f if l.strip()]
        if len(weeks) >= 2:
            prev = weeks[-2]["mean_leverage"]
            curr = weeks[-1]["mean_leverage"]
            if prev > 0 and (prev - curr) / prev > 0.2:
                ambient_path_final = os.environ.get("CHUMP_AMBIENT_LOG", "")
                if not ambient_path_final:
                    # Fallback
                    ambient_path_final = ambient_path
                ts_str = iso(now)
                ev = json.dumps({
                    "ts": ts_str,
                    "kind": "leverage_regression",
                    "week": week_str,
                    "prev_mean_leverage": round(prev, 2),
                    "curr_mean_leverage": round(curr, 2),
                    "drop_pct": round((prev - curr) / prev * 100, 1),
                }, separators=(",", ":"))
                with open(ambient_path_final, "a", encoding="utf-8") as f:
                    f.write(ev + "\n")
                print(f"  ALERT: leverage_regression emitted (dropped {round((prev-curr)/prev*100,1)}%)")
    except Exception:
        pass

if not rows:
    print("  (no session_end events with gap_id in window — try --window 30 for a longer look)")
PY
