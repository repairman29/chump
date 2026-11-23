#!/usr/bin/env bash
# test-almanac-census.sh — EFFECTIVE-391
#
# Smoke test for scripts/dev/almanac-census.py against the retry probe
# fixture (scripts/dev/fixtures/almanac-census-retry-example.json), the
# same case cited in the gap: RetryService copied verbatim across 3 repos,
# RetryPatterns extracted into smugglers/shared-utils/ but never adopted by
# bulwark, and 5 total literal-copy sites out of 16.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

FIXTURE="scripts/dev/fixtures/almanac-census-retry-example.json"
[ -f "$FIXTURE" ] || { echo "FAIL: fixture missing: $FIXTURE"; exit 1; }

OUT="$(python3 scripts/dev/almanac-census.py "retry exponential backoff" --fixture "$FIXTURE" --json)"

echo "$OUT" | python3 -c "import json,sys; json.load(sys.stdin)" \
  || { echo "FAIL: --json output is not valid JSON"; exit 1; }

TOTAL_SITES=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_sites'])")
[ "$TOTAL_SITES" -eq 16 ] || { echo "FAIL: expected 16 total_sites, got $TOTAL_SITES"; exit 1; }

COPY_SITES=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_literal_copy_sites'])")
[ "$COPY_SITES" -eq 5 ] || { echo "FAIL: expected 5 literal-copy sites (AC's '5 of them literal copies'), got $COPY_SITES"; exit 1; }

# AC2: the three RetryService sites must be flagged as a verbatim copy group.
RETRY_SERVICE_TIER=$(echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
row = next(r for r in d['capabilities'] if r['symbol'] == 'RetryService')
assert row['site_count'] == 3, row
assert len(row['copy_groups']) == 1, row
print(row['copy_groups'][0]['tier'])
")
[ "$RETRY_SERVICE_TIER" = "verbatim" ] || { echo "FAIL: RetryService copy group should be tier=verbatim, got $RETRY_SERVICE_TIER"; exit 1; }

# AC2: bulwark/smugglers RetryPatterns must be flagged as a copy despite
# different paths (the gap's other named example).
RETRY_PATTERNS_TIER=$(echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
row = next(r for r in d['capabilities'] if r['symbol'] == 'RetryPatterns')
assert row['site_count'] == 2, row
assert len(row['copy_groups']) == 1, row
print(row['copy_groups'][0]['tier'])
")
[ "$RETRY_PATTERNS_TIER" = "moved" ] || { echo "FAIL: RetryPatterns copy group should be tier=moved (same symbol+line, different path), got $RETRY_PATTERNS_TIER"; exit 1; }

# AC4: existing extraction must be named, with the non-adopting repo listed.
EXISTING=$(echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
row = next(r for r in d['capabilities'] if r['symbol'] == 'RetryPatterns')
print(row['existing_extraction']['message'])
")
echo "$EXISTING" | grep -q "shared-utils/retry-patterns" \
  || { echo "FAIL: existing_extraction message missing the shared-utils site: $EXISTING"; exit 1; }
echo "$EXISTING" | grep -q "bulwark" \
  || { echo "FAIL: existing_extraction message missing the non-adopting repo (bulwark): $EXISTING"; exit 1; }

# AC3: RetryHelper's fixture site is missing importer_count/has_tests on
# purpose — the cluster must report unscored with the exact missing inputs
# named, never a score computed on partial data.
RETRYHELPER=$(echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
row = next(r for r in d['capabilities'] if r['symbol'] == 'RetryHelper')
ex = row['extractability']
assert ex['score'] is None, ex
print(','.join(ex['unavailable_inputs']))
")
echo "$RETRYHELPER" | grep -q "importer_count" || { echo "FAIL: expected importer_count in unavailable_inputs, got: $RETRYHELPER"; exit 1; }
echo "$RETRYHELPER" | grep -q "test_presence" || { echo "FAIL: expected test_presence in unavailable_inputs, got: $RETRYHELPER"; exit 1; }

# AC3: a cluster with all three inputs present must produce a real score.
RETRYSERVICE_SCORE=$(echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
row = next(r for r in d['capabilities'] if r['symbol'] == 'RetryService')
print(row['extractability']['score'])
")
[ "$RETRYSERVICE_SCORE" != "None" ] || { echo "FAIL: RetryService has full inputs, expected a numeric score, got None"; exit 1; }

# AC5: retrieval mode + vocabulary warning must be present and honest.
MODE=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['retrieval_mode'])")
[ "$MODE" = "fixture" ] || { echo "FAIL: expected retrieval_mode=fixture, got $MODE"; exit 1; }
echo "$OUT" | python3 -c "import json,sys; assert 'keyword mode only finds shared-vocabulary' in json.load(sys.stdin)['vocabulary_warning']" \
  || { echo "FAIL: vocabulary_warning missing the keyword-mode caveat (AC5)"; exit 1; }

# retry_with_backoff appears at two different lines (beast-mode, code-roach)
# under the same symbol name: same capability row, but NOT a copy — proves
# the tool distinguishes "independently written under the same name" from
# structural identity instead of flagging every same-symbol cluster as copied.
INDEPENDENT=$(echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
row = next(r for r in d['capabilities'] if r['symbol'] == 'retry_with_backoff')
assert row['site_count'] == 2, row
print(len(row['copy_groups']))
")
[ "$INDEPENDENT" -eq 0 ] || { echo "FAIL: retry_with_backoff sites are at different lines, should not be flagged as copies"; exit 1; }

echo "PASS: almanac-census.py reproduces the retry probe census — 5 literal copies, existing extraction named, extractability honest about missing inputs, vocabulary caveat present"

# Determinism.
OUT2="$(python3 scripts/dev/almanac-census.py "retry exponential backoff" --fixture "$FIXTURE" --json)"
if [ "$OUT" != "$OUT2" ]; then
  echo "FAIL: two runs over the same fixture produced different output — non-deterministic clustering"
  exit 1
fi
echo "PASS: output is deterministic across repeated runs"

# Missing binary must degrade honestly, not crash.
UNAVAILABLE_OUT="$(python3 scripts/dev/almanac-census.py "some concept" --almanac-bin /nonexistent/almanac-binary --json)"
UNAVAILABLE_MODE=$(echo "$UNAVAILABLE_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['retrieval_mode'])")
[ "$UNAVAILABLE_MODE" = "unavailable" ] || { echo "FAIL: expected retrieval_mode=unavailable when binary is absent, got $UNAVAILABLE_MODE"; exit 1; }
echo "PASS: missing almanac binary handled without crashing, reported honestly as unavailable (not a zero-hit)"
