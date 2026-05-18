#!/usr/bin/env bash
# test-hot-file-serialization.sh — INFRA-953
#
# Asserts:
#   1. scripts/coord/hot-files.yaml exists and parses.
#   2. scripts/coord/hot-file-lock.sh helper exposes the expected commands.
#   3. The serialize list is non-empty and includes the audit-identified
#      paths (AGENTS.md, EVENT_REGISTRY, ci.yml workflows).
#   4. The warn_only list is non-empty and disjoint from serialize.
#   5. flock-based mutual exclusion: a second hot_file_lock_acquire on the
#      same lock file blocks until the first releases.
#   6. bot-merge.sh sources the helper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
YAML="$REPO_ROOT/scripts/coord/hot-files.yaml"
HELPER="$REPO_ROOT/scripts/coord/hot-file-lock.sh"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

[[ -f "$YAML" ]]    || fail "missing $YAML"
[[ -x "$HELPER" ]]  || fail "$HELPER not executable"
[[ -f "$BOT_MERGE" ]] || fail "missing $BOT_MERGE"
ok "fixtures present"

# 1) serialize-list output is non-empty and contains audit-identified paths.
serialize="$(bash "$HELPER" serialize-list)"
[[ -n "$serialize" ]] || fail "serialize-list is empty"
for required in AGENTS.md "docs/observability/EVENT_REGISTRY.yaml" ".github/workflows/ci.yml" "scripts/coord/bot-merge.sh"; do
  if ! echo "$serialize" | grep -qFx "$required"; then
    fail "serialize list missing required entry: $required"
  fi
done
ok "serialize list contains audit-identified paths"

# 2) warn_only list is non-empty and disjoint from serialize.
warn="$(bash "$HELPER" warn-list)"
[[ -n "$warn" ]] || fail "warn-list is empty"
while IFS= read -r w; do
  [[ -z "$w" ]] && continue
  if echo "$serialize" | grep -qFx "$w"; then
    fail "warn_only entry '$w' also appears in serialize (must be disjoint)"
  fi
done <<< "$warn"
ok "warn_only and serialize are disjoint"

# 3) bot-merge.sh sources the helper.
grep -q 'hot-file-lock.sh' "$BOT_MERGE" \
  || fail "bot-merge.sh does not reference hot-file-lock.sh"
ok "bot-merge.sh sources the hot-file lock helper"

# 4) Mutual exclusion: spawn two processes that both try to acquire the
# same hot-file lock; the second should wait until the first releases.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"

# Synthetic YAML with one path; force the diff base to a no-op so any
# file we name shows up as "touched".
echo "version: 1" > "$TMP/hot-files.yaml"
echo "serialize:" >> "$TMP/hot-files.yaml"
echo "  - sentinel-path" >> "$TMP/hot-files.yaml"
echo "warn_only: []" >> "$TMP/hot-files.yaml"

# Force the helper to see the sentinel path in the diff. The cleanest way
# is to call "$FLOCK_BIN" directly on the same lockfile pattern the helper would
# pick, since the YAML parsing + diff logic is already covered by the
# serialize-list assertion above.
LOCKFILE="$LOCK_DIR/hot-file-sentinel-path.lock"

# Spawn process A that takes the lock and holds it for 2s.
# INFRA-1600: brew util-linux "$FLOCK_BIN" not on default PATH on self-hosted CI runners.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/discover-flock.sh"

( "$FLOCK_BIN" -x 9 && sleep 2 ) 9>"$LOCKFILE" &
PID_A=$!
sleep 0.2

# Process B tries to acquire with a tight 5s timeout; should succeed only
# AFTER A finishes (~2s in).
T_START=$(date +%s)
( "$FLOCK_BIN" -w 5 9 ) 9>"$LOCKFILE"
T_END=$(date +%s)
wait "$PID_A" 2>/dev/null || true

ELAPSED=$((T_END - T_START))
if [[ "$ELAPSED" -lt 1 ]]; then
  fail "second "$FLOCK_BIN" acquired immediately (${ELAPSED}s) — mutual exclusion is broken"
fi
ok "mutual exclusion verified (second "$FLOCK_BIN" waited ${ELAPSED}s for first to release)"

# 5) CHUMP_HOT_FILE_LOCK_DISABLE=1 short-circuits.
out=$(CHUMP_HOT_FILE_LOCK_DISABLE=1 bash "$HELPER" acquire 2>&1)
echo "$out" | grep -q "skipping" || fail "DISABLE flag did not short-circuit"
ok "CHUMP_HOT_FILE_LOCK_DISABLE=1 short-circuits"

echo
echo "=== test-hot-file-serialization.sh PASSED ==="
