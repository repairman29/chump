#!/usr/bin/env bash
# scripts/dev/pr-wallclock-report.sh — RESILIENT-1552 (RESILIENT-1548 slice)
#
# Parent AC3 (RESILIENT-1548) requires proving median PR CI wall-clock and
# pre-push time dropped materially — this is the "prove it" command. Pure
# report: reads existing signals, writes nothing, cannot block a PR.
#
# Two independent halves, both bucketed by the same PR-class heuristic
# (docs_only / single_crate / full / unknown — see _pp_classify_pr_class in
# scripts/git-hooks/pre-push and _wc_classify_files below):
#
#   1. Pre-push wall-clock — reads kind=prepush_duration events from
#      .chump-locks/ambient.jsonl (emitted by the pre-push hook's EXIT trap
#      on every invocation, success or BLOCKED).
#   2. CI wall-clock — reads the check_runs + pr_state tables in
#      .chump/github_cache.db (populated by the webhook receiver /
#      scripts/ops/github-webhook-receiver.py); per PR, wall-clock is
#      MAX(completed_at) - MIN(started_at) across that PR's head_sha. File
#      list for classification comes from cache_lookup_pr_files (background
#      REST call on cache miss — fine for an occasional manual report).
#
# Either half degrades gracefully to "no data" if its source is empty/
# missing — this never errors out just because one signal hasn't
# accumulated samples yet.
#
# Usage:
#   scripts/dev/pr-wallclock-report.sh                # last 7d, text
#   scripts/dev/pr-wallclock-report.sh --window 24h   # last 24h
#   scripts/dev/pr-wallclock-report.sh --json          # machine-readable

set -euo pipefail

WINDOW="7d"
AS_JSON=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --window) WINDOW="$2"; shift 2 ;;
        --json)   AS_JSON=1; shift ;;
        -h|--help)
            sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_OVERRIDE:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
CACHE_DB="${CHUMP_CACHE_DB:-$REPO_ROOT/.chump/github_cache.db}"

# shellcheck source=scripts/coord/lib/github_cache.sh
_GCACHE_LIB="$REPO_ROOT/scripts/coord/lib/github_cache.sh"
[[ -f "$_GCACHE_LIB" ]] && source "$_GCACHE_LIB"

# Mirrors _pp_classify_pr_class in scripts/git-hooks/pre-push so the two
# halves of this report use the same buckets.
_wc_classify_files() {
    local files="$1"
    if [[ -z "$files" ]]; then
        echo "unclassified"
        return
    fi
    if ! grep -qvE '\.(md|txt)$|(^|/)docs/' <<<"$files"; then
        echo "docs_only"
        return
    fi
    local crate_count top_count
    crate_count="$(grep -oE '^crates/[^/]+' <<<"$files" | sort -u | wc -l | xargs)"
    top_count="$(awk -F/ '{print $1}' <<<"$files" | sort -u | wc -l | xargs)"
    if [[ "$crate_count" -le 1 ]] && [[ "$top_count" -le 2 ]]; then
        echo "single_crate"
    else
        echo "full"
    fi
}

# ---- Half 2 first: walk check_runs/pr_state, emit "<class>\t<seconds>" rows
# to a temp file. Done before Half 1 so we can feed both into one python
# median pass at the end.
CI_ROWS="$(mktemp)"
trap 'rm -f "$CI_ROWS"' EXIT

if [[ -f "$CACHE_DB" ]] && command -v sqlite3 &>/dev/null; then
    while IFS='|' read -r number head_sha start_s end_s; do
        [[ -z "$number" ]] && continue
        [[ -z "$start_s" || -z "$end_s" ]] && continue
        files=""
        if command -v cache_lookup_pr_files &>/dev/null; then
            files="$(cache_lookup_pr_files "$number" 2>/dev/null || true)"
        fi
        class="$(_wc_classify_files "$files")"
        wall_s=$(( end_s - start_s ))
        [[ "$wall_s" -lt 0 ]] && continue
        printf '%s\t%s\n' "$class" "$wall_s" >> "$CI_ROWS"
    done < <(sqlite3 -separator '|' "$CACHE_DB" "
        SELECT ps.number, cr.head_sha,
               CAST(strftime('%s', MIN(cr.started_at)) AS INTEGER),
               CAST(strftime('%s', MAX(cr.completed_at)) AS INTEGER)
        FROM check_runs cr
        JOIN pr_state ps ON ps.head_sha = cr.head_sha
        WHERE cr.started_at IS NOT NULL AND cr.completed_at IS NOT NULL
        GROUP BY ps.number, cr.head_sha
    " 2>/dev/null || true)
fi

PP_ROWS="$(mktemp)"
trap 'rm -f "$CI_ROWS" "$PP_ROWS"' EXIT

if [[ -f "$AMBIENT" ]]; then
    python3 - "$AMBIENT" "$WINDOW" > "$PP_ROWS" <<'PY'
import json, re, sys
from datetime import datetime, timedelta, timezone

path, window = sys.argv[1], sys.argv[2]
m = re.fullmatch(r"(\d+)([hd])", window)
if not m:
    print(f"invalid --window {window!r} (use NNh or NNd)", file=sys.stderr)
    sys.exit(2)
n, unit = int(m.group(1)), m.group(2)
cutoff = datetime.now(timezone.utc) - (timedelta(hours=n) if unit == "h" else timedelta(days=n))

with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("kind") != "prepush_duration":
            continue
        try:
            ts = datetime.strptime(ev["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except Exception:
            continue
        if ts < cutoff:
            continue
        print(f"{ev.get('pr_class', 'unknown')}\t{ev.get('elapsed_s', 0)}")
PY
fi

python3 - "$PP_ROWS" "$CI_ROWS" "$AS_JSON" "$WINDOW" <<'PY'
import json
import statistics
import sys
from collections import defaultdict

pp_path, ci_path, as_json, window = sys.argv[1:5]
as_json = as_json == "1"

def load(path):
    buckets = defaultdict(list)
    try:
        with open(path) as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                cls, _, val = line.partition("\t")
                try:
                    buckets[cls].append(int(val))
                except ValueError:
                    continue
    except FileNotFoundError:
        pass
    return buckets

pp = load(pp_path)
ci = load(ci_path)

def summarize(buckets):
    out = {}
    for cls, vals in buckets.items():
        out[cls] = {
            "n": len(vals),
            "median_s": statistics.median(vals) if vals else None,
            "p90_s": (statistics.quantiles(vals, n=10)[8] if len(vals) >= 2 else (vals[0] if vals else None)),
        }
    return out

report = {
    "window": window,
    "prepush_wallclock": summarize(pp),
    "ci_wallclock": summarize(ci),
}

if as_json:
    print(json.dumps(report, indent=2, sort_keys=True))
    sys.exit(0)

print(f"PR wall-clock report (RESILIENT-1552) — window={window}")
print()
for label, data in (("pre-push hook", report["prepush_wallclock"]), ("CI run", report["ci_wallclock"])):
    print(f"-- {label} wall-clock, by PR class --")
    if not data:
        print("  (no data)")
        continue
    for cls in sorted(data):
        row = data[cls]
        median = row["median_s"]
        p90 = row["p90_s"]
        print(f"  {cls:<14} n={row['n']:<5} median={median}s p90={p90}s")
    print()
PY
