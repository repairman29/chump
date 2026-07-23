#!/usr/bin/env bash
# scripts/ci/test-ingest-preflight-smoke.sh — INFRA-1778
#
# Smoke test for `chump ingest-preflight <owner/repo|url|local-path>`
# (Column A safety rail). Asserts:
#   1. --help exits 0
#   2. missing arg exits 2
#   3. (when gh is authenticated) an unresolvable slug fails permanently
#      (exit 1) and emits both ingest_preflight_started and
#      ingest_preflight_result ambient events, with cost_usd=0.00.
#
# Runs in <30s. Phase 3 makes exactly one real `gh api` network call (to
# assert repo_not_found_or_no_access behavior on a slug that cannot exist);
# it is skipped entirely when gh is not authenticated in this environment.

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

# Point ambient log at a scratch (non-git) dir so this test's events don't
# land in the real fleet ambient stream (see test-ingest-smoke.sh precedent).
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

# ── Phase 3: unresolvable slug fails permanently (gh authenticated only) ─
echo "── Phase 3: unresolvable slug (requires gh auth) ──"
if gh auth status --hostname github.com &>/dev/null; then
    UNRESOLVABLE="chump-ingest-preflight-smoke-does-not-exist-$$/also-does-not-exist"
    set +e
    out=$("$CHUMP_BIN" ingest-preflight "$UNRESOLVABLE" 2>&1)
    rc=$?
    set -e
    if [[ "$rc" -eq 1 ]]; then
        ok "unresolvable slug exits 1 (permanent failure)"
    else
        fail "unresolvable slug should exit 1, got $rc (output: $out)"
    fi
    if grep -q '"ingest_preflight_started"' "$AMBIENT_LOG" 2>/dev/null; then
        ok "ambient.jsonl has ingest_preflight_started event"
    else
        fail "ambient.jsonl missing ingest_preflight_started event"
    fi
    if grep -q '"ingest_preflight_result"' "$AMBIENT_LOG" 2>/dev/null; then
        ok "ambient.jsonl has ingest_preflight_result event"
    else
        fail "ambient.jsonl missing ingest_preflight_result event"
    fi
    if grep -q '"cost_usd":"0.00"' "$AMBIENT_LOG" 2>/dev/null; then
        ok "ingest_preflight_result reports cost_usd=0.00"
    else
        fail "ingest_preflight_result missing cost_usd=0.00"
    fi
    if grep -q '"failure_class":"repo_not_found_or_no_access"' "$AMBIENT_LOG" 2>/dev/null; then
        ok "ambient.jsonl has failure_class=repo_not_found_or_no_access"
    else
        fail "ambient.jsonl missing failure_class=repo_not_found_or_no_access"
    fi
else
    echo "  SKIP: gh not authenticated in this environment — phase 3 skipped"
fi

rm -rf "$AMBIENT_HOME"

# ── Summary ───────────────────────────────────────────────────────────────
echo
echo "── Results: $PASS passed, $FAIL failed ──"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
