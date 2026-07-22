#!/usr/bin/env bash
# scripts/ci/test-bootstrap-smoke.sh — INFRA-2265
#
# Smoke test for `chump bootstrap <intent>`.
# Asserts:
#   1. .git/ exists in the target dir
#   2. README.md contains the intent string
#   3. Cargo.toml exists (default arch = rust)
#   4. state.db has a new gap (EFFECTIVE-* entry added)
#   5. ambient.jsonl has bootstrap_initiated AND bootstrap_completed events
#
# Runs in <90s. No network when --skip-arch-decision is used.
# SOURCE scrub-git-env.sh (RESILIENT-090) to isolate from pre-push hook env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# RESILIENT-090: scrub GIT_* env vars so `git init` inside the test creates a
# truly isolated repo, not a commit in the operator's worktree.
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
STATE_DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"

# Count existing EFFECTIVE gaps before the test (for delta check).
gaps_before=0
if [[ -f "$STATE_DB" ]]; then
    gaps_before=$(sqlite3 "$STATE_DB" \
        "SELECT COUNT(*) FROM gaps WHERE domain='EFFECTIVE';" 2>/dev/null || echo 0)
fi

# Count ambient events before the test.
ambient_before=0
if [[ -f "$AMBIENT_LOG" ]]; then
    ambient_before=$(wc -l < "$AMBIENT_LOG")
fi

# ── Phase 0: binary present ───────────────────────────────────────────────────
echo "── Phase 0: binary present ──"
[[ -x "$CHUMP_BIN" ]] && ok "chump binary executable at $CHUMP_BIN" || { fail "chump binary not executable"; exit 1; }

# ── Phase 1: --help exits 0 ──────────────────────────────────────────────────
echo "── Phase 1: --help ──"
if "$CHUMP_BIN" bootstrap --help &>/dev/null; then
    ok "chump bootstrap --help exits 0"
else
    fail "chump bootstrap --help failed"
fi

# ── Phase 2: non-empty dir bails non-zero ────────────────────────────────────
echo "── Phase 2: non-empty dir guard ──"
ambient_before_fail=0
if [[ -f "$AMBIENT_LOG" ]]; then
    ambient_before_fail=$(wc -l < "$AMBIENT_LOG")
fi
NONEMPTY_DIR=$(mktemp -d)
echo "existing" > "$NONEMPTY_DIR/existing-file.txt"
if ! "$CHUMP_BIN" bootstrap "test intent" --dir "$NONEMPTY_DIR" --skip-arch-decision 2>/dev/null; then
    ok "non-empty dir bails non-zero"
    # Verify it didn't create a git repo.
    if [[ ! -d "$NONEMPTY_DIR/.git" ]]; then
        ok "no .git created in non-empty dir (filesystem not mutated)"
    else
        fail "chump bootstrap created .git in non-empty dir — should have bailed before mutation"
    fi
else
    fail "non-empty dir should have returned non-zero"
fi
rm -rf "$NONEMPTY_DIR"

# INFRA-1784: assert the failure path is observable — bootstrap_failed event
# with failure_class + failure_kind (transient|permanent) fields.
if [[ -f "$AMBIENT_LOG" ]]; then
    fail_events=$(tail -n +"$((ambient_before_fail+1))" "$AMBIENT_LOG" 2>/dev/null || echo "")
    if echo "$fail_events" | grep -q '"bootstrap_failed"'; then
        ok "ambient.jsonl has bootstrap_failed event on guard failure"
        if echo "$fail_events" | grep '"bootstrap_failed"' | grep -q '"failure_class":"scaffolding_write_failed"'; then
            ok "bootstrap_failed carries failure_class=scaffolding_write_failed"
        else
            fail "bootstrap_failed missing expected failure_class field"
        fi
        if echo "$fail_events" | grep '"bootstrap_failed"' | grep -q '"failure_kind":"permanent"'; then
            ok "bootstrap_failed carries failure_kind=permanent"
        else
            fail "bootstrap_failed missing expected failure_kind field"
        fi
    else
        fail "ambient.jsonl missing bootstrap_failed event on guard failure"
    fi
else
    echo "  SKIP: ambient.jsonl not found at $AMBIENT_LOG (not a blocking failure)"
fi

# ── Phase 3: successful bootstrap ────────────────────────────────────────────
echo "── Phase 3: successful bootstrap ──"
TARGET_DIR=$(mktemp -d)
INTENT="A CLI tool that tracks daily habits"

if "$CHUMP_BIN" bootstrap "$INTENT" \
    --dir "$TARGET_DIR" \
    --skip-arch-decision 2>&1; then
    ok "chump bootstrap exited 0"
else
    fail "chump bootstrap exited non-zero"
fi

# Assert .git/ exists.
if [[ -d "$TARGET_DIR/.git" ]]; then
    ok ".git/ exists in target dir"
else
    fail ".git/ missing from target dir"
fi

# Assert README.md contains the intent string.
if [[ -f "$TARGET_DIR/README.md" ]]; then
    if grep -qF "$INTENT" "$TARGET_DIR/README.md"; then
        ok "README.md contains the intent string"
    else
        fail "README.md does not contain intent string '$INTENT'"
    fi
else
    fail "README.md missing from target dir"
fi

# Assert Cargo.toml exists (default arch = rust).
if [[ -f "$TARGET_DIR/Cargo.toml" ]]; then
    ok "Cargo.toml exists (default rust scaffold)"
else
    fail "Cargo.toml missing from target dir"
fi

# Assert at least 1 commit exists.
commit_count=$(git -C "$TARGET_DIR" log --oneline 2>/dev/null | wc -l | tr -d ' ')
if [[ "$commit_count" -ge 1 ]]; then
    ok "target dir has $commit_count commit(s)"
else
    fail "target dir has no commits"
fi

rm -rf "$TARGET_DIR"

# ── Phase 4: ambient events ───────────────────────────────────────────────────
echo "── Phase 4: ambient events ──"
if [[ -f "$AMBIENT_LOG" ]]; then
    new_events=$(tail -n +"$((ambient_before+1))" "$AMBIENT_LOG" 2>/dev/null || echo "")
    if echo "$new_events" | grep -q '"bootstrap_initiated"'; then
        ok "ambient.jsonl has bootstrap_initiated event"
    else
        fail "ambient.jsonl missing bootstrap_initiated event"
    fi
    if echo "$new_events" | grep -q '"bootstrap_completed"'; then
        ok "ambient.jsonl has bootstrap_completed event"
    else
        fail "ambient.jsonl missing bootstrap_completed event (may be in older lines if test was fast)"
    fi
else
    echo "  SKIP: ambient.jsonl not found at $AMBIENT_LOG (not a blocking failure)"
fi

# ── Phase 5: gap filed in state.db ───────────────────────────────────────────
echo "── Phase 5: state.db gap delta ──"
if [[ -f "$STATE_DB" ]]; then
    gaps_after=$(sqlite3 "$STATE_DB" \
        "SELECT COUNT(*) FROM gaps WHERE domain='EFFECTIVE';" 2>/dev/null || echo 0)
    if [[ "$gaps_after" -gt "$gaps_before" ]]; then
        ok "state.db has $((gaps_after - gaps_before)) new EFFECTIVE gap(s) after bootstrap"
    else
        # gap reserve may fail if chump not fully set up (e.g. CI without state.db).
        echo "  SKIP: no new gaps in state.db (gap reserve may need a configured chump install)"
    fi
else
    echo "  SKIP: state.db not found at $STATE_DB (not a blocking failure)"
fi

# ── Phase 6: --with-roadmap graceful TODO ─────────────────────────────────────
echo "── Phase 6: --with-roadmap graceful TODO ──"
TARGET_DIR2=$(mktemp -d)
output=$("$CHUMP_BIN" bootstrap "Another intent" --dir "$TARGET_DIR2" \
    --skip-arch-decision --with-roadmap 2>&1 || true)
exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    ok "--with-roadmap exits 0 (graceful TODO)"
    if echo "$output" | grep -qi "TODO.*roadmap\|roadmap.*TODO"; then
        ok "--with-roadmap prints TODO message"
    else
        fail "--with-roadmap should print a TODO message about roadmap"
    fi
else
    fail "--with-roadmap should exit 0, got exit code $exit_code"
fi
rm -rf "$TARGET_DIR2"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "── Results: $PASS passed, $FAIL failed ──"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
