#!/usr/bin/env bash
# test-storage-footprint-optimizer.sh — RESILIENT-323
# Proves the SENSE/LEARN/BUDGET/WRITE contract: growth + tight disk shrink
# the cap; the budget file's `:=`-assignments never clobber an explicit
# caller override; a stale/absent budget file is a harmless no-op for the
# reapers it feeds.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OPT="$REPO_ROOT/scripts/ops/storage-footprint-optimizer.sh"
fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

[[ -x "$OPT" ]] && pass "optimizer script exists + executable" || fail "not executable: $OPT"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/target" "$WORK/state"
AMB="$WORK/ambient.jsonl"
STATE="$WORK/state"
BUDGET="$STATE/storage-footprint-budget.env"
HIST="$STATE/storage-footprint-history.jsonl"

run_opt() {
  CHUMP_REPO="$WORK/repo" CHUMP_STATE_DIR="$STATE" CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_STORAGE_HISTORY_FILE="$HIST" CHUMP_STORAGE_BUDGET_FILE="$BUDGET" \
    bash "$OPT" "$@"
}

echo "== 1. first run writes a budget file + a history snapshot + emits storage_footprint_budget =="
: > "$AMB"; : > "$HIST"
dd if=/dev/zero of="$WORK/repo/target/blob" bs=1M count=3 >/dev/null 2>&1
run_opt >/dev/null
[[ -f "$BUDGET" ]] && pass "budget file written" || fail "budget file missing"
[[ -s "$HIST" ]] && pass "history snapshot appended" || fail "history not appended"
grep -q '"kind":"storage_footprint_budget"' "$AMB" && pass "emitted storage_footprint_budget" || fail "event not emitted"

echo "== 2. --dry-run never writes the budget file =="
rm -f "$BUDGET"
run_opt --dry-run >/dev/null
[[ ! -f "$BUDGET" ]] && pass "dry-run left no budget file" || fail "dry-run wrote a budget file"

echo "== 3. disk-aware ceiling: tiny free-disk fraction yields a small cap, never the 20000MB default =="
: > "$HIST"
CHUMP_REPO="$WORK/repo" CHUMP_STATE_DIR="$STATE" CHUMP_AMBIENT_LOG="$AMB" \
  CHUMP_STORAGE_HISTORY_FILE="$HIST" CHUMP_STORAGE_BUDGET_FILE="$BUDGET" \
  CHUMP_STORAGE_DISK_FRACTION="0.0001" bash "$OPT" >/dev/null
cap="$(grep -oE 'CHUMP_CARGO_TARGET_CAP_MB:=[0-9]+' "$BUDGET" | grep -oE '[0-9]+')"
if [[ -n "$cap" ]] && (( cap < 20000 )); then pass "disk-constrained cap ($cap MB) below the 20000MB fixed default"; else fail "cap not disk-constrained: got '$cap'"; fi

echo "== 4. an explicit caller env var always wins over the written budget (:= semantics) =="
CHUMP_CARGO_TARGET_CAP_MB=777 bash -c "source '$BUDGET'; echo \"resolved=\$CHUMP_CARGO_TARGET_CAP_MB\"" | grep -q 'resolved=777' \
  && pass "caller override survives sourcing the budget file" || fail "budget file clobbered caller override"

echo "== 5. an absent budget file is a harmless no-op when sourced by the reapers =="
rm -f "$BUDGET"
GC_OUT="$(CHUMP_STORAGE_BUDGET_FILE="$BUDGET" PATH="/usr/bin:/bin" HOME="$WORK" \
  CHUMP_AMBIENT_LOG="$WORK/gc-ambient.jsonl" CHUMP_REPO="$WORK/no-cargo-toml-here" \
  bash "$REPO_ROOT/scripts/ops/cargo-sweep-gc.sh" 2>&1)"
rc=$?
(( rc == 0 )) && pass "cargo-sweep-gc.sh tolerates a missing budget file (rc=0)" || fail "cargo-sweep-gc.sh should still exit 0, got $rc: $GC_OUT"

echo "== 6. scanner anchors + registry entries exist (verify-rule + honesty, INFRA-754) =="
grep -q '"kind":"storage_footprint_budget"' "$OPT" && pass "scanner anchor present in optimizer" || fail "scanner anchor missing"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q 'kind: storage_footprint_budget' "$REG" && pass "storage_footprint_budget registered" || fail "kind not registered in EVENT_REGISTRY.yaml"

echo "== 7. cargo-sweep-gc.sh and sccache-reaper.sh both source the adaptive budget file =="
grep -q 'CHUMP_STORAGE_BUDGET_FILE' "$REPO_ROOT/scripts/ops/cargo-sweep-gc.sh" \
  && pass "cargo-sweep-gc.sh sources the budget file" || fail "cargo-sweep-gc.sh does not source the budget file"
grep -q 'CHUMP_STORAGE_BUDGET_FILE' "$REPO_ROOT/scripts/coord/sccache-reaper.sh" \
  && pass "sccache-reaper.sh sources the budget file" || fail "sccache-reaper.sh does not source the budget file"

if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails check(s)" >&2
  exit 1
fi
echo "PASS: storage-footprint-optimizer"
