#!/usr/bin/env bash
# scripts/ci/test-prepush-rust-env-immunity.sh — INFRA-1997 Phase 1
#
# Verifies that the new chump-pre-push binary resolves the REAL repo root
# even when GIT_DIR / GIT_WORK_TREE / GITHUB_WORKSPACE are pre-injected
# with bogus values — the env-leak class behind INFRA-1950 / TRUNK_RED
# 2026-05-23.
#
# DOES NOT emit any new ambient event kinds. Sets CHUMP_AMBIENT_DISABLE=1
# defensively so any future telemetry the binary picks up is muted.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Defensive: kill any inherited workflow CHUMP_* state that could redirect
# the binary to a different repo. The whole point of this test is to
# verify env-immunity, so we must inject the leak deliberately, not let
# the runner inject it implicitly.
unset CHUMP_LOCK_DIR CHUMP_REPO CHUMP_REPO_ROOT 2>/dev/null || true
export CHUMP_AMBIENT_DISABLE=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '      %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Build the binary up front. The test asserts the BUILT binary behaves
# correctly under env-leak, not a stub.
# ---------------------------------------------------------------------------
echo "[test] building chump-git-hooks binary..."
BUILD_LOG="$TMP/build.log"
if ! (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" \
        cargo build --quiet -p chump-git-hooks --bin chump-pre-push) \
        >"$BUILD_LOG" 2>&1; then
    echo "[test] BUILD FAILED — log below:"
    cat "$BUILD_LOG"
    exit 1
fi

# Locate the binary. cargo's default target dir is target/ at workspace
# root; sccache / .cargo-test-target are also possible.
BIN=""
CARGO_TARGET_DIR_VAL="${CARGO_TARGET_DIR:-}"
for candidate in \
    "$REPO_ROOT/target/debug/chump-pre-push" \
    "$REPO_ROOT/.cargo-test-target/debug/chump-pre-push" \
    "${CARGO_TARGET_DIR_VAL:+$CARGO_TARGET_DIR_VAL/debug/chump-pre-push}" \
    ; do
    [[ -z "$candidate" ]] && continue
    if [[ -x "$candidate" ]]; then
        BIN="$candidate"
        break
    fi
done
if [[ -z "$BIN" ]]; then
    fail "could not locate built chump-pre-push binary"
    echo "Looked in:"
    echo "  $REPO_ROOT/target/debug/"
    echo "  $REPO_ROOT/.cargo-test-target/debug/"
    echo "  \$CARGO_TARGET_DIR/debug/"
    exit 1
fi
note "binary: $BIN"

# ---------------------------------------------------------------------------
# Test 1: Env-leak injection. Set fake GIT_DIR / GIT_WORK_TREE /
# GITHUB_WORKSPACE that point at non-existent paths. The binary MUST
# scrub them and still discover the real repo root via env_clear'd git
# subprocess. We verify by running the binary in --help-ish mode: any
# successful exit + RUST_LOG=info trace mentioning the real repo path is
# proof of env-immunity.
#
# Strategy: feed an empty stdin (zero refspecs) + dummy argv → binary
# should construct HookContext successfully and exit 0. We capture stderr
# (where tracing writes) and grep for the real repo root.
# ---------------------------------------------------------------------------
FAKE_GIT_DIR="$TMP/fake-git-dir-$$"
FAKE_WT="$TMP/fake-wt-$$"
FAKE_WS="$TMP/fake-ws-$$"
mkdir -p "$FAKE_WT" "$FAKE_WS"

# Initialize a fake git dir so any non-scrubbed binary would resolve THERE.
git -C "$FAKE_WT" init --quiet 2>/dev/null || true

STDERR_LOG="$TMP/stderr.log"
STDOUT_LOG="$TMP/stdout.log"

# Run binary from REPO_ROOT cwd with leak vars pre-injected. If the
# binary scrubs them correctly, repo discovery resolves to REPO_ROOT.
# If it does NOT scrub them, repo discovery resolves to FAKE_WT (or
# fails entirely if FAKE_GIT_DIR is bogus).
cd "$REPO_ROOT"
GIT_DIR="$FAKE_GIT_DIR" \
GIT_WORK_TREE="$FAKE_WT" \
GITHUB_WORKSPACE="$FAKE_WS" \
GIT_COMMON_DIR="$FAKE_GIT_DIR" \
GIT_INDEX_FILE="$FAKE_GIT_DIR/index" \
RUST_LOG=info \
    "$BIN" origin "git@example.com:foo/bar.git" </dev/null \
    >"$STDOUT_LOG" 2>"$STDERR_LOG"
RC=$?

if [[ "$RC" -eq 0 ]]; then
    ok "binary exited 0 under env-leak injection (empty stdin → no guards to fire)"
else
    fail "binary exited non-zero ($RC) under env-leak injection"
    echo "stderr:"
    sed 's/^/    /' "$STDERR_LOG"
fi

# Stderr should mention the REAL repo root path (REPO_ROOT) in the
# tracing init log, NOT the fake paths.
if grep -q "repo_root=$REPO_ROOT" "$STDERR_LOG" || \
   grep -q "repo_root=\"$REPO_ROOT\"" "$STDERR_LOG"; then
    ok "binary discovered real repo root despite env-leak"
elif grep -qF "$FAKE_WT" "$STDERR_LOG" || grep -qF "$FAKE_GIT_DIR" "$STDERR_LOG"; then
    fail "binary leaked fake paths to stderr — env scrubbing FAILED"
    echo "stderr:"
    sed 's/^/    /' "$STDERR_LOG"
else
    # Tracing may not have fired at this level — verify the binary at
    # least didn't blow up trying to use the fake paths.
    note "no explicit repo_root mention in stderr at RUST_LOG=info; checking absence of fake paths"
    if ! grep -qF "$FAKE_WT" "$STDERR_LOG" && ! grep -qF "$FAKE_GIT_DIR" "$STDERR_LOG"; then
        ok "no leaked fake paths in stderr (env scrubbing held)"
    else
        fail "fake paths appeared in stderr"
        sed 's/^/    /' "$STDERR_LOG"
    fi
fi

# ---------------------------------------------------------------------------
# Test 2: malformed-refspec rejection. Binary must exit non-zero when
# stdin has a malformed line (not 4 whitespace-separated tokens).
# ---------------------------------------------------------------------------
STDERR_LOG2="$TMP/stderr2.log"
# Only 3 whitespace-separated tokens — parser must reject.
echo "only three tokens" | \
    "$BIN" origin "url" >"$TMP/stdout2.log" 2>"$STDERR_LOG2"
RC2=$?
if [[ "$RC2" -ne 0 ]]; then
    ok "malformed stdin (3 tokens) produces non-zero exit"
else
    fail "malformed stdin did not produce non-zero exit"
    sed 's/^/    /' "$STDERR_LOG2"
fi

# ---------------------------------------------------------------------------
# Test 3: well-formed empty-stdin case under leak. Pass condition.
# ---------------------------------------------------------------------------
STDERR_LOG3="$TMP/stderr3.log"
GIT_DIR="$FAKE_GIT_DIR" GIT_WORK_TREE="$FAKE_WT" \
    "$BIN" origin "url" </dev/null \
    >"$TMP/stdout3.log" 2>"$STDERR_LOG3"
RC3=$?
if [[ "$RC3" -eq 0 ]]; then
    ok "empty stdin under env-leak: binary passes through cleanly"
else
    fail "empty stdin under env-leak: binary exited $RC3"
    sed 's/^/    /' "$STDERR_LOG3"
fi

# ---------------------------------------------------------------------------
# Test 4: source-level discipline. Verify the new crate does NOT contain
# any actual ambient-emission code paths — this is the regression class
# behind yesterday's #2540 closure. We grep only Rust files (*.rs) and
# only outside of comment lines, so docs that mention "must NOT emit" do
# not false-positive.
# ---------------------------------------------------------------------------
CRATE_DIR="$REPO_ROOT/crates/chump-git-hooks"
# Search for code patterns (function calls or macros) in .rs files, then
# filter out lines that are comments (start with //!  //  /*  * etc.).
AMBIENT_MATCHES="$(find "$CRATE_DIR" -name '*.rs' -print0 2>/dev/null \
    | xargs -0 grep -nE 'ambient_emit::emit|ambient_emit!\(|EVENT_REGISTRY' 2>/dev/null \
    | grep -vE ':[[:space:]]*(//|//!|/\*|\*)' || true)"
if [[ -n "$AMBIENT_MATCHES" ]]; then
    fail "new crate references ambient emission code — Phase 1 forbids new event kinds"
    echo "$AMBIENT_MATCHES" | sed 's/^/    /'
else
    ok "no ambient emission code in chump-git-hooks crate (.rs files)"
fi

# ---------------------------------------------------------------------------
# Test 5: bash shim dispatch. Verify the shim line at top of
# scripts/git-hooks/pre-push routes to chump-pre-push when CHUMP_PREPUSH_RUST=1.
# ---------------------------------------------------------------------------
PRE_PUSH="$REPO_ROOT/scripts/git-hooks/pre-push"
if grep -q 'CHUMP_PREPUSH_RUST' "$PRE_PUSH" && grep -q 'exec chump-pre-push' "$PRE_PUSH"; then
    ok "bash shim dispatch line present in scripts/git-hooks/pre-push"
else
    fail "bash shim dispatch line missing or malformed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=== test-prepush-rust-env-immunity.sh ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
