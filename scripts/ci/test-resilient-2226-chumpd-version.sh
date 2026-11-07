#!/usr/bin/env bash
# RESILIENT-2226: chumpd --version/-V must exit fast and not kill live workers.
set -euo pipefail
cd "$(dirname "$0")/../.."
cargo build -q -p chumpd
BIN="$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')/debug/chumpd"
sleep 60 & FAKE=$!
trap 'kill $FAKE 2>/dev/null || true' EXIT
for flag in --version -V; do
    out="$(timeout 5 "$BIN" "$flag")" || { echo "FAIL: chumpd $flag did not exit 0 within 5s"; exit 1; }
    grep -qE '^chumpd [0-9.]+ \(' <<<"$out" || { echo "FAIL: bad output: $out"; exit 1; }
done
kill -0 "$FAKE" || { echo "FAIL: fake worker was killed"; exit 1; }
echo "PASS"
