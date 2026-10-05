#!/usr/bin/env bash
# scripts/ci/test-ingest-orchestrate-smoke.sh — INFRA-1784
#
# Smoke test for `chump ingest <repo-path> --confirm-mutations` (INFRA-1746
# phase 5: orchestration + takeover certificate + auto-gaps).
# Asserts:
#   1. non-existent path + --confirm-mutations exits 1, ingest_failed
#      failure_class=path_not_found (phase-1a validation runs first, so
#      orchestration never starts)
#   2. valid fixture repo + --confirm-mutations exits 0, writes
#      certificate.json + proposed-gaps.json, and emits
#      ingest_orchestrate_started + ingest_complete with
#      total_cost_usd_cents=0
#   3. ingest_complete reports phases_completed=[librarian, cartographer,
#      evangelist, systematizer] and prs_attempted=0
#
# Runs in <30s, no network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# ── Locate chump binary ──────────────────────────────────────────────────
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/debug/chump" ]]; then
        CHUMP_BIN="$CARGO_TARGET_DIR/debug/chump"
    elif [[ -f "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump &>/dev/null; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "SKIP: chump binary not found (set CHUMP_BIN or run cargo build first)" >&2
        exit 0
    fi
fi

# Isolate ambient writes from the real .chump-locks/ambient.jsonl — see
# test-ingest-smoke.sh for why both CHUMP_REPO and CHUMP_HOME must be set.
AMBIENT_HOME=$(mktemp -d)
export CHUMP_REPO="$AMBIENT_HOME"
export CHUMP_HOME="$AMBIENT_HOME"
AMBIENT_LOG="$AMBIENT_HOME/.chump-locks/ambient.jsonl"

echo "── Phase 0: binary present ──"
[[ -x "$CHUMP_BIN" ]] && ok "chump binary executable at $CHUMP_BIN" || { fail "chump binary not executable"; exit 1; }

# ── Phase 1: non-existent path + --confirm-mutations exits 1 ────────────
echo "── Phase 1: non-existent path ──"
NONEXISTENT="/tmp/chump-ingest-orchestrate-smoke-does-not-exist-$$"
rm -rf "$NONEXISTENT"
set +e
out=$("$CHUMP_BIN" ingest "$NONEXISTENT" --confirm-mutations 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 1 ]]; then
    ok "non-existent path + --confirm-mutations exits 1"
else
    fail "non-existent path should exit 1, got $rc (output: $out)"
fi
if grep -q '"failure_class":"path_not_found"' "$AMBIENT_LOG" 2>/dev/null; then
    ok "ambient.jsonl has ingest_failed failure_class=path_not_found (phase-1a gate, orchestration never starts)"
else
    fail "ambient.jsonl missing failure_class=path_not_found"
fi
if grep -q '"kind":"ingest_orchestrate_started"' "$AMBIENT_LOG" 2>/dev/null; then
    fail "ingest_orchestrate_started should NOT fire when phase-1a validation fails first"
else
    ok "ingest_orchestrate_started correctly did not fire"
fi

# ── Phase 2: valid fixture repo + --confirm-mutations exits 0 ───────────
echo "── Phase 2: valid fixture repo, full orchestration ──"
FIXTURE=$(mktemp -d)
git -C "$FIXTURE" init -q
mkdir -p "$FIXTURE/src"
echo 'fn main() {}' > "$FIXTURE/src/main.rs"
git -C "$FIXTURE" add src/main.rs
git -C "$FIXTURE" -c user.email=test@test.com -c user.name=test commit -q -m "init"

set +e
out=$("$CHUMP_BIN" ingest "$FIXTURE" --confirm-mutations 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    ok "valid fixture repo + --confirm-mutations exits 0"
else
    fail "valid fixture repo should exit 0, got $rc (output: $out)"
fi

if [[ -f "$FIXTURE/.chump-ingest/certificate.json" ]]; then
    ok "certificate.json written"
else
    fail "certificate.json was not written"
fi
if [[ -f "$FIXTURE/.chump-ingest/proposed-gaps.json" ]]; then
    ok "proposed-gaps.json written"
else
    fail "proposed-gaps.json was not written"
fi

if grep -q '"kind":"ingest_orchestrate_started"' "$AMBIENT_LOG" 2>/dev/null; then
    ok "ambient.jsonl has ingest_orchestrate_started event"
else
    fail "ambient.jsonl missing ingest_orchestrate_started event"
fi
if grep -q '"kind":"ingest_complete"' "$AMBIENT_LOG" 2>/dev/null; then
    ok "ambient.jsonl has ingest_complete event"
else
    fail "ambient.jsonl missing ingest_complete event"
fi

# ── Phase 3: ingest_complete field contract ──────────────────────────────
echo "── Phase 3: ingest_complete field contract ──"
COMPLETE_LINE=$(grep '"kind":"ingest_complete"' "$AMBIENT_LOG" 2>/dev/null || true)
if [[ -n "$COMPLETE_LINE" ]]; then
    if echo "$COMPLETE_LINE" | grep -q '"total_cost_usd_cents":0'; then
        ok "ingest_complete reports total_cost_usd_cents=0"
    else
        fail "ingest_complete missing total_cost_usd_cents=0"
    fi
    if echo "$COMPLETE_LINE" | grep -q '"prs_attempted":0'; then
        ok "ingest_complete reports prs_attempted=0 (auto-PR deferred past v1)"
    else
        fail "ingest_complete missing prs_attempted=0"
    fi
    for phase in librarian cartographer evangelist systematizer; do
        if echo "$COMPLETE_LINE" | grep -q "\"$phase\""; then
            ok "ingest_complete phases_completed includes $phase"
        else
            fail "ingest_complete phases_completed missing $phase"
        fi
    done
else
    fail "no ingest_complete line found to inspect"
fi

rm -rf "$FIXTURE" "$AMBIENT_HOME"

# ── Summary ───────────────────────────────────────────────────────────────
echo
echo "── Results: $PASS passed, $FAIL failed ──"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
