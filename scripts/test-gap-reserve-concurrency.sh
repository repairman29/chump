#!/usr/bin/env bash
# Spawns parallel gap-reserve.sh INFRA calls with distinct CHUMP_SESSION_ID values
# under an isolated CHUMP_LOCK_DIR. Asserts all printed IDs are unique (INFRA-021).

set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_LOCK_DIR="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1

N="${1:-5}"
pids=()
for ((i = 1; i <= N; i++)); do
    (
        export CHUMP_SESSION_ID="gap-reserve-conc-${i}-$$"
        bash scripts/gap-reserve.sh INFRA "concurrency smoke $i" >"$TMP/id-$i.txt"
    ) &
    pids+=($!)
done
for p in "${pids[@]}"; do
    wait "$p"
done

uc="$(sort -u "$TMP"/id-*.txt | wc -l | tr -d '[:space:]')"
if [[ "$uc" != "$N" ]]; then
    echo "FAIL: expected $N unique IDs, got $uc (duplicates or missing output)" >&2
    sort "$TMP"/id-*.txt | uniq -c >&2 || true
    exit 1
fi

echo "OK: $N distinct INFRA-* reservations under isolated CHUMP_LOCK_DIR"
