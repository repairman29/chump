#!/usr/bin/env bash
# Smoke test for pr-shepherd-daemon (META-181 skeleton + META-183 classification).
# Asserts: (a) script is executable, (b) --help exits 0, (c) tick exits 0,
# (d) at least one pr_shepherd_tick event is appended to ambient.jsonl,
# (e) the tick event has open_pr_count,
# (f) META-183: pr_classified events emitted with required fields.

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

# (d) at least one event appended (tick + potentially N pr_classified)
[[ "$after" -gt "$before" ]] || { echo "[test] FAIL: no event appended"; exit 1; }

# Extract newly appended lines since 'before'
new_lines=$(tail -n +"$((before + 1))" "$AMBIENT")

# (e) pr_shepherd_tick event exists with open_pr_count
echo "$new_lines" | grep -q '"kind":"pr_shepherd_tick"' || { echo "[test] FAIL: no pr_shepherd_tick event"; exit 1; }
echo "$new_lines" | grep '"kind":"pr_shepherd_tick"' | grep -q '"open_pr_count":' || { echo "[test] FAIL: tick missing open_pr_count"; exit 1; }

# (f) META-183: if any pr_classified events emitted, verify required fields
classified_count=$(echo "$new_lines" | grep -c '"kind":"pr_classified"' || true)
if [[ "$classified_count" -gt 0 ]]; then
  # Check first pr_classified has all required fields
  first_classified=$(echo "$new_lines" | grep '"kind":"pr_classified"' | head -1)
  echo "$first_classified" | grep -q '"pr":' || { echo "[test] FAIL: pr_classified missing pr field"; exit 1; }
  echo "$first_classified" | grep -q '"classification":' || { echo "[test] FAIL: pr_classified missing classification field"; exit 1; }
  echo "$first_classified" | grep -q '"gap_id":' || { echo "[test] FAIL: pr_classified missing gap_id field"; exit 1; }
  echo "$first_classified" | grep -q '"age_minutes":' || { echo "[test] FAIL: pr_classified missing age_minutes field"; exit 1; }
  echo "$first_classified" | grep -q '"dry_run":true' || { echo "[test] FAIL: pr_classified missing dry_run=true"; exit 1; }
  # Validate classification is one of the 6 known states
  classification=$(echo "$first_classified" | python3 -c "import json,sys; print(json.load(sys.stdin)['classification'])")
  case "$classification" in
    BEHIND|MERGEABLE|ARMED|DIRTY|BLOCKED|UNKNOWN) ;;
    *) echo "[test] FAIL: unknown classification '$classification'"; exit 1 ;;
  esac
fi

echo "[test-pr-shepherd-daemon] PASS (tick + ${classified_count} pr_classified events)"
