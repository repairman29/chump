#!/usr/bin/env bash
# test-cargo-sweep-gc.sh — ZERO-WASTE-053
# Proves the steady-state GC's guards + honest reporting without touching a real
# target: cargo-sweep-absent → skip+emit; no Cargo.toml → skip+emit; and that a
# missing GC surfaces loudly rather than masquerading as a bounded target.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GC="$REPO_ROOT/scripts/ops/cargo-sweep-gc.sh"
fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

[[ -x "$GC" ]] && pass "GC script exists + executable" || fail "GC not executable: $GC"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
AMB="$WORK/ambient.jsonl"; : > "$AMB"

# ZERO-WASTE-054: cargo is checked FIRST (the launchd-env bug). FAKEBIN gives the
# later tests a resolvable cargo so they reach the check they mean to exercise.
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
mkcargo() { printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/cargo"; chmod +x "$FAKEBIN/cargo"; }

echo "== 1a. cargo NOT on PATH → skip cargo-not-found (ZERO-WASTE-054: the launchd bug) =="
: > "$AMB"
PATH="/usr/bin:/bin" HOME="$WORK" CHUMP_AMBIENT_LOG="$AMB" CHUMP_REPO="$WORK" bash "$GC" >/dev/null 2>&1
rc=$?
(( rc == 0 )) && pass "exits 0 when cargo absent" || fail "should exit 0, got $rc"
grep -q 'cargo-not-found' "$AMB" && pass "skipped with cargo-not-found (not a silent no-op)" || fail "must skip cargo-not-found"

echo "== 1b. cargo present but cargo-sweep absent → skip cargo-sweep-not-installed =="
: > "$AMB"; mkcargo
PATH="$FAKEBIN:/usr/bin:/bin" HOME="$WORK" CHUMP_AMBIENT_LOG="$AMB" CHUMP_REPO="$WORK" bash "$GC" >/dev/null 2>&1
grep -q 'cargo-sweep-not-installed' "$AMB" && pass "skip reason cargo-sweep-not-installed" || fail "skip reason missing"

echo "== 2. no Cargo.toml at repo → skip no-cargo-toml (cargo + cargo-sweep both 'present') =="
: > "$AMB"; mkcargo; printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/cargo-sweep"; chmod +x "$FAKEBIN/cargo-sweep"
PATH="$FAKEBIN:/usr/bin:/bin" HOME="$WORK" CHUMP_AMBIENT_LOG="$AMB" CHUMP_REPO="$WORK" bash "$GC" >/dev/null 2>&1
grep -q '"kind":"cargo_sweep_gc_skipped"' "$AMB" && grep -q 'no-cargo-toml' "$AMB" \
  && pass "no-Cargo.toml → skipped+reason" || fail "should skip with no-cargo-toml reason"

echo "== 3. the emit anchors + registry entries exist (verify-rule + honesty) =="
grep -q '"kind":"cargo_sweep_gc_ran"' "$GC" && grep -q '"kind":"cargo_sweep_gc_skipped"' "$GC" \
  && pass "scanner anchors present in GC" || fail "scanner anchors missing"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q 'kind: cargo_sweep_gc_ran' "$REG" && grep -q 'kind: cargo_sweep_gc_skipped' "$REG" \
  && pass "both kinds registered" || fail "kinds not registered in EVENT_REGISTRY.yaml"

echo "== 4. plist template is well-formed + points at the GC =="
PLIST="$REPO_ROOT/scripts/plists/dev.chump.cargo-sweep-gc.plist"
[[ -f "$PLIST" ]] && grep -q 'cargo-sweep-gc.sh' "$PLIST" && grep -q 'StartInterval' "$PLIST" \
  && pass "plist present, references the GC, has a timer" || fail "plist missing/malformed"

echo ""
if (( fails == 0 )); then echo "PASS test-cargo-sweep-gc"; exit 0
else echo "FAIL ($fails) test-cargo-sweep-gc"; exit 1; fi
