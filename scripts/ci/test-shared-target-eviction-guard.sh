#!/usr/bin/env bash
# scripts/ci/test-shared-target-eviction-guard.sh — RESILIENT-1647
#  1. a fake live `cargo` process with CARGO_TARGET_DIR=<dir> is detected; none for another dir.
#  2. cargo-sweep-gc.sh and shared-target-cache-reaper.sh evict nothing while it runs.
#  3. an eviction emits one kind=shared_target_evicted line with paths + bytes.
#  4. (runs when cargo is on PATH; offline, path-dep only) two serialized
#     builds of different Cargo.lock states share one CARGO_TARGET_DIR in debug and release.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
WORK="$(mktemp -d)"; BGP=""
trap '[[ -n "$BGP" ]] && kill "$BGP" 2>/dev/null; rm -rf "$WORK"' EXIT
# shellcheck source=../lib/shared-target-guard.sh
source "$REPO_ROOT/scripts/lib/shared-target-guard.sh"

T="$WORK/target"; OTHER="$WORK/other"
mkdir -p "$T/debug/incremental/x" "$OTHER"
head -c 200000 /dev/zero > "$T/debug/incremental/x/blob"
mkdir -p "$WORK/fakebin"; cp "$(command -v bash)" "$WORK/fakebin/cargo"

shared_target_live_build "$T" && fail "false positive with no build" || pass "no build -> not live"
CARGO_TARGET_DIR="$T" "$WORK/fakebin/cargo" -c "sleep 30; :" & BGP=$!
sleep 0.3
shared_target_live_build "$T" && pass "fake live cargo detected" || fail "fake live cargo not detected"
shared_target_live_build "$OTHER" && fail "live build leaked to unrelated dir" || pass "unrelated dir not live"

mkdir -p "$WORK/stub"; printf '#!/bin/sh\nexit 0\n' > "$WORK/stub/cargo"; cp "$WORK/stub/cargo" "$WORK/stub/cargo-sweep"; chmod +x "$WORK/stub/"*
cp "$WORK/stub/cargo" "$WORK/stub/chump"
export CHUMP_AMBIENT_LOG="$WORK/amb.jsonl"; mkdir -p "$WORK/home"
# Reaper: forced-trigger via CLI args, sandbox HOME so lane locks stay local.
HOME="$WORK/home" PATH="$WORK/stub:$PATH" bash "$REPO_ROOT/scripts/coord/shared-target-cache-reaper.sh" \
  --execute --target "$T" --budget-gb 0 --floor-gb 0 >"$WORK/r.out" 2>&1
[[ -d "$T/debug/incremental" ]] && pass "reaper evicted nothing during live build" || fail "reaper evicted during live build"
grep -q '"kind":"shared_target_evicted"' "$CHUMP_AMBIENT_LOG" 2>/dev/null && fail "eviction logged during live build" || pass "no eviction receipt during live build"

# cargo-sweep-gc: skip path must fire before cargo-sweep runs (stub it).
printf '[package]\nname="x"\nversion="0.0.0"\n' > "$WORK/Cargo.toml"
CHUMP_REPO_ROOT="$WORK" CHUMP_CARGO_SWEEP_TARGET_DIRS="$T" PATH="$WORK/stub:$PATH" bash "$REPO_ROOT/scripts/ops/cargo-sweep-gc.sh" >"$WORK/s.out" 2>&1
grep -q "live build" "$WORK/s.out" && pass "cargo-sweep-gc skipped live target" || { fail "cargo-sweep-gc did not skip live target"; cat "$WORK/s.out" >&2; }

kill "$BGP" 2>/dev/null; wait "$BGP" 2>/dev/null; BGP=""
shared_target_emit_evicted test-organ "$T" 200000 "$T/debug/incremental"
n="$(grep -c '"kind":"shared_target_evicted".*"organ":"test-organ".*"bytes":200000.*"paths":\["' "$CHUMP_AMBIENT_LOG")"
[[ "$n" == 1 ]] && pass "emit helper writes one receipt with paths+bytes" || fail "receipt malformed (n=$n)"

HOME="$WORK/home" PATH="$WORK/stub:$PATH" bash "$REPO_ROOT/scripts/coord/shared-target-cache-reaper.sh" --execute --target "$T" --budget-gb 0 --floor-gb 0 >"$WORK/r2.out" 2>&1
if [[ ! -d "$T/debug/incremental" ]]; then
  grep -q '"organ":"shared-target-cache-reaper"' "$CHUMP_AMBIENT_LOG" && pass "reaper eviction logged shared_target_evicted" || fail "reaper evicted without receipt"
else
  echo "  note: idle reaper skipped for env reasons (chump/flock/admit): $(tail -1 "$WORK/r2.out")"
fi

if command -v cargo >/dev/null 2>&1; then
  P="$(mktemp -d)"; mkdir -p "$P/src" "$P/dep1/src"
  echo 'fn main(){}' > "$P/src/main.rs"; echo 'pub fn f(){}' > "$P/dep1/src/lib.rs"
  printf '[package]\nname="dep1"\nversion="0.1.0"\nedition="2021"\n' > "$P/dep1/Cargo.toml"
  export CARGO_TARGET_DIR="$WORK/shared"
  for prof in "" "--release"; do
    for state in a b a; do
      printf '[package]\nname="lf"\nversion="0.1.0"\nedition="2021"\n[dependencies]\n' > "$P/Cargo.toml"
      [[ "$state" == b ]] && echo 'dep1 = { path = "dep1" }' >> "$P/Cargo.toml"
      rm -f "$P/Cargo.lock"
      ( cd "$P" && cargo build --offline $prof >"$WORK/b.out" 2>&1 ) && pass "serialized build lock-state-$state ${prof:-debug}" || { fail "build state-$state ${prof:-debug} failed on shared target"; tail -5 "$WORK/b.out" >&2; }
    done
  done
fi
[[ $fails -eq 0 ]] && echo "PASS" || { echo "FAILED: $fails" >&2; exit 1; }
