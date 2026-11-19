#!/usr/bin/env bash
# test-almanac-zero-hits.sh — EFFECTIVE-380
#
# Smoke test for scripts/dev/almanac-zero-hits.py: proves the clustering +
# three-way classification actually discriminates (sql -> unsupported,
# swift -> unsupported, a real in-checkout phrase -> retrieval-miss with
# non-empty evidence, a made-up phrase -> absent) rather than always
# reporting one bucket.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

TMP_LOG="$(mktemp -t almanac-zero-hits-fixture.XXXXXX.jsonl)"
trap 'rm -f "$TMP_LOG"' EXIT

python3 - "$TMP_LOG" <<'PYEOF'
import json
import sys

path = sys.argv[1]
records = [
    # unsupported-artifact / sql
    {"ts": "2026-08-06T09:00:00+00:00", "surface": "cli", "tool": "search",
     "repo": "chump", "query": "sql migration that adds the gaps table schema",
     "hits": 0, "mode": "keyword", "duration_ms": 10},
    # unsupported-artifact / language
    {"ts": "2026-08-06T09:05:00+00:00", "surface": "mcp", "tool": "almanac_search",
     "repo": "maclawd", "query": "gap importer written in swift for the ios client",
     "hits": 0, "mode": "fusion", "duration_ms": 10},
    # retrieval-miss: this checkout has real content matching >= 2 of these
    # distinctive tokens within a few lines of each other (e.g. the
    # MISSION-045 outcome-gate keystone comment in
    # crates/chump-preflight/src/preflight.rs), so this is a genuine
    # quality-bug example, not a hand-waved one.
    {"ts": "2026-08-06T09:10:00+00:00", "surface": "cli", "tool": "search",
     "repo": "chump", "query": "MISSION-045 anti-bloat outcome gate keystone",
     "hits": 0, "mode": "keyword", "duration_ms": 10},
    # absent: a concept this repo has no content on.
    {"ts": "2026-08-06T09:15:00+00:00", "surface": "cli", "tool": "search",
     "repo": "chump", "query": "xylophone quokka farming subsidy apparatus",
     "hits": 0, "mode": "keyword", "duration_ms": 10},
    # a real hit, to prove zero_hit_rate isn't just "all calls".
    {"ts": "2026-08-06T09:20:00+00:00", "surface": "cli", "tool": "search",
     "repo": "chump", "query": "how does chump claim a gap", "hits": 4,
     "mode": "fusion", "duration_ms": 200},
]
with open(path, "w") as f:
    for r in records:
        f.write(json.dumps(r) + "\n")
PYEOF

OUT="$(python3 scripts/dev/almanac-zero-hits.py --log "$TMP_LOG" --days 3650 --json)"

echo "$OUT" | python3 -c "import json,sys; json.load(sys.stdin)" \
  || { echo "FAIL: --json output is not valid JSON"; exit 1; }

TOTAL=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_calls'])")
ZERO=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['zero_hit_calls'])")
[ "$TOTAL" -eq 5 ] || { echo "FAIL: expected 5 total_calls, got $TOTAL"; exit 1; }
[ "$ZERO" -eq 4 ] || { echo "FAIL: expected 4 zero_hit_calls, got $ZERO"; exit 1; }

CAUSES=$(echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(','.join(sorted(t['cause'] for t in d['themes'])))
")
echo "causes: $CAUSES"

echo "$CAUSES" | grep -q "unsupported-artifact" \
  || { echo "FAIL: expected an unsupported-artifact cluster (sql/swift), got: $CAUSES"; exit 1; }

RETRIEVAL_COUNT=$(echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(sum(1 for t in d['themes'] if t['cause'] == 'retrieval-miss'))
")
[ "$RETRIEVAL_COUNT" -ge 1 ] || { echo "FAIL: expected at least one retrieval-miss cluster"; exit 1; }

EVIDENCE_COUNT=$(echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rm = [t for t in d['themes'] if t['cause'] == 'retrieval-miss']
print(sum(len(t['evidence']) for t in rm))
")
[ "$EVIDENCE_COUNT" -ge 1 ] || { echo "FAIL: retrieval-miss cluster(s) carried no evidence — AC3 requires a provable example"; exit 1; }

echo "$CAUSES" | grep -q "absent" \
  || { echo "FAIL: expected an absent cluster (xylophone/quokka query), got: $CAUSES"; exit 1; }

echo "PASS: almanac-zero-hits.py clusters, discriminates all three causes, and cites verifiable evidence for retrieval-miss"

# Determinism: same fixture, same result — the token-set is a Python `set`
# (hash-randomized iteration order), so a non-deterministic tie-break in
# candidate selection would make this test flaky.
OUT2="$(python3 scripts/dev/almanac-zero-hits.py --log "$TMP_LOG" --days 3650 --json)"
if [ "$OUT" != "$OUT2" ]; then
  echo "FAIL: two runs over the same fixture produced different output — non-deterministic clustering/classification"
  exit 1
fi
echo "PASS: output is deterministic across repeated runs"

# Empty log: must not crash, must report zero honestly.
EMPTY_LOG="$(mktemp -t almanac-zero-hits-empty.XXXXXX.jsonl)"
EMPTY_OUT="$(python3 scripts/dev/almanac-zero-hits.py --log "$EMPTY_LOG" --json)"
rm -f "$EMPTY_LOG"
EMPTY_TOTAL=$(echo "$EMPTY_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_calls'])")
[ "$EMPTY_TOTAL" -eq 0 ] || { echo "FAIL: missing log should report 0 calls, got $EMPTY_TOTAL"; exit 1; }
echo "PASS: missing/empty log handled without crashing"
