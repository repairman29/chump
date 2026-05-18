#!/usr/bin/env bash
# INFRA-1229 slice 3: smoke test for the retry loop in `chump ship execute`.
#
# Uses a tmpdir-scoped fake `git` binary on $PATH that returns canned
# outputs to drive each retry classification (success, push-retry,
# rebase-conflict, exhausted-retries). The runner classifies via the
# pure chump_ship::classify_step_failure function from slice 3 step 1.

set -euo pipefail

# Resolve the chump binary. Prefer $CHUMP_BIN, then worktree-local target,
# then the workspace shared target.
BIN="${CHUMP_BIN:-}"
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
    if [[ -x "${CARGO_TARGET_DIR:-./target}/debug/chump" ]]; then
        BIN="${CARGO_TARGET_DIR:-./target}/debug/chump"
    elif [[ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]]; then
        BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
    fi
fi
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
    echo "[test] FAIL: chump binary not found — build first" >&2
    exit 2
fi
echo "[test] using binary: $BIN" >&2

WORK=$(mktemp -d /tmp/chump-ship-retry-smoke.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# A scriptable fake `git`: respects $CHUMP_FAKE_GIT_SCRIPT=push:rc:stderr_marker
# Order: 1st call to `git push` consults $CHUMP_FAKE_PUSH_1, 2nd $CHUMP_FAKE_PUSH_2, etc.
# Other git invocations (fetch, rebase) succeed by default unless
# $CHUMP_FAKE_REBASE_RC / $CHUMP_FAKE_REBASE_STDERR override.
cat > "$WORK/bin/git" <<'FAKE'
#!/usr/bin/env bash
sub="${1:-}"
case "$sub" in
    fetch)
        # Always succeed
        exit 0
        ;;
    rebase)
        rc="${CHUMP_FAKE_REBASE_RC:-0}"
        stderr="${CHUMP_FAKE_REBASE_STDERR:-}"
        [[ -n "$stderr" ]] && echo "$stderr" >&2
        exit "$rc"
        ;;
    push)
        # Pick the per-attempt scripted result via $CHUMP_FAKE_PUSH_SEQ.
        # Each call consumes one entry; default: "0:" (rc=0, no stderr).
        seq_file="${CHUMP_FAKE_PUSH_SEQ_FILE:-}"
        entry=""
        if [[ -n "$seq_file" && -f "$seq_file" ]]; then
            entry="$(head -1 "$seq_file" 2>/dev/null || true)"
            # Pop the consumed entry (only if there was one)
            if [[ -n "$entry" ]]; then
                tail -n +2 "$seq_file" > "$seq_file.tmp" && mv "$seq_file.tmp" "$seq_file"
            fi
        fi
        # Default when seq is empty/missing: success.
        [[ -z "$entry" ]] && entry="0:"
        rc="${entry%%:*}"
        rest="${entry#*:}"
        [[ -z "$rc" ]] && rc=0
        [[ -n "$rest" ]] && echo "$rest" >&2
        exit "$rc"
        ;;
    *)
        exit 0
        ;;
esac
FAKE
chmod +x "$WORK/bin/git"
export PATH="$WORK/bin:$PATH"

PLAN_REBASE='{"plan":{"action":"RebaseAndPush","behind_count":3}}'

# ── 1. Clean push first try → Success, retry_attempts=0 ─────────────────
SEQ="$WORK/seq1"
: > "$SEQ"  # empty → default rc=0
export CHUMP_FAKE_PUSH_SEQ_FILE="$SEQ"
unset CHUMP_FAKE_REBASE_RC CHUMP_FAKE_REBASE_STDERR
OUT=$(echo "$PLAN_REBASE" | "$BIN" ship execute --stdin --max-rebase-retries 3 2>/dev/null)
FINAL=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["final_action"])')
RETRIES=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["retry_attempts"])')
if [[ "$FINAL" != "Success" || "$RETRIES" != "0" ]]; then
    echo "[test] FAIL: clean push expected Success/0 retries; got $FINAL/$RETRIES" >&2
    echo "$OUT" | head -40 >&2
    exit 1
fi
echo "[test] PASS: clean push → Success (retry_attempts=0)"

# ── 2. Push fails once with stale-info → retries, then succeeds ─────────
SEQ="$WORK/seq2"
printf "1:rejected — stale info\n0:\n" > "$SEQ"
export CHUMP_FAKE_PUSH_SEQ_FILE="$SEQ"
OUT=$(echo "$PLAN_REBASE" | "$BIN" ship execute --stdin --max-rebase-retries 3 2>/dev/null)
FINAL=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["final_action"])')
RETRIES=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["retry_attempts"])')
if [[ "$FINAL" != "Success" || "$RETRIES" != "1" ]]; then
    echo "[test] FAIL: 1-retry-to-success expected Success/1 retries; got $FINAL/$RETRIES" >&2
    echo "$OUT" | head -50 >&2
    exit 1
fi
echo "[test] PASS: push fails once (stale info) → 1 retry → Success"

# ── 3. Push fails N+1 times (exhaust → final_action=Fail, exit 1) ───────
SEQ="$WORK/seq3"
printf "1:rejected — stale info\n1:rejected — stale info\n1:rejected — stale info\n1:rejected — stale info\n" > "$SEQ"
export CHUMP_FAKE_PUSH_SEQ_FILE="$SEQ"
set +e
OUT=$(echo "$PLAN_REBASE" | "$BIN" ship execute --stdin --max-rebase-retries 3 2>/dev/null)
rc=$?
set -e
FINAL=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["final_action"])')
if [[ "$FINAL" != "Fail" || "$rc" != "1" ]]; then
    echo "[test] FAIL: exhausted retries expected Fail/exit 1; got $FINAL/$rc" >&2
    echo "$OUT" | head -60 >&2
    exit 1
fi
echo "[test] PASS: exhausted retries → Fail, exit 1"

# ── 4. Rebase produces CONFLICT → immediate AbortAsConflict ─────────────
SEQ="$WORK/seq4"
: > "$SEQ"
export CHUMP_FAKE_PUSH_SEQ_FILE="$SEQ"
export CHUMP_FAKE_REBASE_RC=1
export CHUMP_FAKE_REBASE_STDERR='CONFLICT (content): Merge conflict in src/main.rs'
set +e
OUT=$(echo "$PLAN_REBASE" | "$BIN" ship execute --stdin --max-rebase-retries 3 2>/dev/null)
rc=$?
set -e
FINAL=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["final_action"])')
RETRIES=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["retry_attempts"])')
if [[ "$FINAL" != "ConflictRecover" || "$rc" != "1" || "$RETRIES" != "0" ]]; then
    echo "[test] FAIL: conflict expected ConflictRecover/exit 1/0 retries; got $FINAL/$rc/$RETRIES" >&2
    echo "$OUT" | head -60 >&2
    exit 1
fi
echo "[test] PASS: rebase conflict → ConflictRecover (no retry, exit 1)"
unset CHUMP_FAKE_REBASE_RC CHUMP_FAKE_REBASE_STDERR

# ── 5. Non-stale push failure → Fail without retry ──────────────────────
SEQ="$WORK/seq5"
printf "1:error: src refspec HEAD does not match any\n" > "$SEQ"
export CHUMP_FAKE_PUSH_SEQ_FILE="$SEQ"
set +e
OUT=$(echo "$PLAN_REBASE" | "$BIN" ship execute --stdin --max-rebase-retries 3 2>/dev/null)
rc=$?
set -e
FINAL=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["final_action"])')
RETRIES=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["retry_attempts"])')
if [[ "$FINAL" != "Fail" || "$rc" != "1" || "$RETRIES" != "0" ]]; then
    echo "[test] FAIL: non-stale push failure expected Fail/exit 1/0 retries; got $FINAL/$rc/$RETRIES" >&2
    echo "$OUT" | head -60 >&2
    exit 1
fi
echo "[test] PASS: non-stale push failure → Fail (no retry classification)"

echo ""
echo "[test] ALL CHUMP-SHIP-EXECUTE RETRY CHECKS PASSED — INFRA-1229 slice 3 verified"
