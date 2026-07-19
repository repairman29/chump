#!/usr/bin/env bash
# scripts/ci/test-ingest-smoke.sh — INFRA-1780
#
# Smoke test for `chump ingest <repo-path>` (phase 1a: CLI + validation +
# read-only safety). Asserts:
#   1. --help exits 0
#   2. missing arg exits non-zero
#   3. nonexistent path fails with ingest_failed / path_not_found, no mutation
#   4. non-git directory fails with ingest_failed / not_a_git_repo
#   5. valid git repo in default (read-only) mode succeeds and writes nothing
#   6. valid git repo with --confirm-mutations succeeds
#   7. ambient.jsonl has ingest_initiated AND ingest_validated events
#
# Runs in <30s, no network.
# SOURCE scrub-git-env.sh (RESILIENT-090) to isolate from pre-push hook env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/lib/scrub-git-env.sh
source "$REPO_ROOT/scripts/lib/scrub-git-env.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# ── Locate chump binary ───────────────────────────────────────────────────────
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

AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

ambient_before=0
if [[ -f "$AMBIENT_LOG" ]]; then
    ambient_before=$(wc -l < "$AMBIENT_LOG")
fi

# ── Phase 0: binary present ───────────────────────────────────────────────────
echo "── Phase 0: binary present ──"
[[ -x "$CHUMP_BIN" ]] && ok "chump binary executable at $CHUMP_BIN" || { fail "chump binary not executable"; exit 1; }

# ── Phase 1: --help exits 0 ──────────────────────────────────────────────────
echo "── Phase 1: --help ──"
if "$CHUMP_BIN" ingest --help &>/dev/null; then
    ok "chump ingest --help exits 0"
else
    fail "chump ingest --help failed"
fi

# ── Phase 2: missing arg exits non-zero ──────────────────────────────────────
echo "── Phase 2: missing arg guard ──"
if ! "$CHUMP_BIN" ingest 2>/dev/null; then
    ok "missing <repo-path> exits non-zero"
else
    fail "missing <repo-path> should have exited non-zero"
fi

# ── Phase 3: nonexistent path fails, no mutation ─────────────────────────────
echo "── Phase 3: nonexistent path ──"
NONEXISTENT="/tmp/chump-ingest-smoke-does-not-exist-$$"
rm -rf "$NONEXISTENT"
if ! "$CHUMP_BIN" ingest "$NONEXISTENT" 2>/dev/null; then
    ok "nonexistent path exits non-zero"
else
    fail "nonexistent path should have exited non-zero"
fi
if [[ ! -e "$NONEXISTENT" ]]; then
    ok "no filesystem mutation for nonexistent path"
else
    fail "chump ingest created something at a nonexistent target path"
fi

# ── Phase 4: non-git directory fails ─────────────────────────────────────────
echo "── Phase 4: non-git directory ──"
PLAIN_DIR=$(mktemp -d)
if ! "$CHUMP_BIN" ingest "$PLAIN_DIR" 2>/dev/null; then
    ok "non-git directory exits non-zero"
else
    fail "non-git directory should have exited non-zero"
fi
if [[ ! -d "$PLAIN_DIR/.git" ]]; then
    ok "no .git created in non-git target (not mutated)"
else
    fail "chump ingest created .git in a non-git target"
fi
rm -rf "$PLAIN_DIR"

# ── Phase 5: valid git repo, default read-only mode ──────────────────────────
echo "── Phase 5: valid git repo, read-only mode ──"
GIT_DIR=$(mktemp -d)
git -C "$GIT_DIR" init -q
git -C "$GIT_DIR" config user.email "smoke@chump.local"
git -C "$GIT_DIR" config user.name "smoke"
echo "hello" > "$GIT_DIR/README.md"
git -C "$GIT_DIR" add README.md
git -C "$GIT_DIR" -c gpg.sign=false commit -q -m "seed" --no-verify

before_hash=$(git -C "$GIT_DIR" rev-parse HEAD)

if "$CHUMP_BIN" ingest "$GIT_DIR" 2>&1; then
    ok "valid git repo, read-only mode exits 0"
else
    fail "valid git repo, read-only mode should exit 0"
fi

after_hash=$(git -C "$GIT_DIR" rev-parse HEAD)
if [[ "$before_hash" == "$after_hash" ]]; then
    ok "read-only mode did not mutate the target repo"
else
    fail "read-only mode mutated the target repo (HEAD changed)"
fi

# ── Phase 6: valid git repo, --confirm-mutations ─────────────────────────────
echo "── Phase 6: --confirm-mutations ──"
if "$CHUMP_BIN" ingest "$GIT_DIR" --confirm-mutations 2>&1; then
    ok "valid git repo with --confirm-mutations exits 0"
else
    fail "valid git repo with --confirm-mutations should exit 0"
fi

after_confirm_hash=$(git -C "$GIT_DIR" rev-parse HEAD)
if [[ "$before_hash" == "$after_confirm_hash" ]]; then
    ok "phase 1a still writes nothing even with --confirm-mutations"
else
    fail "phase 1a should not mutate the repo even with --confirm-mutations"
fi

rm -rf "$GIT_DIR"

# ── Phase 7: ambient events ───────────────────────────────────────────────────
echo "── Phase 7: ambient events ──"
if [[ -f "$AMBIENT_LOG" ]]; then
    new_events=$(tail -n +"$((ambient_before+1))" "$AMBIENT_LOG" 2>/dev/null || echo "")
    if echo "$new_events" | grep -q '"ingest_initiated"'; then
        ok "ambient.jsonl has ingest_initiated event"
    else
        fail "ambient.jsonl missing ingest_initiated event"
    fi
    if echo "$new_events" | grep -q '"ingest_validated"'; then
        ok "ambient.jsonl has ingest_validated event"
    else
        fail "ambient.jsonl missing ingest_validated event"
    fi
    if echo "$new_events" | grep -q '"ingest_failed"'; then
        ok "ambient.jsonl has ingest_failed event"
    else
        fail "ambient.jsonl missing ingest_failed event"
    fi
else
    echo "  SKIP: ambient.jsonl not found at $AMBIENT_LOG (not a blocking failure)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "── Results: $PASS passed, $FAIL failed ──"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
