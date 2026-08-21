#!/usr/bin/env bash
# scripts/coord/gap-pattern-hold-check.sh — RESILIENT-365
#
# Symptom-cluster block: recurring-gap-pattern-detector.sh (INFRA-249) files
# a META RCA gap for a keyword cluster and writes a hold record to
# pattern-detector-hold.json. This helper checks a candidate gap TITLE
# against active holds — if the title matches a held keyword and does not
# reference the RCA gap id, the caller should stop and link to the RCA gap
# instead of shipping the 44th symptom.
#
# Usage:
#   scripts/coord/gap-pattern-hold-check.sh "<title>"
#     exit 0  — no held keyword matches; proceed normally
#     exit 2  — title matches a held keyword and does not reference the RCA
#               gap id; caller should block/warn (prints the RCA gap + advisory)
#
#   scripts/coord/gap-pattern-hold-check.sh --json "<title>"
#     always exits 0; prints {"blocked":bool,"keyword":...,"rca_gap":...}
#
# To proceed anyway, reference the RCA gap id in the title (e.g. append
# "(see META-9001)") — that's the resolve path, not an env-var bypass; see
# INFRA-2429 zero-bypass thesis on why no CHUMP_*_SKIP escape hatch exists
# here.
#
# Env:
#   CHUMP_PATTERN_DETECTOR_HOLD=<path>  # override hold file path (tests)

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HOLD_FILE="${CHUMP_PATTERN_DETECTOR_HOLD:-$REPO_ROOT/.chump-locks/pattern-detector-hold.json}"
FORMAT=text

if [[ "${1:-}" == "--json" ]]; then
    FORMAT=json
    shift
fi

TITLE="${1:-}"

if [[ ! -f "$HOLD_FILE" ]] || [[ -z "$TITLE" ]]; then
    [[ "$FORMAT" == "json" ]] && echo '{"blocked":false}'
    exit 0
fi

python3 - "$HOLD_FILE" "$TITLE" "$FORMAT" <<'PY'
import json, re, sys

hold_path, title, fmt = sys.argv[1:4]
try:
    h = json.load(open(hold_path))
except Exception:
    h = {}
holds = h.get("holds", {})

title_lc = title.lower()
match_kw = None
match = None
for kw, rec in holds.items():
    if re.search(r'\b' + re.escape(kw) + r'\b', title_lc):
        match_kw = kw
        match = rec
        break

if match is None:
    if fmt == "json":
        print(json.dumps({"blocked": False}))
    sys.exit(0)

rca_gap = match.get("rca_gap", "")
# Already links to the RCA gap in the title (e.g. filing the RCA itself, or
# a sub-gap that cites it) — don't block.
if rca_gap and rca_gap in title:
    if fmt == "json":
        print(json.dumps({"blocked": False, "keyword": match_kw, "rca_gap": rca_gap}))
    sys.exit(0)

if fmt == "json":
    print(json.dumps({
        "blocked": True,
        "keyword": match_kw,
        "rca_gap": rca_gap,
        "advisory": match.get("advisory", ""),
    }))
    sys.exit(0)

print(f"[gap-pattern-hold] BLOCKED: title matches held keyword \"{match_kw}\"", file=sys.stderr)
print(f"[gap-pattern-hold]   RCA gap: {rca_gap}", file=sys.stderr)
print(f"[gap-pattern-hold]   {match.get('advisory', '')}", file=sys.stderr)
print(f"[gap-pattern-hold]   Reference {rca_gap} (e.g. via --title mentioning it, or depends_on) instead of filing another symptom.", file=sys.stderr)
sys.exit(2)
PY
exit $?
