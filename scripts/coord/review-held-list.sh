#!/usr/bin/env bash
# scripts/coord/review-held-list.sh — CREDIBLE-1526 (PHASE-R R3 AC3): list open
# PRs held by independent review, with diff stat, for the SessionStart digest and
# `chump fleet brief`. Prints nothing when none are held. Never fails.
#   CHUMP_REVIEW_HELD_JSON=<file>  test hook: use this `gh pr list` JSON instead.
set -uo pipefail
GH_BIN="${GH_BIN:-gh}"
json=""
if [[ -n "${CHUMP_REVIEW_HELD_JSON:-}" ]]; then
    json="$(cat "$CHUMP_REVIEW_HELD_JSON" 2>/dev/null || true)"
else
    json="$(for l in review-held review-needs-mutants; do
        CHUMP_GH_CALL_CRITICALITY=background timeout 10 "$GH_BIN" pr list --state open --label "$l" \
            --json number,title,additions,deletions,changedFiles --limit 30 2>/dev/null
    done | python3 -c '
import json, sys
seen = {}
dec = json.JSONDecoder(); s = sys.stdin.read(); i = 0
while i < len(s):
    while i < len(s) and s[i].isspace(): i += 1
    if i >= len(s): break
    obj, i = dec.raw_decode(s, i)
    for p in obj: seen[p["number"]] = p
print(json.dumps(list(seen.values())))
' 2>/dev/null || true)"
fi
[[ -z "$json" ]] && exit 0
printf '%s' "$json" | python3 -c '
import json, sys
try:
    prs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not prs:
    sys.exit(0)
print("HELD by review (%d) — needs human approval, cannot merge:" % len(prs))
for p in sorted(prs, key=lambda p: p["number"]):
    print("  #%s %s (+%s/-%s, %s files)" % (p["number"], p["title"][:70], p.get("additions", "?"), p.get("deletions", "?"), p.get("changedFiles", "?")))
' 2>/dev/null
exit 0
