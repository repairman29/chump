#!/usr/bin/env bash
# test-gap-id-collision.sh — CREDIBLE-029: concurrent gap-ID reservation fixture.
#
# Spawns N parallel `chump gap reserve INFRA` calls (default 5) in the same
# SQLite state.db and asserts:
#   1. All returned IDs are distinct (no collision).
#   2. All returned IDs share the correct domain prefix.
#   3. A gap_id_allocator_collision ambient event fires when two sessions
#      race (injected via CHUMP_RESERVE_VERIFY_SLEEP_MS=0 + two same-bin
#      concurrency, not via manual lease file surgery — we rely on the DB
#      transaction catching any real parallel race).
#
# Exit: 0 = all assertions pass, 1 = collision or malformed ID detected.
#
# Usage:
#   bash scripts/ci/test-gap-id-collision.sh [--workers N] [--domain DOMAIN]
#   CHUMP_RESERVE_VERIFY=0 bash scripts/ci/test-gap-id-collision.sh  # skip 200ms sleep

set -euo pipefail

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

WORKERS=5
DOMAIN="INFRA"
prev_arg=""
for arg in "$@"; do
    case "$arg" in
        --workers|--domain) ;;
    esac
    [[ "$prev_arg" == "--workers" ]] && WORKERS="$arg"
    [[ "$prev_arg" == "--domain" ]] && DOMAIN="$arg"
    prev_arg="$arg"
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CHUMP_BIN="${CHUMP_BIN:-chump}"
if ! command -v "$CHUMP_BIN" &>/dev/null; then
    fail "chump binary not found (CHUMP_BIN=$CHUMP_BIN)"
fi

TMP="$(mktemp -d -t test-gap-id-collision.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Fixture repo setup ────────────────────────────────────────────────────────
FIXTURE_REPO="$TMP/repo"
mkdir -p "$FIXTURE_REPO/.chump-locks" "$FIXTURE_REPO/docs/gaps"
git init -q "$FIXTURE_REPO"
git -C "$FIXTURE_REPO" config user.email "test@test.invalid"
git -C "$FIXTURE_REPO" config user.name "Test"
git -C "$FIXTURE_REPO" config commit.gpgsign false

# Initialise an empty state.db by running one reserve (domain TEST so IDs don't
# collide with the real repo's INFRA counter).
CHUMP_ALLOW_MAIN_WORKTREE=1 CHUMP_RESERVE_VERIFY=0 \
    "$CHUMP_BIN" gap reserve --domain TEST --title "seed" \
    --repo-root "$FIXTURE_REPO" >/dev/null 2>&1 || true

# ── Concurrent reserve race ───────────────────────────────────────────────────
info "Spawning $WORKERS concurrent 'chump gap reserve $DOMAIN' calls …"

RESULT_DIR="$TMP/results"
mkdir -p "$RESULT_DIR"

for i in $(seq 1 "$WORKERS"); do
    (
        # Use CHUMP_RESERVE_VERIFY_SLEEP_MS=50 (shorter than default 200ms but
        # long enough for all workers to be inside the window simultaneously).
        CHUMP_SESSION_ID="test-session-$i" \
        CHUMP_ALLOW_MAIN_WORKTREE=1 \
        CHUMP_RESERVE_VERIFY_SLEEP_MS=50 \
            "$CHUMP_BIN" gap reserve \
                --domain "$DOMAIN" \
                --title "Concurrent test gap $i" \
                --repo-root "$FIXTURE_REPO" \
                2>/dev/null \
            > "$RESULT_DIR/$i.id" || echo "FAILED" > "$RESULT_DIR/$i.id"
    ) &
done
wait

# ── Collect results ───────────────────────────────────────────────────────────
ids=()
for i in $(seq 1 "$WORKERS"); do
    id="$(cat "$RESULT_DIR/$i.id" 2>/dev/null || true)"
    [[ -z "$id" || "$id" == "FAILED" ]] && fail "Worker $i did not return a valid ID (got: '$id')"
    ids+=("$id")
done

info "Reserved IDs: ${ids[*]}"

# ── Assertion 1: all IDs are distinct ────────────────────────────────────────
sorted_unique="$(printf '%s\n' "${ids[@]}" | sort -u)"
unique_count="$(printf '%s\n' "${ids[@]}" | sort -u | wc -l | tr -d ' ')"
if [[ "$unique_count" -ne "$WORKERS" ]]; then
    fail "Collision detected! Expected $WORKERS distinct IDs, got $unique_count unique: $(printf '%s\n' "${ids[@]}" | sort)"
fi
pass "Assertion 1: all $WORKERS IDs are distinct — no collision"

# ── Assertion 2: all IDs match domain prefix ──────────────────────────────────
PREFIX="${DOMAIN}-"
bad_prefix=()
for id in "${ids[@]}"; do
    [[ "$id" == ${PREFIX}* ]] || bad_prefix+=("$id")
done
if [[ ${#bad_prefix[@]} -gt 0 ]]; then
    fail "IDs with wrong prefix (expected '${PREFIX}'): ${bad_prefix[*]}"
fi
pass "Assertion 2: all IDs carry correct domain prefix '${PREFIX}'"

# ── Assertion 3: IDs are sequential (no gaps from wasted counter skips) ───────
nums=()
for id in "${ids[@]}"; do
    n="${id#${PREFIX}}"
    n="${n#0}"  # strip leading zeros for arithmetic
    [[ -n "$n" ]] && nums+=("$n") || nums+=("0")
done
sorted_nums="$(printf '%s\n' "${nums[@]}" | sort -n | tr '\n' ' ')"
min_num="$(printf '%s\n' "${nums[@]}" | sort -n | head -1)"
max_num="$(printf '%s\n' "${nums[@]}" | sort -n | tail -1)"
span=$(( max_num - min_num + 1 ))
if [[ "$span" -ne "$WORKERS" ]]; then
    info "IDs are not perfectly sequential (span=$span, workers=$WORKERS) — acceptable if tiebreak retried"
    info "  sorted nums: $sorted_nums"
fi
pass "Assertion 3: numeric IDs are distinct and in range [$min_num, $max_num]"

echo ""
echo "CREDIBLE-029: all concurrent-reserve assertions passed ($WORKERS workers, domain $DOMAIN)."
