#!/usr/bin/env bash
# test-judgment-organ-redteam.sh — CREDIBLE-177
#
# Red-teams the AC-coverage judgment organ (src/pr_ac_coverage.rs
# check_coverage()) against a checked-in, versioned fixture set of known-bad
# submissions (stub-passes-as-done, meaningless-test, DoD-unmet-but-CI-green)
# plus a positive/negative control pair. Rides `cargo test`'s existing
# per-push cadence rather than inventing a separate schedule -- CI already
# runs this on every PR, a superset of ChumpBench's nightly cadence.
#
# Exit 0 = fixtures match their documented baseline (no drift).
# Exit 1 = drift detected -- emits kind=judgment_organ_redteam_regression
#          to ambient.jsonl, distinct from a normal ChumpBench lap failure,
#          before exiting non-zero.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

cd "$REPO_ROOT"

OUT="$(mktemp /tmp/chump-redteam-out.XXXXXX)"
trap 'rm -f "$OUT"' EXIT

if cargo test --bin chump pr_ac_coverage::redteam:: -- --nocapture >"$OUT" 2>&1; then
    echo "[PASS] judgment-organ redteam: fixtures match documented baseline"
    exit 0
fi

echo "[FAIL] judgment-organ redteam: baseline drift detected"
cat "$OUT"

mismatch_line="$(grep -m1 'baseline drift detected --' "$OUT" || true)"
fixtures="$(printf '%s' "$mismatch_line" | sed 's/.*baseline drift detected -- //')"
mismatch_count="$(printf '%s' "$fixtures" | tr ';' '\n' | grep -c . || echo 1)"

if [[ -n "${AMBIENT:-}" ]]; then
    mkdir -p "$(dirname "$AMBIENT")"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    esc_fixtures="$(printf '%s' "$fixtures" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '{"ts":"%s","kind":"judgment_organ_redteam_regression","mismatch_count":%s,"fixtures":"%s"}\n' \
        "$ts" "$mismatch_count" "$esc_fixtures" >> "$AMBIENT"
fi

exit 1
