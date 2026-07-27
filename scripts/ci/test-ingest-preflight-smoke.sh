#!/usr/bin/env bash
# scripts/ci/test-ingest-preflight-smoke.sh — INFRA-1778
#
# Smoke test for `chump ingest-preflight <owner/repo|url|local-path>`.
# Asserts:
#   1. --help exits 0
#   2. missing arg exits 2
#   3. (when gh is authenticated) an unresolvable target fails permanently
#      (exit 1, failure_class=unresolvable_repo) and both
#      ingest_preflight_started / ingest_preflight_result ambient events fire
#
# Runs in <30s. Phase 3 makes zero network calls (unresolvable_repo is
# caught before any `gh repo view` call), but is gated on gh already being
# authenticated so this test doesn't require installing/logging into gh.

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
    if [[ -f "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump &>/dev/null; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "SKIP: chump binary not found (set CHUMP_BIN or run cargo build first)" >&2
        exit 0
    fi
fi

# See scripts/ci/test-ingest-smoke.sh for why CHUMP_REPO (not just
# CHUMP_HOME) must be overridden to keep this test's events out of the
# real fleet ambient stream.
AMBIENT_HOME=$(mktemp -d)
export CHUMP_REPO="$AMBIENT_HOME"
export CHUMP_HOME="$AMBIENT_HOME"
AMBIENT_LOG="$AMBIENT_HOME/.chump-locks/ambient.jsonl"

# ── Phase 0: binary present ──────────────────────────────────────────────
echo "── Phase 0: binary present ──"
[[ -x "$CHUMP_BIN" ]] && ok "chump binary executable at $CHUMP_BIN" || { fail "chump binary not executable"; exit 1; }

# ── Phase 1: --help exits 0 ──────────────────────────────────────────────
echo "── Phase 1: --help ──"
if "$CHUMP_BIN" ingest-preflight --help &>/dev/null; then
    ok "chump ingest-preflight --help exits 0"
else
    fail "chump ingest-preflight --help failed"
fi

# ── Phase 2: missing arg exits 2 ─────────────────────────────────────────
echo "── Phase 2: missing arg ──"
set +e
"$CHUMP_BIN" ingest-preflight &>/dev/null
rc=$?
set -e
if [[ "$rc" -eq 2 ]]; then
    ok "missing <target> exits 2"
else
    fail "missing <target> should exit 2, got $rc"
fi

# ── Phase 3: unresolvable target fails permanently + emits both events ──
echo "── Phase 3: unresolvable target ──"
# Mirror src/ingest_preflight.rs's gh_authenticated(): strip GH_TOKEN /
# GITHUB_TOKEN before checking, so a stale/explicit env token can't mask
# (or fake) gh's actual keyring auth state — same trap onboard.rs avoids.
if ! command -v gh &>/dev/null || ! env -u GH_TOKEN -u GITHUB_TOKEN gh auth status --hostname github.com &>/dev/null; then
    echo "SKIP: gh not installed or not authenticated in this environment" >&2
else
    set +e
    out=$("$CHUMP_BIN" ingest-preflight "this is not resolvable" 2>&1)
    rc=$?
    set -e
    if [[ "$rc" -eq 1 ]]; then
        ok "unresolvable target exits 1"
    else
        fail "unresolvable target should exit 1, got $rc (output: $out)"
    fi
    if grep -q '"failure_class":"unresolvable_repo"' "$AMBIENT_LOG" 2>/dev/null; then
        ok "ambient.jsonl has ingest_preflight_result failure_class=unresolvable_repo"
    else
        fail "ambient.jsonl missing failure_class=unresolvable_repo"
    fi
    if grep -q '"event":"ingest_preflight_started"' "$AMBIENT_LOG" 2>/dev/null; then
        ok "ambient.jsonl has ingest_preflight_started event"
    else
        fail "ambient.jsonl missing ingest_preflight_started event"
    fi
    if grep -q '"event":"ingest_preflight_result"' "$AMBIENT_LOG" 2>/dev/null; then
        ok "ambient.jsonl has ingest_preflight_result event"
    else
        fail "ambient.jsonl missing ingest_preflight_result event"
    fi
    if grep -q '"cost_usd":"0.00"' "$AMBIENT_LOG" 2>/dev/null; then
        ok "events report cost_usd=0.00"
    else
        fail "events missing cost_usd=0.00"
    fi
fi

rm -rf "$AMBIENT_HOME"

# ── Summary ───────────────────────────────────────────────────────────────
echo
echo "── Results: $PASS passed, $FAIL failed ──"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
