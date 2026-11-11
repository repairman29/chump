#!/usr/bin/env bash
# RESILIENT-1647: (1) no eviction while a live cargo owns the target dir,
# (2) eviction receipts are emitted, (3) two serialized builds of different
# Cargo.lock states share one CARGO_TARGET_DIR in debug and release.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/lib/shared-target-guard.sh"
T="$(mktemp -d)"; trap 'kill $FAKE_PID 2>/dev/null; rm -rf "$T"' EXIT
FAIL=0; ok(){ echo "ok - $1"; }; bad(){ echo "FAIL - $1"; FAIL=1; }
AMB="$T/ambient.jsonl"; : > "$AMB"; export CHUMP_AMBIENT_LOG="$AMB"

# 1. fake live cargo bound to TARGET
TARGET="$T/shared"; mkdir -p "$TARGET/release/incremental/x" "$TARGET/release/.fingerprint/a"
mkdir -p "$T/fakebin"; cp "$(command -v bash)" "$T/fakebin/cargo"
CARGO_TARGET_DIR="$TARGET" "$T/fakebin/cargo" -c 'read -t 60 <> <(:)' & FAKE_PID=$!
sleep 0.3
if st_live_build "$TARGET"; then ok "live cargo on target detected"; else bad "live cargo not detected"; fi
if st_live_build "$T/other"; then bad "unrelated target flagged live"; else ok "unrelated target not flagged"; fi

# reaper under a live build must evict nothing
HOME_SB="$T/home"; mkdir -p "$HOME_SB/.chump"
HOME="$HOME_SB" CHUMP_AMBIENT_LOG="$AMB" bash "$ROOT/scripts/coord/shared-target-cache-reaper.sh" \
  --execute --target "$TARGET" --floor-gb 99999 --budget-gb 0 >/dev/null 2>&1
[[ -d "$TARGET/release/incremental/x" ]] && ok "no eviction during live build" || bad "evicted during live build"
grep -q shared_target_evicted "$AMB" && bad "eviction receipt during live build" || ok "no receipt during live build"

# disk-critical-reactor-style guard + cargo-sweep-gc skip
kill $FAKE_PID 2>/dev/null; wait $FAKE_PID 2>/dev/null
st_live_build "$TARGET" && bad "dead cargo still live" || ok "guard releases after cargo exits"

# 2. receipt emitted on a real eviction
st_emit_evicted test-actor "$TARGET/release/incremental" 4096 "$AMB"
grep -q '"kind":"shared_target_evicted".*"bytes":4096' "$AMB" && ok "receipt format" || bad "receipt missing"

# 3. two serialized lockfile states, debug + release, one shared target
if command -v cargo >/dev/null 2>&1; then
  mk() { # <dir> <dep-version>
    mkdir -p "$1/dep/src" "$1/app/src"
    cat > "$1/Cargo.toml" <<TOML
[workspace]
members = ["app", "dep"]
resolver = "2"
TOML
    printf '[package]\nname="dep"\nversion="%s"\nedition="2021"\n' "$2" > "$1/dep/Cargo.toml"
    echo 'pub fn f()->u32{1}' > "$1/dep/src/lib.rs"
    printf '[package]\nname="app"\nversion="0.1.0"\nedition="2021"\nbuild="build.rs"\n[dependencies]\ndep={path="../dep"}\n' > "$1/app/Cargo.toml"
    echo 'fn main(){}' > "$1/app/build.rs"
    echo 'fn main(){ println!("{}", dep::f()); }' > "$1/app/src/main.rs"
  }
  mk "$T/A" 0.1.0; mk "$T/B" 0.2.0
  SHARED="$T/cargo-shared"
  for prof in "" "--release"; do
    for st in A B; do
      if (cd "$T/$st" && CARGO_TARGET_DIR="$SHARED" cargo build --offline $prof >/dev/null 2>&1); then
        ok "build $st ${prof:-debug}"
      else bad "build $st ${prof:-debug}"; fi
    done
  done
else echo "skip - cargo absent"; fi
exit $FAIL
