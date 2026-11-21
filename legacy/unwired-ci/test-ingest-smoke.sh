#!/usr/bin/env bash
# scripts/ci/test-ingest-smoke.sh — INFRA-1780
#
# Smoke test for `chump ingest <repo-path>` (INFRA-1746 phase 1a).
# Asserts:
#   1. --help exits 0
#   2. missing arg exits 2
#   3. non-existent path exits 1 with failure_class=path_not_found
#   4. non-git dir exits 1 with failure_class=not_a_git_repo
#   5. valid git repo exits 0 with zero filesystem mutation
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
    if [[ -f "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump &>/dev/null; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "SKIP: chump binary not found (set CHUMP_BIN or run cargo build first)" >&2
        exit 0
    fi
fi

# chump's Rust ambient_emit::emit() resolves the ambient log via
# CHUMP_REPO (checked before CHUMP_HOME) / CHUMP_HOME (falling back to
# `git rev-parse`) rather than a CHUMP_AMBIENT_LOG override, so point
# CHUMP_REPO at a scratch (non-git) dir to keep this test's events out of
# the real fleet ambient stream. CHUMP_REPO is commonly already set in the
# fleet session env, so it must be overridden (not just CHUMP_HOME).
AMBIENT_HOME=$(mktemp -d)
export CHUMP_REPO="$AMBIENT_HOME"
export CHUMP_HOME="$AMBIENT_HOME"
AMBIENT_LOG="$AMBIENT_HOME/.chump-locks/ambient.jsonl"

# ── Phase 0: binary present ──────────────────────────────────────────────
echo "── Phase 0: binary present ──"
[[ -x "$CHUMP_BIN" ]] && ok "chump binary executable at $CHUMP_BIN" || { fail "chump binary not executable"; exit 1; }

# ── Phase 1: --help exits 0 ──────────────────────────────────────────────
echo "── Phase 1: --help ──"
if "$CHUMP_BIN" ingest --help &>/dev/null; then
    ok "chump ingest --help exits 0"
else
    fail "chump ingest --help failed"
fi

# ── Phase 2: missing arg exits 2 ─────────────────────────────────────────
echo "── Phase 2: missing arg ──"
set +e
"$CHUMP_BIN" ingest &>/dev/null
rc=$?
set -e
if [[ "$rc" -eq 2 ]]; then
    ok "missing <repo-path> exits 2"
else
    fail "missing <repo-path> should exit 2, got $rc"
fi

# ── Phase 3: non-existent path exits 1, failure_class=path_not_found ────
echo "── Phase 3: non-existent path ──"
NONEXISTENT="/tmp/chump-ingest-smoke-does-not-exist-$$"
rm -rf "$NONEXISTENT"
set +e
out=$("$CHUMP_BIN" ingest "$NONEXISTENT" 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 1 ]]; then
    ok "non-existent path exits 1"
else
    fail "non-existent path should exit 1, got $rc (output: $out)"
fi
if grep -q '"failure_class":"path_not_found"' "$AMBIENT_LOG" 2>/dev/null; then
    ok "ambient.jsonl has ingest_failed failure_class=path_not_found"
else
    fail "ambient.jsonl missing failure_class=path_not_found"
fi

# ── Phase 4: non-git dir exits 1, failure_class=not_a_git_repo ──────────
echo "── Phase 4: non-git dir ──"
NONGIT_DIR=$(mktemp -d)
echo "not a repo" > "$NONGIT_DIR/file.txt"
set +e
out=$("$CHUMP_BIN" ingest "$NONGIT_DIR" 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 1 ]]; then
    ok "non-git dir exits 1"
else
    fail "non-git dir should exit 1, got $rc (output: $out)"
fi
if grep -q '"failure_class":"not_a_git_repo"' "$AMBIENT_LOG" 2>/dev/null; then
    ok "ambient.jsonl has ingest_failed failure_class=not_a_git_repo"
else
    fail "ambient.jsonl missing failure_class=not_a_git_repo"
fi
rm -rf "$NONGIT_DIR"

# ── Phase 5: valid git repo exits 0, zero filesystem mutation ───────────
echo "── Phase 5: valid git repo ──"
VALID_DIR=$(mktemp -d)
git -C "$VALID_DIR" init -q
echo "hello" > "$VALID_DIR/README.md"
git -C "$VALID_DIR" add README.md
git -C "$VALID_DIR" -c user.email=test@test.com -c user.name=test commit -q -m "init"

# Snapshot the tree (mtimes + content hashes) before running ingest.
before=$(find "$VALID_DIR" -type f -exec sha256sum {} \; | sort)
before_status=$(git -C "$VALID_DIR" status --porcelain)

set +e
out=$("$CHUMP_BIN" ingest "$VALID_DIR" 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    ok "valid git repo exits 0"
else
    fail "valid git repo should exit 0, got $rc (output: $out)"
fi

after=$(find "$VALID_DIR" -type f -exec sha256sum {} \; | sort)
after_status=$(git -C "$VALID_DIR" status --porcelain)
if [[ "$before" == "$after" ]]; then
    ok "no filesystem mutation (file content hashes unchanged)"
else
    fail "filesystem was mutated by chump ingest"
fi
if [[ "$before_status" == "$after_status" ]]; then
    ok "no git state change (git status unchanged)"
else
    fail "git state changed by chump ingest"
fi

if grep -q '"ingest_validated"' "$AMBIENT_LOG" 2>/dev/null; then
    ok "ambient.jsonl has ingest_validated event"
else
    fail "ambient.jsonl missing ingest_validated event"
fi
if grep -q '"cost_usd_cents":"0"' "$AMBIENT_LOG" 2>/dev/null; then
    ok "ingest_validated reports cost_usd_cents=0"
else
    fail "ingest_validated missing cost_usd_cents=0"
fi

rm -rf "$VALID_DIR"

# ── Phase 6: ingest_initiated fires on every invocation ─────────────────
echo "── Phase 6: ingest_initiated ──"
if grep -q '"ingest_initiated"' "$AMBIENT_LOG" 2>/dev/null; then
    ok "ambient.jsonl has ingest_initiated event"
else
    fail "ambient.jsonl missing ingest_initiated event"
fi

rm -rf "$AMBIENT_HOME"

# ── Summary ───────────────────────────────────────────────────────────────
echo
echo "── Results: $PASS passed, $FAIL failed ──"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
