#!/usr/bin/env bash
# first-pass-yield.sh — CREDIBLE-273: measure the factory's rework, not its speed.
#
# WHY THIS METRIC. On 2026-08-09 a single session produced 51 CI runs across 7
# PRs — first-pass yield 1/7 (14%), rework multiplier ~7x, and two PRs consumed
# 20 runs while shipping nothing. Duration was never the constraint: the one
# doc-only PR merged in 7m32s on a single clean run. REWORK was the constraint.
#
# WHAT IT MEASURES
#   first-pass yield  = PRs whose CI passed on attempt 1 / PRs total
#   rework multiplier = total CI runs / PRs total   (1.0 is perfect)
#   destroyed         = PRs that consumed CI and never merged (pure waste)
#
# READ THE MIX, NOT JUST THE NUMBER. A low FPY is only actionable once the
# failures are classified. In the 2026-08-09 baseline, of ~45 failures roughly:
#     2  real defects in the change        <- what CI is FOR
#    10  obligations discovered late       -> shift left (DOC-096)
#    11  false signals                     -> CREDIBLE-251, CREDIBLE-175
#     5  scope-blind detectors             -> CREDIBLE-237, CREDIBLE-239
# Under 5% of failures were the thing CI exists to catch. Chasing "fewer
# failures" without that split optimises the wrong term.
#
# THE BLIND SPOT, stated so nobody mistakes a green number for health: this
# metric can only see things that FAIL. The largest wins of that same session
# were invisible to it — mold installed but unwired for weeks (EFFECTIVE-396),
# operator-recall dead since 2026-05-08 with enabled=true, and a clean merge
# that nearly deleted `chump gap write-ac`. All are zero-defect states, because
# nothing was failing. Yield cannot see an instrument that stopped reporting.
#
# Usage:
#   bash scripts/ops/first-pass-yield.sh [--days 7] [--limit 40] [--json]
set -uo pipefail

DAYS=7
LIMIT=40
AS_JSON=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)  DAYS="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --json)  AS_JSON=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }

SINCE="$(date -u -v-"${DAYS}"d +%Y-%m-%d 2>/dev/null || date -u -d "${DAYS} days ago" +%Y-%m-%d)"

# Merged AND closed-unmerged both count: a PR that consumed CI and shipped
# nothing is the most expensive outcome, so excluding it would flatter the
# number exactly where it should hurt.
prs="$(gh pr list --state all --limit "$LIMIT" \
        --json number,headRefName,mergedAt,createdAt,files \
        --jq "[.[] | select(.createdAt >= \"${SINCE}\")]" 2>/dev/null)"

[[ -n "$prs" && "$prs" != "[]" ]] || { echo "no PRs since ${SINCE}"; exit 0; }

echo "$prs" | python3 -c '
import json, subprocess, sys

prs = json.load(sys.stdin)
rows = []
for pr in prs:
    br = pr.get("headRefName") or ""
    if not br:
        continue
    out = subprocess.run(
        ["gh","run","list","--branch",br,"--workflow=ci.yml","--limit","50",
         "--json","conclusion"],
        capture_output=True, text=True)
    try:
        runs = json.loads(out.stdout or "[]")
    except json.JSONDecodeError:
        runs = []
    if not runs:
        continue   # no CI ever ran; a trigger problem, not a yield one
    total  = len(runs)
    failed = sum(1 for r in runs if r.get("conclusion") == "failure")
    # Class the PR by what it touched. Doc-only has its own express lane, so
    # mixing it with code PRs hides the real code number.
    paths = [f.get("path","") for f in (pr.get("files") or [])]
    cls = "doc" if paths and all(p.endswith(".md") for p in paths) else "code"
    rows.append({
        "pr": pr["number"], "class": cls, "runs": total, "failed": failed,
        "first_pass": failed == 0,
        "merged": bool(pr.get("mergedAt")),
    })

if not rows:
    print("no PRs with CI runs in window"); sys.exit(0)

def block(label, rs):
    n = len(rs)
    if n == 0:
        return
    fp   = sum(1 for r in rs if r["first_pass"])
    runs = sum(r["runs"] for r in rs)
    dead = sum(1 for r in rs if not r["merged"])
    print(f"  {label:<6} PRs={n:<3} first-pass={fp}/{n} ({100*fp//n}%)  "
          f"runs={runs:<4} rework={runs/n:.1f}x  destroyed={dead}")

print(f"=== first-pass yield ({len(rows)} PRs with CI) ===")
block("ALL",  rows)
block("code", [r for r in rows if r["class"] == "code"])
block("doc",  [r for r in rows if r["class"] == "doc"])
print()
print("  worst offenders (most CI runs):")
for r in sorted(rows, key=lambda x: -x["runs"])[:5]:
    flag = "" if r["merged"] else "   <- DESTROYED, all of it waste"
    n, c, t, f = r["pr"], r["class"], r["runs"], r["failed"]
    print("    #%-6s %-5s runs=%-3s failed=%-3s%s" % (n, c, t, f, flag))
print()
print("  Read the MIX before acting: classify the failures into real defects /")
print("  late obligations / false signals / scope-blind detectors. In the")
print("  2026-08-09 baseline under 5% were real defects.")
'
