#!/usr/bin/env bash
# extract-best-practices.sh — PRODUCT-008
#
# Nightly best-practice extraction: scans merged PRs, reflection_db outcomes,
# and ambient ALERT events to produce a structured summary with proposed
# convention additions.
#
# Usage:
#   scripts/eval/extract-best-practices.sh [--output-dir <dir>]
#
# Output:
#   docs/best-practices/best-practices-YYYY-MM-DD.md
#
# No LLM calls are made. Data sources:
#   - gh pr list --state merged (last 50, filtered to last 30 days)
#   - SQLite reflection_db (sessions/chump_memory.db or CHUMP_MEMORY_DB_PATH)
#   - .chump-locks/ambient.jsonl (last 200 lines, ALERT events)

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
OUTPUT_DIR="${REPO_ROOT}/docs/best-practices"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

TODAY="$(date +%Y-%m-%d)"
OUTPUT_FILE="${OUTPUT_DIR}/best-practices-${TODAY}.md"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
DB_PATH="${CHUMP_MEMORY_DB_PATH:-${REPO_ROOT}/sessions/chump_memory.db}"

mkdir -p "${OUTPUT_DIR}"
echo "[extract-best-practices] Starting run for ${TODAY}" >&2

# ---------------------------------------------------------------------------
# Helper: run a sqlite3 query safely; returns empty string if DB unavailable
# ---------------------------------------------------------------------------
db_query() {
    [[ -f "${DB_PATH}" ]] || return 0
    sqlite3 -separator $'\t' "${DB_PATH}" "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 1. Fetch merged PRs (last 50, filter to last 30 days)
# ---------------------------------------------------------------------------
echo "[extract-best-practices] Fetching merged PRs..." >&2
PR_JSON='[]'
if command -v gh &>/dev/null; then
    PR_JSON="$(gh pr list --state merged --limit 50 \
        --json number,title,mergedAt,changedFiles,labels 2>/dev/null || echo '[]')"
else
    echo "[extract-best-practices] WARN: gh not found — skipping PR analysis" >&2
fi

# ---------------------------------------------------------------------------
# 2. Query reflection_db
# ---------------------------------------------------------------------------
echo "[extract-best-practices] Querying reflection_db..." >&2
IMPROVEMENT_TARGETS="$(db_query "
    SELECT it.priority, it.directive, COUNT(*) AS freq
    FROM chump_improvement_targets it
    WHERE it.priority IN ('high','critical')
      AND it.created_at >= datetime('now', '-30 days')
    GROUP BY it.directive
    ORDER BY freq DESC, it.priority DESC
    LIMIT 10;")"

OUTCOME_DIST="$(db_query "
    SELECT outcome_class, COUNT(*) AS cnt
    FROM chump_reflections
    WHERE created_at >= datetime('now', '-30 days')
    GROUP BY outcome_class
    ORDER BY cnt DESC;")"

ERROR_PATTERNS="$(db_query "
    SELECT error_patterns, COUNT(*) AS cnt
    FROM chump_reflections
    WHERE created_at >= datetime('now', '-30 days')
      AND error_patterns != '' AND error_patterns IS NOT NULL
    GROUP BY error_patterns
    ORDER BY cnt DESC
    LIMIT 5;")"

REFLECTION_COUNT="$(db_query "
    SELECT COUNT(*) FROM chump_reflections
    WHERE created_at >= datetime('now', '-30 days');" | tr -d '[:space:]')"
REFLECTION_COUNT="${REFLECTION_COUNT:-0}"

# ---------------------------------------------------------------------------
# 3. Parse ambient.jsonl (last 200 lines) for ALERT events
# ---------------------------------------------------------------------------
echo "[extract-best-practices] Scanning ambient events..." >&2
AMBIENT_TAIL=""
if [[ -f "${AMBIENT_LOG}" ]]; then
    AMBIENT_TAIL="$(tail -200 "${AMBIENT_LOG}" 2>/dev/null || true)"
else
    echo "[extract-best-practices] WARN: ambient log not found at ${AMBIENT_LOG}" >&2
fi

# ---------------------------------------------------------------------------
# 4. Render everything in a single Python pass
# ---------------------------------------------------------------------------
echo "[extract-best-practices] Writing report to ${OUTPUT_FILE}..." >&2

python3 - \
    "${OUTPUT_FILE}" \
    "${TODAY}" \
    "${REFLECTION_COUNT}" \
    "${DB_PATH}" \
    "${IMPROVEMENT_TARGETS}" \
    "${OUTCOME_DIST}" \
    "${ERROR_PATTERNS}" \
    "${AMBIENT_TAIL}" \
    <<'PYEOF'
import sys, json, os, re, statistics, datetime

# ---- args ----------------------------------------------------------------
output_file            = sys.argv[1]
today                  = sys.argv[2]
refl_count             = sys.argv[3]
db_path                = sys.argv[4]
improvement_targets_raw = sys.argv[5]
outcome_dist_raw       = sys.argv[6]
error_patterns_raw     = sys.argv[7]
ambient_raw            = sys.argv[8] if len(sys.argv) > 8 else ""

db_available = os.path.isfile(db_path) if db_path else False

# ---- parse PR JSON from env -----------------------------------------------
pr_json_str = os.environ.get("PR_JSON", "[]")
try:
    all_prs = json.loads(pr_json_str)
except json.JSONDecodeError:
    all_prs = []

today_dt = datetime.date.fromisoformat(today)
cutoff = datetime.datetime(today_dt.year, today_dt.month, today_dt.day,
                           tzinfo=datetime.timezone.utc) - datetime.timedelta(days=30)

filtered_prs = []
for pr in all_prs:
    merged = pr.get("mergedAt", "")
    if not merged:
        continue
    try:
        dt = datetime.datetime.fromisoformat(merged.replace("Z", "+00:00"))
        if dt >= cutoff:
            filtered_prs.append(pr)
    except ValueError:
        filtered_prs.append(pr)

pr_count = len(filtered_prs)
if pr_count > 0:
    files_list = [pr.get("changedFiles", 0) for pr in filtered_prs]
    avg_files = round(statistics.mean(files_list), 1)
    small_prs = [pr for pr in filtered_prs if pr.get("changedFiles", 0) <= 5]
    small_pr_pct = round(len(small_prs) / pr_count * 100, 1)
    auto_merge_count = sum(
        1 for pr in filtered_prs
        if any(lbl.get("name","") in ("auto-merge","automerge") for lbl in pr.get("labels",[]))
        or "auto-merge" in pr.get("title","").lower()
    )
    auto_merge_pct = round(auto_merge_count / pr_count * 100, 1)
    gap_ids = sorted({gid for pr in filtered_prs
                      for gid in re.findall(r'[A-Z]+-\d+', pr.get("title",""))})
    min_files, max_files = min(files_list), max(files_list)
else:
    avg_files = small_pr_pct = auto_merge_pct = 0
    auto_merge_count = small_pr_count = min_files = max_files = 0
    gap_ids = []
    small_prs = []

# ---- parse ambient ALERTs -------------------------------------------------
alert_by_kind = {}
recent_alerts = []
for line in ambient_raw.strip().splitlines():
    if not line.strip():
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if ev.get("event") == "ALERT":
        kind = ev.get("kind", "unknown")
        alert_by_kind[kind] = alert_by_kind.get(kind, 0) + 1
        recent_alerts.append({"ts": ev.get("ts",""), "kind": kind, "detail": ev.get("detail","")})

total_alerts = sum(alert_by_kind.values())
recent_alerts = recent_alerts[-5:]

# ---- build report ---------------------------------------------------------
L = []  # accumulate lines

L += [
    f"# Chump Best Practices — {today}",
    "",
    "> Auto-generated by `scripts/eval/extract-best-practices.sh` (PRODUCT-008).",
    "> Human review required before promoting any item to CLAUDE.md or AGENT_COORDINATION.md.",
    "",
    "---",
    "",
]

# PR section
L += ["## PR Analysis (last 30 days)", ""]
if pr_count == 0:
    L += ["_No merged PRs found in the last 30 days (or gh CLI unavailable)._", ""]
else:
    L += [
        f"- **Merged PRs analyzed:** {pr_count}",
        f"- **Average changed files per PR:** {avg_files}",
        f"- **Small PRs (≤5 files):** {len(small_prs)} ({small_pr_pct}%)",
        f"- **Auto-merge labeled PRs:** {auto_merge_count} ({auto_merge_pct}%)",
        f"- **File size range:** {min_files}–{max_files} files",
    ]
    if gap_ids:
        L.append(f"- **Gap IDs in PR titles:** {', '.join(gap_ids[:20])}")
    L += ["", "### Observed patterns", ""]
    if small_pr_pct >= 70:
        L.append(f"- High small-PR compliance ({small_pr_pct}%): the ≤5-file rule is being followed well.")
    elif small_pr_pct >= 40:
        L.append(f"- Moderate small-PR compliance ({small_pr_pct}%): some large PRs slipping through.")
    else:
        L.append(f"- Low small-PR compliance ({small_pr_pct}%): many PRs exceed the 5-file guideline.")
    if auto_merge_pct >= 80:
        L.append(f"- Auto-merge adoption high ({auto_merge_pct}%): merge queue is being used as intended.")
    elif auto_merge_pct >= 30:
        L.append(f"- Auto-merge adoption moderate ({auto_merge_pct}%): some PRs still merged manually.")
    else:
        L.append(f"- Auto-merge adoption low ({auto_merge_pct}%): many PRs merged without the auto-merge queue.")
    L.append("")

# Reflection DB section
L += ["## Reflection DB Analysis (last 30 days)", ""]
if not db_available:
    L += [
        "_reflection_db not found — run `chump` at least once to initialize,_",
        "_or set `CHUMP_MEMORY_DB_PATH` to an existing `sessions/chump_memory.db`._",
        "",
    ]
else:
    L.append(f"- **Reflections recorded in last 30 days:** {refl_count}")
    L.append("")
    if outcome_dist_raw.strip():
        L += ["### Outcome class distribution", "", "| Outcome | Count |", "|---------|-------|"]
        for row in outcome_dist_raw.strip().splitlines():
            p = row.split("\t")
            if len(p) >= 2:
                L.append(f"| {p[0]} | {p[1]} |")
        L.append("")
    else:
        L += ["_No outcome data in last 30 days._", ""]
    if improvement_targets_raw.strip():
        L += [
            "### Top improvement targets (high/critical priority)",
            "",
            "| Priority | Directive | Frequency |",
            "|----------|-----------|-----------|",
        ]
        for row in improvement_targets_raw.strip().splitlines():
            p = row.split("\t")
            if len(p) >= 3:
                d = p[1][:120] + "…" if len(p[1]) > 120 else p[1]
                L.append(f"| {p[0]} | {d} | {p[2]} |")
        L.append("")
    else:
        L += ["_No high/critical improvement targets in last 30 days._", ""]
    if error_patterns_raw.strip():
        L += ["### Recurring error patterns", ""]
        for row in error_patterns_raw.strip().splitlines():
            p = row.split("\t")
            if len(p) >= 2:
                L.append(f"- `{p[0]}` (seen {p[1]}×)")
        L.append("")

# Ambient section
L += ["## Ambient Event Analysis (last 200 lines of ambient.jsonl)", ""]
L.append(f"- **Total ALERT events:** {total_alerts}")
if alert_by_kind:
    L.append("- **By kind:**")
    for kind, cnt in sorted(alert_by_kind.items(), key=lambda x: -x[1]):
        L.append(f"  - `{kind}`: {cnt}")
L.append("")
if recent_alerts:
    L += ["### Most recent ALERTs", ""]
    for a in recent_alerts:
        detail = f" — {a['detail']}" if a.get("detail") else ""
        L.append(f"- `{a['ts']}` `{a['kind']}`{detail}")
    L.append("")
if not alert_by_kind:
    L += ["_No ALERT events in the last 200 ambient log entries._", ""]

# Proposed conventions
L += [
    "## Proposed Convention Additions",
    "",
    "_Review each item below before promoting to CLAUDE.md or AGENT_COORDINATION.md._",
    "",
    "### Proposed additions to CLAUDE.md",
    "",
]
props_claude = []
if pr_count > 0 and small_pr_pct < 60:
    props_claude.append(
        f"- Reinforce PR size limit: only {small_pr_pct}% of PRs meet the ≤5-file guideline. "
        "Consider a pre-push warning in `scripts/coord/bot-merge.sh` when `changedFiles > 5`."
    )
if pr_count > 0 and auto_merge_pct < 50:
    props_claude.append(
        f"- Auto-merge adoption is at {auto_merge_pct}%. Remind agents: `bot-merge.sh --auto-merge` "
        "is the default ship path — manual `gh pr merge` bypasses the merge queue and increases squash-loss risk."
    )
if improvement_targets_raw.strip():
    props_claude.append(
        "- High-priority improvement targets exist in reflection_db (see table above). "
        "Consider running `chump --briefing` with the top target IDs at sprint start."
    )
if not props_claude:
    props_claude.append("_No changes proposed for CLAUDE.md based on current data._")
L += props_claude + [""]

L += ["### Proposed additions to AGENT_COORDINATION.md", ""]
props_coord = []
lo = alert_by_kind.get("lease_overlap", 0)
if lo > 0:
    props_coord.append(
        f"- `lease_overlap` alerts occurred {lo}× in the sampled window. "
        "Review whether agents run `gap-preflight.sh` before claiming; consider adding a "
        "reminder to the pre-flight checklist in §1."
    )
sa = alert_by_kind.get("silent_agent", 0)
if sa > 0:
    props_coord.append(
        f"- `silent_agent` alerts occurred {sa}× — heartbeat interval expectations may need "
        "more prominence in §2."
    )
if not props_coord:
    props_coord.append("_No changes proposed for AGENT_COORDINATION.md based on current data._")
L += props_coord + [""]

# Human review checklist
L += [
    "---",
    "",
    "## Human Review Checklist",
    "",
    "Before promoting any finding to CLAUDE.md or AGENT_COORDINATION.md:",
    "",
    "- [ ] Verify PR count and date range (spot-check with `gh pr list --state merged`)",
    "- [ ] Confirm reflection_db data reflects real agent runs, not test fixtures",
    "- [ ] Review each ALERT event — confirm it was a real incident, not a spurious trigger",
    "- [ ] For each proposed convention: does it generalize, or is it one-off noise?",
    "- [ ] Update `docs/gaps.yaml` if follow-up gaps are warranted",
    "- [ ] Archive this file after review (`mv` to `docs/best-practices/archive/`)",
    "",
    "---",
    "",
    f"_Generated: {today} · `scripts/eval/extract-best-practices.sh` · PRODUCT-008_",
]

with open(output_file, "w") as f:
    f.write("\n".join(L) + "\n")

print(f"[extract-best-practices] Report written: {output_file}")
PYEOF

echo "[extract-best-practices] Done. Output: ${OUTPUT_FILE}" >&2
