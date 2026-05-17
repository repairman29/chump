#!/usr/bin/env bash
# scripts/ci/test-gap-reserve-auto-stages.sh — INFRA-1354
#
# Verifies that 'chump gap reserve' auto-stages docs/gaps/<ID>.yaml so it
# rides along on the next commit and doesn't orphan in-flight PRs.
#
# Scenarios:
#   1. reserve in a git dir with docs/gaps/ present → yaml exists + staged (A)
#   2. reserve with CHUMP_RESERVE_NO_AUTOSTAGE=1 → yaml exists but NOT staged
#   3. reserve when docs/gaps/ absent → no yaml, no error (no-op path)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$(dirname "$0")/lib/discover-chump-bin.sh"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$CHUMP_BIN" ]] || fail "no chump binary at $CHUMP_BIN (set CHUMP_BIN or cargo build first)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── set up a scratch git repo with docs/gaps/ ───────────────────────────────
SCRATCH="$TMP/scratch"
mkdir -p "$SCRATCH/docs/gaps" "$SCRATCH/.chump"
cd "$SCRATCH"
git init -q
git config user.email "ci@test.local"
git config user.name "CI Test"
touch "$SCRATCH/.chump/state.db"
# Create a minimal state.db so chump doesn't error
"$CHUMP_BIN" --chump-home "$SCRATCH/.chump" gap list --status open >/dev/null 2>&1 || true

# ── Test 1: normal reserve → yaml staged as A ───────────────────────────────
CHUMP_HOME="$SCRATCH/.chump" \
CHUMP_REPO="$SCRATCH" \
CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
CHUMP_RESERVE_NO_AUTOSTAGE="" \
FLEET_029_AMBIENT_GLANCE_SKIP=1 \
CHUMP_PILLAR_BALANCE_DISABLE=1 \
    "$CHUMP_BIN" gap reserve --domain TEST --title "INFRA-1354 autostage smoke" \
    --priority P2 --effort xs --skip-obs-acs \
    2>"$TMP/reserve1.stderr" >"$TMP/reserve1.stdout" \
    || fail "reserve failed unexpectedly (stderr: $(cat "$TMP/reserve1.stderr"))"

GAP_ID="$(cat "$TMP/reserve1.stdout" | tr -d '[:space:]')"
[[ -n "$GAP_ID" ]] || fail "no gap ID on stdout"

YAML_PATH="$SCRATCH/docs/gaps/${GAP_ID}.yaml"
[[ -f "$YAML_PATH" ]] || fail "yaml not written: $YAML_PATH"
ok "yaml written: $YAML_PATH"

# Check git status shows it as staged (A = added to index)
STATUS="$(cd "$SCRATCH" && git status --porcelain "$YAML_PATH" 2>/dev/null)"
[[ "$STATUS" == A* ]] \
    || fail "yaml not staged (git status: '$STATUS') — expected 'A '"
ok "yaml staged in git index (status: A)"

# Check stderr contains '[reserve] staged' message
grep -q "\[reserve\] staged" "$TMP/reserve1.stderr" \
    || fail "no '[reserve] staged' message in stderr (got: $(cat "$TMP/reserve1.stderr"))"
ok "'[reserve] staged' message emitted on stderr"

# ── Test 2: CHUMP_RESERVE_NO_AUTOSTAGE=1 → yaml written but NOT staged ──────
SCRATCH2="$TMP/scratch2"
mkdir -p "$SCRATCH2/docs/gaps" "$SCRATCH2/.chump"
cd "$SCRATCH2"
git init -q
git config user.email "ci@test.local"
git config user.name "CI Test"

CHUMP_HOME="$SCRATCH2/.chump" \
CHUMP_REPO="$SCRATCH2" \
CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
CHUMP_RESERVE_NO_AUTOSTAGE=1 \
FLEET_029_AMBIENT_GLANCE_SKIP=1 \
CHUMP_PILLAR_BALANCE_DISABLE=1 \
    "$CHUMP_BIN" gap reserve --domain TEST --title "INFRA-1354 no-autostage smoke" \
    --priority P2 --effort xs --skip-obs-acs \
    2>"$TMP/reserve2.stderr" >"$TMP/reserve2.stdout" \
    || fail "reserve2 failed unexpectedly (stderr: $(cat "$TMP/reserve2.stderr"))"

GAP_ID2="$(cat "$TMP/reserve2.stdout" | tr -d '[:space:]')"
YAML_PATH2="$SCRATCH2/docs/gaps/${GAP_ID2}.yaml"
[[ -f "$YAML_PATH2" ]] || fail "yaml2 not written: $YAML_PATH2"
ok "CHUMP_RESERVE_NO_AUTOSTAGE=1: yaml written"

STATUS2="$(cd "$SCRATCH2" && git status --porcelain "$YAML_PATH2" 2>/dev/null)"
# Should be '??' (untracked) not 'A '
[[ "$STATUS2" == "??"* ]] \
    || fail "yaml should be untracked with NO_AUTOSTAGE=1 (got: '$STATUS2')"
ok "CHUMP_RESERVE_NO_AUTOSTAGE=1: yaml NOT staged (untracked as expected)"

# ── Test 3: docs/gaps/ absent → no yaml, reserve succeeds ───────────────────
SCRATCH3="$TMP/scratch3"
mkdir -p "$SCRATCH3/.chump"
cd "$SCRATCH3"
git init -q
git config user.email "ci@test.local"
git config user.name "CI Test"
# NOTE: no docs/gaps/ directory

CHUMP_HOME="$SCRATCH3/.chump" \
CHUMP_REPO="$SCRATCH3" \
CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
FLEET_029_AMBIENT_GLANCE_SKIP=1 \
CHUMP_PILLAR_BALANCE_DISABLE=1 \
    "$CHUMP_BIN" gap reserve --domain TEST --title "INFRA-1354 no-dir smoke" \
    --priority P2 --effort xs --skip-obs-acs \
    >"$TMP/reserve3.stdout" 2>"$TMP/reserve3.stderr" \
    || fail "reserve3 failed (docs/gaps/ absent should be no-op, not error) (stderr: $(cat "$TMP/reserve3.stderr"))"

GAP_ID3="$(cat "$TMP/reserve3.stdout" | tr -d '[:space:]')"
[[ -n "$GAP_ID3" ]] || fail "no gap ID on stdout for no-dir case"
[[ ! -f "$SCRATCH3/docs/gaps/${GAP_ID3}.yaml" ]] \
    || fail "yaml should NOT exist when docs/gaps/ absent"
ok "docs/gaps/ absent: reserve succeeds, no yaml written (correct no-op)"

ok "ALL INFRA-1354 gap-reserve-auto-stages checks passed"
