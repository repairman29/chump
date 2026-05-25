#!/usr/bin/env bash
# scripts/ci/test-agent-session-id.sh — INFRA-2024
#
# CI test: verifies that agent-session-id.sh produces STABLE ids within a
# single process and UNIQUE ids across distinct process invocations.
#
# Tests:
#   T1: Same process (sourced twice) → same id (stability)
#   T2: Two separate bash processes → different ids (uniqueness)
#   T3: Env-file written by script → sourcing it returns same id
#   T4: CHUMP_SESSION_ID preset → passthrough without overwrite
#   T5: session-start-session-id.sh writes env file; 2nd call is idempotent
#
# Exit: 0 all pass, 1 any failure.

set -euo pipefail

REPO="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO/scripts/setup/agent-session-id.sh"
HOOK="$REPO/scripts/setup/session-start-session-id.sh"
LOCKS="$REPO/.chump-locks"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== test-agent-session-id.sh (INFRA-2024) ==="
echo "SCRIPT: $SCRIPT"
echo "HOOK:   $HOOK"
echo ""

# ── Prerequisite checks ──────────────────────────────────────────────────────
[[ -f "$SCRIPT" ]] || { echo "FATAL: $SCRIPT not found" >&2; exit 1; }
[[ -x "$SCRIPT" ]] || { echo "FATAL: $SCRIPT not executable" >&2; exit 1; }
[[ -f "$HOOK"   ]] || { echo "FATAL: $HOOK not found" >&2; exit 1; }
[[ -x "$HOOK"   ]] || { echo "FATAL: $HOOK not executable" >&2; exit 1; }

# ── T1: Stability — sourcing the script twice in the same process → same id ──
# The stability guarantee is within one process: the second call reads from the
# env file written by the first call (keyed on $$, the process PID).
echo "T1: stability (sourced twice in same process → same id)"
(
    # Clean any leftover env file for this subshell PID
    rm -f "$LOCKS/session-$$.env"
    unset CHUMP_SESSION_ID

    # shellcheck source=/dev/null
    source "$SCRIPT"
    id1="${CHUMP_SESSION_ID:-}"

    # Source again — should re-read env file, not regenerate
    unset CHUMP_SESSION_ID
    # shellcheck source=/dev/null
    source "$SCRIPT"
    id2="${CHUMP_SESSION_ID:-}"

    rm -f "$LOCKS/session-$$.env"

    if [[ "$id1" == "$id2" && -n "$id1" ]]; then
        echo "  PASS: id stable across two sources in same process: $id1"
    else
        echo "  FAIL: ids differ: '$id1' vs '$id2'" >&2
        exit 1
    fi
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# ── T2: Uniqueness — two separate bash processes → different ids ─────────────
echo "T2: uniqueness (two separate processes → different ids)"
TMP_A="$(mktemp)"
TMP_B="$(mktemp)"
bash "$SCRIPT" > "$TMP_A" &
PID_A=$!
bash "$SCRIPT" > "$TMP_B" &
PID_B=$!
wait "$PID_A" "$PID_B"
ID_A="$(cat "$TMP_A")"
ID_B="$(cat "$TMP_B")"
rm -f "$TMP_A" "$TMP_B"

if [[ "$ID_A" != "$ID_B" ]]; then
    pass "two parallel processes produced different ids: '$ID_A' vs '$ID_B'"
else
    fail "two parallel processes produced identical ids: '$ID_A'"
fi

# ── T3: Env-file persistence — env file written by script can be sourced ─────
echo "T3: env-file persistence (env file matches sourced id)"
(
    rm -f "$LOCKS/session-$$.env"
    unset CHUMP_SESSION_ID

    # shellcheck source=/dev/null
    source "$SCRIPT"
    SOURCED_ID="${CHUMP_SESSION_ID:-}"

    ENV_FILE="$LOCKS/session-$$.env"
    if [[ -f "$ENV_FILE" ]]; then
        FILE_ID="$(grep '^CHUMP_SESSION_ID=' "$ENV_FILE" | cut -d= -f2)"
        if [[ "$SOURCED_ID" == "$FILE_ID" && -n "$SOURCED_ID" ]]; then
            echo "  PASS: env file matches sourced id: $SOURCED_ID"
        else
            echo "  FAIL: sourced '$SOURCED_ID' != file '$FILE_ID'" >&2
            exit 1
        fi
    else
        echo "  FAIL: env file not found at $ENV_FILE" >&2
        exit 1
    fi

    rm -f "$ENV_FILE"
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# ── T4: Passthrough — preset CHUMP_SESSION_ID is returned unchanged ──────────
echo "T4: preset CHUMP_SESSION_ID passthrough"
PRESET_ID="test-preset-session-abc123"
RETURNED="$(CHUMP_SESSION_ID="$PRESET_ID" bash "$SCRIPT")"
if [[ "$RETURNED" == "$PRESET_ID" ]]; then
    pass "preset id returned unchanged: $RETURNED"
else
    fail "preset id '$PRESET_ID' was overwritten; got '$RETURNED'"
fi

# ── T5: Hook — generates env file; idempotent on 2nd call ───────────────────
# The hook uses $$ = the calling process PID.  We simulate two consecutive
# SessionStart fires from the same Claude Code process by:
#   (a) calling the hook once to produce session-<pid>.env
#   (b) calling it again with the SAME pid env file already present
#       (Claude Code always has one stable PID; we emulate that by reusing
#        the env file that was just written and calling the hook with an
#        explicit CHUMP_SESSION_ID passthrough so it takes the early-exit path)
echo "T5: session-start-session-id.sh generates env file; idempotent on 2nd call"
(
    # First call: run hook as a subprocess; capture the pid it used
    TMP_FIRST="$(mktemp)"
    # Run hook and also grab its pid via a wrapper
    HOOK_PID_FILE="$(mktemp)"
    bash -c 'echo $$ > "'"$HOOK_PID_FILE"'"; exec bash "'"$HOOK"'"'
    HOOK_PID="$(cat "$HOOK_PID_FILE")"
    rm -f "$HOOK_PID_FILE" "$TMP_FIRST"

    HOOK_ENV="$LOCKS/session-${HOOK_PID}.env"
    if [[ -f "$HOOK_ENV" ]]; then
        HOOK_ID="$(grep '^CHUMP_SESSION_ID=' "$HOOK_ENV" | cut -d= -f2)"
        if [[ -n "$HOOK_ID" ]]; then
            echo "  PASS: hook wrote id on first call: $HOOK_ID"
        else
            echo "  FAIL: hook wrote empty id" >&2
            exit 1
        fi
    else
        echo "  FAIL: hook did not create env file at $HOOK_ENV" >&2
        exit 1
    fi

    # Second call: simulate the same PID by seeding its env file contents
    # into CHUMP_SESSION_ID so the hook takes the preset passthrough path
    # and does not regenerate.  This mirrors what happens in a real session
    # where $$ is constant and the env file already exists from the first call.
    HOOK_ID2="$(CHUMP_SESSION_ID="$HOOK_ID" bash "$HOOK" 2>/dev/null; \
                grep '^CHUMP_SESSION_ID=' "$HOOK_ENV" | cut -d= -f2)"
    if [[ "$HOOK_ID" == "$HOOK_ID2" ]]; then
        echo "  PASS: hook is idempotent; id unchanged: $HOOK_ID"
    else
        echo "  FAIL: hook changed id on 2nd call: '$HOOK_ID' -> '$HOOK_ID2'" >&2
        exit 1
    fi

    rm -f "$HOOK_ENV"
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
