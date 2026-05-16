#!/usr/bin/env bash
# test-fleet-brief-worktree-ships.sh — INFRA-1355
#
# Verifies that `chump fleet brief` correctly reports ship counts when run
# from a linked git worktree (without CHUMP_REPO set).
#
# Before INFRA-1355: locks_dir was derived from repo_root() which returned
# current_dir() when CHUMP_REPO was unset, pointing at the worktree's sparse
# .chump-locks/ (3 files, no commit events) → Ships: 0.
#
# After INFRA-1355: locks_dir uses main_checkout_root() (via git-common-dir)
# which resolves to the main checkout → Ships: N (the synthetic events below).
#
# Test layout:
#   $TMP/main-repo/          ← main checkout (has .chump-locks/ambient.jsonl)
#   $TMP/linked-wt/          ← linked worktree (sparse .chump-locks/)
#
# Both reference the same git object store; git-common-dir from linked-wt
# returns $TMP/main-repo/.git, so main_checkout_root() = $TMP/main-repo.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# ── Locate chump binary ───────────────────────────────────────────────────────
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    for candidate in \
        "$REPO_ROOT/target/debug/chump" \
        "$REPO_ROOT/target/release/chump" \
        "$(command -v chump 2>/dev/null || true)"
    do
        if [[ -x "$candidate" ]]; then
            CHUMP_BIN="$candidate"
            break
        fi
    done
fi
if [[ -z "$CHUMP_BIN" ]]; then
    echo "SKIP: chump binary not found (run 'cargo build' first or set CHUMP_BIN=...)" >&2
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> INFRA-1355: fleet brief ships count from linked worktree"
echo "    chump: $CHUMP_BIN"
echo "    tmp:   $TMP"

# ── Build main repo with ambient events ──────────────────────────────────────
MAIN="$TMP/main-repo"
mkdir -p "$MAIN/scripts/dispatch" "$MAIN/.chump-locks" "$MAIN/.chump"

git -C "$MAIN" init -q
git -C "$MAIN" config user.email "ci@test"
git -C "$MAIN" config user.name "CI"
git -C "$MAIN" commit --allow-empty -q -m "init"

# Stub run-fleet.sh (needed by fleet subcommand init)
echo "#!/usr/bin/env bash" > "$MAIN/scripts/dispatch/run-fleet.sh"
chmod +x "$MAIN/scripts/dispatch/run-fleet.sh"

# Write 5 commit events into main's ambient.jsonl
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for i in 1 2 3 4 5; do
    printf '{"ts":"%s","event":"commit","gap_id":"TEST-%d","session":"s%d"}\n' \
        "$NOW" "$i" "$i" >> "$MAIN/.chump-locks/ambient.jsonl"
done

echo "    main ambient.jsonl: $(wc -l < "$MAIN/.chump-locks/ambient.jsonl") lines"

# ── Create linked worktree ────────────────────────────────────────────────────
WKTR="$TMP/linked-wt"
# Need a separate branch for the linked worktree
git -C "$MAIN" checkout -q -b infra-1355-wt-test 2>/dev/null || true
git -C "$MAIN" worktree add -q "$WKTR" -b infra-1355-wt-branch 2>/dev/null || \
    git -C "$MAIN" worktree add -q "$WKTR" infra-1355-wt-test

echo "    linked worktree: $WKTR"
echo "    git-common-dir from wt: $(git -C "$WKTR" rev-parse --git-common-dir 2>/dev/null || echo '(failed)')"

# Worktree gets a sparse .chump-locks/ with just throttle files (no events)
mkdir -p "$WKTR/.chump-locks"
touch "$WKTR/.chump-locks/.gh-throttle.lock"
# Write a single NON-commit event so the sparse file exists but ships=0 without fix
# Use a registered kind (fleet_health) to satisfy the event-registry pre-commit gate.
printf '{"ts":"%s","kind":"fleet_health","session":"wt-test"}\n' "$NOW" \
    >> "$WKTR/.chump-locks/ambient.jsonl"

echo "    worktree ambient.jsonl: $(wc -l < "$WKTR/.chump-locks/ambient.jsonl") line (no commit events)"

# ── Run fleet brief from the linked worktree (no CHUMP_REPO) ─────────────────
echo ""
echo "==> Running: chump fleet brief  (cwd=$WKTR, no CHUMP_REPO)"

OUTPUT="$(cd "$WKTR" && env -i \
    HOME="$HOME" \
    PATH="$PATH" \
    "$CHUMP_BIN" fleet brief 2>&1)"

echo "$OUTPUT"

# ── Assertions ───────────────────────────────────────────────────────────────
SHIPS="$(echo "$OUTPUT" | grep -E '^Ships:' | grep -oE '[0-9]+' | head -1 || echo 0)"
echo ""
echo "==> Extracted ships: $SHIPS  (expected >= 5)"

if [[ "${SHIPS:-0}" -lt 5 ]]; then
    echo "FAIL: ships=$SHIPS — expected >= 5 (INFRA-1355 fallback not working)" >&2
    echo "      The fleet brief still reads from the sparse worktree .chump-locks/" >&2
    exit 1
fi

# ── Control: verify main checkout gives same result ──────────────────────────
OUTPUT_MAIN="$(cd "$MAIN" && env -i \
    HOME="$HOME" \
    PATH="$PATH" \
    "$CHUMP_BIN" fleet brief 2>&1)"

SHIPS_MAIN="$(echo "$OUTPUT_MAIN" | grep -E '^Ships:' | grep -oE '[0-9]+' | head -1 || echo 0)"
echo "==> Control (main checkout): ships=$SHIPS_MAIN"

if [[ "${SHIPS_MAIN:-0}" -lt 5 ]]; then
    echo "FAIL: control ships=$SHIPS_MAIN — expected >= 5 (even main checkout broken)" >&2
    exit 1
fi

echo ""
echo "ALL CHECKS PASSED — INFRA-1355: fleet brief reports ships=$SHIPS from linked worktree"
