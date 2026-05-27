#!/usr/bin/env bash
# test-chump-staleness-gate.sh — INFRA-2054 (META-114 freshness cluster).
#
# Smoke contract:
#   1. `chump --build-info` exits 0 and stdout contains a valid SHA-like
#      string (40 hex chars or "unknown-no-git-context" sentinel).
#   2. `chump --build-info --json` parses as JSON and has the four expected
#      fields: sha, timestamp, rustc, workspace_root.
#   3. `chump self-check-staleness --threshold-age-s <HUGE> --threshold-commits <HUGE>`
#      → exit 0 + classification FRESH (permissive thresholds force FRESH).
#   4. `chump self-check-staleness --threshold-age-s 0 --threshold-commits 0`
#      → exit 1 or 2 (zero thresholds force non-FRESH).
#
# Phase 1 deliberately does NOT emit any ambient events — CHUMP_AMBIENT_DISABLE=1
# is set to belt-and-braces this; if the test ever finds new event kinds in
# the registry attributable to staleness, that's a regression.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

# Suppress ambient writes — Phase 1 is observation-free; this catches any
# accidental future regression that adds an event kind.
export CHUMP_AMBIENT_DISABLE=1

# Locate the chump binary; build to target/debug if not found.
CHUMP_BIN=""
for cand in \
    "$REPO_ROOT/target/debug/chump" \
    "$REPO_ROOT/target/release/chump" \
    "$HOME/.cargo/bin/chump"; do
    if [[ -x "$cand" ]]; then
        CHUMP_BIN="$cand"
        break
    fi
done
if [[ -z "$CHUMP_BIN" ]]; then
    info "chump binary not found; building..."
    (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --bin chump --quiet)
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
fi
info "using chump: $CHUMP_BIN"

# ── Test 1: --build-info exits 0 with non-empty embedded SHA ──────────────
set +e
out=$("$CHUMP_BIN" --build-info 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    fail "chump --build-info exited non-zero ($rc): $out"
fi
if ! echo "$out" | grep -qE '^  sha:[[:space:]]+([a-f0-9]{7,}|unknown-no-git-context)'; then
    fail "chump --build-info did not print a valid sha line; got: $out"
fi
pass "chump --build-info exit 0 with valid sha line"

# ── Test 2: --build-info --json parses as JSON, has 4 expected fields ─────
set +e
out=$("$CHUMP_BIN" --build-info --json 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    fail "chump --build-info --json exited non-zero ($rc): $out"
fi
# Use python3 to validate JSON + presence of all fields.
python3 - <<PY || fail "JSON parse / shape validation failed"
import json, sys
data = json.loads("""$out""")
for field in ("sha", "timestamp", "rustc", "workspace_root"):
    if field not in data:
        print(f"missing field: {field}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data[field], str) or not data[field]:
        print(f"field {field} is empty or not a string", file=sys.stderr)
        sys.exit(1)
PY
pass "chump --build-info --json parses as JSON with all 4 fields"

# ── Test 3: huge thresholds force FRESH (exit 0) ──────────────────────────
set +e
out=$("$CHUMP_BIN" self-check-staleness --threshold-age-s 99999999 --threshold-commits 999999 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    fail "huge-thresholds invocation exited $rc (expected 0=FRESH): $out"
fi
if ! echo "$out" | grep -q "staleness: FRESH"; then
    fail "expected 'staleness: FRESH' in output; got: $out"
fi
pass "huge thresholds → exit 0 + FRESH"

# ── Test 4: zero thresholds force non-FRESH (exit 1 or 2) ─────────────────
set +e
out=$("$CHUMP_BIN" self-check-staleness --threshold-age-s 0 --threshold-commits 0 2>&1)
rc=$?
set -e
if [[ $rc -ne 1 && $rc -ne 2 ]]; then
    fail "zero-thresholds invocation exited $rc (expected 1=STALE or 2=CRITICAL_STALE): $out"
fi
if ! echo "$out" | grep -qE "staleness: (STALE|CRITICAL_STALE)"; then
    fail "expected 'staleness: STALE' or 'staleness: CRITICAL_STALE' in output; got: $out"
fi
pass "zero thresholds → exit $rc + non-FRESH"

# ── Test 5: --json shape for self-check-staleness ─────────────────────────
set +e
out=$("$CHUMP_BIN" self-check-staleness --threshold-age-s 99999999 --threshold-commits 999999 --json 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    fail "JSON huge-thresholds invocation exited $rc: $out"
fi
python3 - <<PY || fail "self-check-staleness JSON shape validation failed"
import json, sys
data = json.loads("""$out""")
for field in (
    "build_age_s", "commits_behind", "build_sha", "local_head_sha",
    "classification", "threshold_age_s", "threshold_age_critical_s",
    "threshold_commits", "threshold_commits_critical", "reason"
):
    if field not in data:
        print(f"missing field: {field}", file=sys.stderr)
        sys.exit(1)
if data["classification"] != "fresh":
    print(f"expected classification=fresh, got {data['classification']}", file=sys.stderr)
    sys.exit(1)
PY
pass "chump self-check-staleness --json parses with expected shape"

info "all checks passed"
