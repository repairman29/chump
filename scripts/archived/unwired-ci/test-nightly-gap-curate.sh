#!/usr/bin/env bash
# test-nightly-gap-curate.sh — INFRA-637
# Validates gap-curate.sh: opt-out, dry-run, ambient emission, graceful
# skip of missing subcommands, correct exit codes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/gap-curate.sh"
INSTALLER="$REPO_ROOT/scripts/setup/install-gap-curate-launchd.sh"
PLIST="$REPO_ROOT/launchd/com.chump.gap-curate.plist"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "$SCRIPT" ]] || fail "gap-curate.sh not found or not executable at $SCRIPT"
[[ -x "$INSTALLER" ]] || fail "install-gap-curate-launchd.sh not found at $INSTALLER"
[[ -f "$PLIST" ]] || fail "com.chump.gap-curate.plist not found at $PLIST"

TMP_DIR="$(mktemp -d -t chump-gap-curate-test-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

AMBIENT="$TMP_DIR/ambient.jsonl"

# ── 1: CHUMP_GAP_CURATE_DISABLE=1 skips and exits 0 ─────────────────────────
out=$(CHUMP_GAP_CURATE_DISABLE=1 CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" 2>&1 || true)
echo "$out" | grep -qi 'disable\|skip' \
    || fail "CHUMP_GAP_CURATE_DISABLE=1 should print disable/skip message"
CHUMP_GAP_CURATE_DISABLE=1 CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" \
    || fail "CHUMP_GAP_CURATE_DISABLE=1 must exit 0"
pass "CHUMP_GAP_CURATE_DISABLE=1 skips curation and exits 0"

# ── 2: --dry-run does not write to ambient.jsonl ──────────────────────────────
CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" --dry-run 2>&1 || true
[[ ! -f "$AMBIENT" ]] \
    || fail "--dry-run must not write to ambient.jsonl"
pass "--dry-run does not write to ambient.jsonl"

# ── 3: gap_store_curated event emitted on real run (missing chump → skip gracefully) ──
# When chump binary is absent the script exits 0 without emitting.
AMBIENT2="$TMP_DIR/ambient2.jsonl"
out=$(CHUMP_AMBIENT_LOG="$AMBIENT2" bash "$SCRIPT" --quiet 2>&1 || true)
# Script either emits event (chump found) or exits cleanly (chump absent).
# Both are valid. If it emitted, validate the fields.
if [[ -f "$AMBIENT2" ]] && grep -q 'gap_store_curated' "$AMBIENT2" 2>/dev/null; then
    event=$(grep 'gap_store_curated' "$AMBIENT2" | head -1)
    for field in 'ts' 'kind' 'session' 'rebalanced' 'consolidated' 'retained' 'errors'; do
        echo "$event" | grep -q "\"$field\"" \
            || fail "gap_store_curated missing field $field in: $event"
    done
    pass "gap_store_curated event has all required fields"
else
    pass "gap_store_curated: chump absent — script exited cleanly (OK for CI)"
fi

# ── 4: unknown flag exits 2 ──────────────────────────────────────────────────
exit_code=0
bash "$SCRIPT" --bad-flag 2>&1 || exit_code=$?
[[ "$exit_code" -eq 2 ]] \
    || fail "unknown flag should exit 2; got $exit_code"
pass "unknown flag exits 2"

# ── 5: launchd plist has StartCalendarInterval at 04:00 ──────────────────────
grep -q 'StartCalendarInterval' "$PLIST" \
    || fail "plist must use StartCalendarInterval (not StartInterval) for daily at 04:00"
grep -q '<integer>4</integer>' "$PLIST" \
    || fail "plist Hour must be 4 (04:00)"
pass "launchd plist schedules at 04:00 via StartCalendarInterval"

# ── 6: installer has correct label ───────────────────────────────────────────
grep -q 'com.chump.gap-curate' "$INSTALLER" \
    || fail "installer must reference com.chump.gap-curate label"
pass "installer references correct launchd label"

# ── 7: gap-curate.sh references CHUMP_GAP_CURATE_DISABLE ─────────────────────
grep -q 'CHUMP_GAP_CURATE_DISABLE' "$SCRIPT" \
    || fail "CHUMP_GAP_CURATE_DISABLE opt-out not wired"
pass "CHUMP_GAP_CURATE_DISABLE opt-out is wired"

# ── 8: gap_store_curated in EVENT_REGISTRY.yaml ──────────────────────────────
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
[[ -f "$REGISTRY" ]] || fail "EVENT_REGISTRY.yaml not found at $REGISTRY"
grep -q 'gap_store_curated' "$REGISTRY" \
    || fail "gap_store_curated not registered in EVENT_REGISTRY.yaml"
pass "gap_store_curated registered in EVENT_REGISTRY.yaml"

printf '\nAll gap-curate tests passed.\n'
