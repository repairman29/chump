#!/usr/bin/env bash
# RESILIENT-2226: chumpd --version must exit fast and never kill a live worker.
set -euo pipefail
cd "$(dirname "$0")/../.."
cargo build -q -p chumpd
BIN="${CARGO_TARGET_DIR:-target}/debug/chumpd"
bash -c 'exec -a "dispatch/worker.sh fake" sleep 60' &
W=$!
sleep 0.3
for f in --version -V; do
    out="$(timeout 5 "$BIN" "$f" </dev/null)" || { echo "FAIL: chumpd $f did not exit 0 in 5s"; kill $W; exit 1; }
    echo "$out" | grep -qE '^chumpd [0-9.]+ \([a-z0-9]+\)$' || { echo "FAIL: bad output: $out"; kill $W; exit 1; }
done
kill -0 $W 2>/dev/null || { echo "FAIL: fake worker was killed"; exit 1; }
kill $W
echo "PASS"
