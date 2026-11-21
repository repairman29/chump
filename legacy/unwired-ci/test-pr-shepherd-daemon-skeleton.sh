#!/usr/bin/env bash
# Smoke test for pr-shepherd-daemon skeleton (META-181).
# Asserts: (a) script is executable, (b) --help exits 0, (c) tick exits 0,
# (d) one pr_shepherd_tick event is appended to ambient.jsonl, (e) the event has open_pr_count.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/pr-shepherd-daemon.sh"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

# (a) executable
[[ -x "$DAEMON" ]] || { echo "[test] FAIL: daemon not executable"; exit 1; }

# (b) --help
"$DAEMON" --help >/dev/null || { echo "[test] FAIL: --help non-zero"; exit 1; }

# (c) tick (use DRY_RUN to avoid spamming real gh calls if available; tick still emits event)
mkdir -p "$(dirname "$AMBIENT")"
before=$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)
CHUMP_PR_SHEPHERD_DRY_RUN=1 "$DAEMON" tick || { echo "[test] FAIL: tick non-zero"; exit 1; }
after=$(wc -l < "$AMBIENT")

# (d) event appended
[[ "$after" -gt "$before" ]] || { echo "[test] FAIL: no event appended"; exit 1; }

# (e) event has expected shape
tail -1 "$AMBIENT" | grep -q '"kind":"pr_shepherd_tick"' || { echo "[test] FAIL: wrong kind"; exit 1; }
tail -1 "$AMBIENT" | grep -q '"open_pr_count":' || { echo "[test] FAIL: no count"; exit 1; }

echo "[test-pr-shepherd-daemon-skeleton] PASS (canonical test: scripts/ci/test-pr-shepherd-daemon.sh)"
