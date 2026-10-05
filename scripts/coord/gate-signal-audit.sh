#!/usr/bin/env bash
# gate-signal-audit.sh — CREDIBLE-271 (SHIP-INFRA 4/7 [RELIABILITY])
#
# Audits whether our CI/fleet "gates" (reapers, halt-class detectors, grace
# windows) are producing a real signal, or firing/existing for no measurable
# effect. Three concrete failure classes named in the gap:
#
#   1. Phantom reapers — a reaper (sccache/target-dir/incremental) that has
#      run N+ times and freed 0 bytes every time. Either it is mis-scoped
#      (nothing left to reap) or its freed-bytes accounting is broken; either
#      way it is not producing a measured signal and should be fixed or cut.
#
#   2. farmer_auth_dead false positives — a farmer_auth_dead ambient event
#      fired while the fleet kept shipping (gap_shipped / pr_merged near the
#      same timestamp). A halt-class signal that fires alongside continued
#      shipping is not halt-class; it is noise that erodes trust in the real
#      alerts (see docs/process/OPERATOR_PLAYBOOK.md cry-wolf history).
#
#   3. Write-only grace-guards — a script that writes a grace-window record
#      (e.g. required-check-grace.json) but whose consult/read path (the
#      function or CLI flag that actually skips something because of the
#      grace window) is never invoked anywhere else in the repo. The write
#      side existing does not mean the guard guards anything.
#
# Usage:
#   scripts/coord/gate-signal-audit.sh [--ambient-file PATH] [--window-days N]
#                                       [--fp-window-mins N] [--min-runs N]
#                                       [--output FILE] [--skip-required-checks]
#
# Output: markdown report to --output (default docs/eval/gate-signal-audit-<date>.md)
#         plus a stdout summary with one FP-rate line per audited category.
#
# Rust-First-Bypass: one-shot/periodic audit tool, <260 LOC, reads ambient
# log + greps repo, mutates nothing — shell-OK criteria met per META-064.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AMBIENT_FILE="${REPO_ROOT}/.chump-locks/ambient.jsonl"
WINDOW_DAYS=30
FP_WINDOW_MINS=30
MIN_RUNS=2
OUTPUT_FILE=""
SKIP_REQUIRED_CHECKS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ambient-file) AMBIENT_FILE="$2"; shift 2 ;;
        --window-days) WINDOW_DAYS="$2"; shift 2 ;;
        --fp-window-mins) FP_WINDOW_MINS="$2"; shift 2 ;;
        --min-runs) MIN_RUNS="$2"; shift 2 ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        --skip-required-checks) SKIP_REQUIRED_CHECKS=1; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "[gate-signal-audit] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="${REPO_ROOT}/docs/eval/gate-signal-audit-$(date -u +%Y-%m-%d).md"
fi

if [[ ! -f "$AMBIENT_FILE" ]]; then
    echo "[gate-signal-audit] ERROR: ambient file not found: $AMBIENT_FILE" >&2
    exit 1
fi

# ── Category 1: phantom reapers ──────────────────────────────────────────────
# Sums a "freed" measure per reaper kind, across kinds whose name matches
# _reap(ed|er) and that report freed bytes/kb/mb/gb. A kind with >= MIN_RUNS
# occurrences and a total freed of exactly 0 is PHANTOM.
REAPER_REPORT="$(python3 - "$AMBIENT_FILE" "$MIN_RUNS" <<'PYEOF'
import json, sys
path, min_runs = sys.argv[1], int(sys.argv[2])
totals = {}
counts = {}
for line in open(path, encoding="utf-8", errors="ignore"):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    kind = ev.get("kind", "")
    if "reap" not in kind:
        continue
    freed_bytes = 0.0
    if "bytes_freed" in ev:
        freed_bytes = float(ev.get("bytes_freed") or 0)
    elif "freed_kb" in ev:
        freed_bytes = float(ev.get("freed_kb") or 0) * 1024
    elif "freed_gb" in ev:
        freed_bytes = float(ev.get("freed_gb") or 0) * 1e9
    elif "freed_mb" in ev:
        freed_bytes = float(ev.get("freed_mb") or 0) * 1e6
    else:
        continue  # no freed-measure field — not a reaper-with-a-signal kind
    totals[kind] = totals.get(kind, 0.0) + freed_bytes
    counts[kind] = counts.get(kind, 0) + 1

phantom = 0
total_kinds = 0
for kind in sorted(counts):
    total_kinds += 1
    runs = counts[kind]
    freed = totals[kind]
    is_phantom = runs >= min_runs and freed == 0
    if is_phantom:
        phantom += 1
    print(f"{kind}\t{runs}\t{freed:.0f}\t{'PHANTOM' if is_phantom else 'signal'}")
PYEOF
)"
REAPER_ROWS="$(echo "$REAPER_REPORT" | grep -v '^$' || true)"
REAPER_PHANTOM_COUNT="$(echo "$REAPER_ROWS" | awk -F'\t' '$4=="PHANTOM"{c++} END{print c+0}')"
REAPER_TOTAL_COUNT="$(echo "$REAPER_ROWS" | awk -F'\t' 'NF{c++} END{print c+0}')"
if [[ "$REAPER_TOTAL_COUNT" -gt 0 ]]; then
    REAPER_FPR="$(python3 -c "print(f'{$REAPER_PHANTOM_COUNT/$REAPER_TOTAL_COUNT*100:.1f}%')")"
else
    REAPER_FPR="N/A"
fi

# ── Category 2: farmer_auth_dead false positives ─────────────────────────────
# A farmer_auth_dead event is classified FP if a gap_shipped or pr_merged
# event exists within +/- FP_WINDOW_MINS minutes in the same ambient log
# (the fleet kept shipping — the "auth is dead" signal did not reflect
# a real inability to transact).
AUTHDEAD_REPORT="$(python3 - "$AMBIENT_FILE" "$FP_WINDOW_MINS" <<'PYEOF'
import json, sys, datetime
path, window_mins = sys.argv[1], int(sys.argv[2])

def parse_ts(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except Exception:
        return None

auth_dead_events = []
ship_events = []
for line in open(path, encoding="utf-8", errors="ignore"):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    kind = ev.get("kind", "")
    ts = parse_ts(ev.get("ts", ""))
    if ts is None:
        continue
    if kind == "farmer_auth_dead":
        auth_dead_events.append(ts)
    elif kind in ("gap_shipped", "pr_merged"):
        ship_events.append(ts)

window = datetime.timedelta(minutes=window_mins)
fp = 0
for ts in auth_dead_events:
    if any(abs((ts - s).total_seconds()) <= window.total_seconds() for s in ship_events):
        fp += 1

total = len(auth_dead_events)
print(f"{total}\t{fp}")
PYEOF
)"
AUTHDEAD_TOTAL="$(echo "$AUTHDEAD_REPORT" | cut -f1)"
AUTHDEAD_FP="$(echo "$AUTHDEAD_REPORT" | cut -f2)"
if [[ "${AUTHDEAD_TOTAL:-0}" -gt 0 ]]; then
    AUTHDEAD_FPR="$(python3 -c "print(f'{$AUTHDEAD_FP/$AUTHDEAD_TOTAL*100:.1f}%')")"
else
    AUTHDEAD_FPR="N/A (0 events in log)"
fi

# ── Category 3: write-only grace-guards ──────────────────────────────────────
# Candidate scripts that write a grace-window record. For each, check whether
# any OTHER file in the repo actually invokes the consult path — matched by
# the script's full repo-relative path (not bare basename, which false-hits
# on prose mentions like a comment saying "triggered by required-check-monitor.sh"),
# excluding the script's own file, this audit script, and its test.
declare -a GRACE_CANDIDATES=(
    "scripts/coord/required-check-monitor.sh"
)
GRACE_ROWS=""
GRACE_WRITEONLY_COUNT=0
GRACE_TOTAL_COUNT=0
for rel in "${GRACE_CANDIDATES[@]}"; do
    GRACE_TOTAL_COUNT=$((GRACE_TOTAL_COUNT + 1))
    # Count references to this script's full relative path outside the
    # script's own file, this auditor, and its regression test.
    hits=$(grep -rln --include='*.sh' --include='*.yml' --include='*.plist' \
        -F "$rel" "$REPO_ROOT" 2>/dev/null \
        | grep -v "/${rel}$" \
        | grep -v "/scripts/coord/gate-signal-audit.sh$" \
        | grep -v "/scripts/ci/test-gate-signal-audit.sh$" \
        | wc -l | tr -d ' ')
    status="signal"
    if [[ "$hits" -eq 0 ]]; then
        status="WRITE_ONLY"
        GRACE_WRITEONLY_COUNT=$((GRACE_WRITEONLY_COUNT + 1))
    fi
    GRACE_ROWS="${GRACE_ROWS}${rel}\t${hits}\t${status}\n"
done
if [[ "$GRACE_TOTAL_COUNT" -gt 0 ]]; then
    GRACE_FPR="$(python3 -c "print(f'{$GRACE_WRITEONLY_COUNT/$GRACE_TOTAL_COUNT*100:.1f}%')")"
else
    GRACE_FPR="N/A"
fi

# ── Category 4 (best-effort): phantom required checks ────────────────────────
REQCHECK_SECTION="(skipped — pass without --skip-required-checks and with authenticated gh to run)"
if [[ "$SKIP_REQUIRED_CHECKS" -eq 0 ]] && command -v gh &>/dev/null && gh auth status &>/dev/null; then
    REPO_SLUG="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed -E 's|.*github.com[:/]||; s|\.git$||')"
    if [[ -n "$REPO_SLUG" ]]; then
        REQUIRED="$(gh api "repos/${REPO_SLUG}/branches/main/protection" --jq '.required_status_checks.contexts[]?' 2>/dev/null || true)"
        if [[ -n "$REQUIRED" ]]; then
            PHANTOM_CHECKS=""
            while IFS= read -r check; do
                [[ -z "$check" ]] && continue
                if ! grep -rqF "$check" "$REPO_ROOT/.github/workflows/" 2>/dev/null; then
                    PHANTOM_CHECKS="${PHANTOM_CHECKS}- \`${check}\` — required, no matching job name in .github/workflows/\n"
                fi
            done <<< "$REQUIRED"
            if [[ -n "$PHANTOM_CHECKS" ]]; then
                REQCHECK_SECTION="$(printf '%b' "$PHANTOM_CHECKS")"
            else
                REQCHECK_SECTION="none — every required check maps to a workflow job"
            fi
        else
            REQCHECK_SECTION="(no required_status_checks.contexts returned — ruleset may be used instead of branch protection)"
        fi
    else
        REQCHECK_SECTION="(could not resolve repo slug from origin remote)"
    fi
else
    REQCHECK_SECTION="(skipped — gh unavailable/unauthenticated, or --skip-required-checks passed)"
fi

# ── Write report ──────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$OUTPUT_FILE")"
{
    echo "# Gate signal audit — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "**Gap:** CREDIBLE-271 (SHIP-INFRA 4/7)"
    echo "**Ambient source:** ${AMBIENT_FILE}"
    echo
    echo "## 1. Reaper signal (phantom = >= ${MIN_RUNS} runs, 0 bytes freed total)"
    echo
    echo "| kind | runs | bytes freed | verdict |"
    echo "|---|---|---|---|"
    if [[ -n "$REAPER_ROWS" ]]; then
        echo "$REAPER_ROWS" | awk -F'\t' '{printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4}'
    else
        echo "| (no reaper-kind events in window) | | | |"
    fi
    echo
    echo "Reaper phantom rate: **${REAPER_FPR}** (${REAPER_PHANTOM_COUNT}/${REAPER_TOTAL_COUNT} reaper kinds)"
    echo
    echo "## 2. farmer_auth_dead false-positive rate (fired within ${FP_WINDOW_MINS}m of shipping activity)"
    echo
    echo "Events: ${AUTHDEAD_TOTAL:-0}, classified FP: ${AUTHDEAD_FP:-0}"
    echo
    echo "farmer_auth_dead FP rate: **${AUTHDEAD_FPR}**"
    echo
    echo "## 3. Write-only grace-guards (write-side exists, consult-side has 0 external callers)"
    echo
    echo "| script | external references | verdict |"
    echo "|---|---|---|"
    printf '%b' "$GRACE_ROWS" | awk -F'\t' 'NF{printf "| %s | %s | %s |\n", $1, $2, $3}'
    echo
    echo "Write-only grace-guard rate: **${GRACE_FPR}** (${GRACE_WRITEONLY_COUNT}/${GRACE_TOTAL_COUNT})"
    echo
    echo "## 4. Phantom required checks (best-effort, needs authenticated gh)"
    echo
    echo "$REQCHECK_SECTION"
    echo
    echo "## Action"
    echo
    echo "Any PHANTOM / WRITE_ONLY finding above is a candidate to either fix"
    echo "(wire the consult path in, or fix the freed-bytes accounting) or"
    echo "DELETE per the gap's charter: every gate a real signal or deleted."
} > "$OUTPUT_FILE"

echo "[gate-signal-audit] reaper phantom rate:      ${REAPER_FPR} (${REAPER_PHANTOM_COUNT}/${REAPER_TOTAL_COUNT})"
echo "[gate-signal-audit] farmer_auth_dead FP rate:  ${AUTHDEAD_FPR}"
echo "[gate-signal-audit] write-only grace-guards:   ${GRACE_FPR} (${GRACE_WRITEONLY_COUNT}/${GRACE_TOTAL_COUNT})"
echo "[gate-signal-audit] report written to: ${OUTPUT_FILE}"
