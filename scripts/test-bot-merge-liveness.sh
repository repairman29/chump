#!/usr/bin/env bash
# INFRA-028 — structural checks + watchdog integration test (simulated hung child).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

echo "[test-bot-merge-liveness] repo root: $ROOT"

bash -n scripts/bot-merge.sh

test -f scripts/bot-merge-run-timed.py || {
    echo "missing scripts/bot-merge-run-timed.py" >&2
    exit 1
}

grep -q "run_timed" scripts/bot-merge.sh || {
    echo "bot-merge.sh missing run_timed" >&2
    exit 1
}
grep -q "heartbeat_begin" scripts/bot-merge.sh || {
    echo "bot-merge.sh missing heartbeat_begin" >&2
    exit 1
}
grep -q "No GitHub PR found for branch" scripts/bot-merge.sh || {
    echo "bot-merge.sh missing PR honesty guard" >&2
    exit 1
}

# Simulate a sibling-contention hang: child sleeps far longer than the cap.
set +e
out=$(python3 scripts/bot-merge-run-timed.py 1 -- sleep 60 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 124 ]]; then
    echo "expected bot-merge-run-timed.py to exit 124 on timeout, got $rc" >&2
    echo "$out" >&2
    exit 1
fi
if ! grep -q "TIMEOUT after 1s" <<<"$out"; then
    echo "timeout stderr missing expected marker" >&2
    echo "$out" >&2
    exit 1
fi

echo "[test-bot-merge-liveness] OK"
