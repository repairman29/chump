#!/usr/bin/env bash
# test-subagent-epilogue-ref.sh — INFRA-332
#
# Enforce that every subagent prompt-builder in this repo references the
# canonical `subagent-shipping-epilogue` token. The token resolves to
# `scripts/dispatch/subagent-shipping-epilogue.md` which holds the
# bot-merge / chump-doctor / manual-recovery / final-report contract that
# the META-025 trial showed is the load-bearing difference between 25%
# and ~80% subagent self-ship rate.
#
# Today only two prompt builders dispatch subagents:
#   - crates/chump-orchestrator/src/dispatch.rs::build_prompt
#       (claude -p backend, the AUTO-013 baseline path)
#   - src/execute_gap.rs::build_execute_gap_prompt
#       (chump --execute-gap backend, the chump-local cost-routing path)
#
# Both must reference the canonical token so that any future audit by
# `rg subagent-shipping-epilogue` finds them.
#
# Future builders (e.g. a new dispatcher backend, a Discord-bot relay,
# a meta-dispatcher) MUST also reference the token — this guard fails
# loudly when a new dispatcher path appears without it.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
EPILOGUE_FILE="$REPO_ROOT/scripts/dispatch/subagent-shipping-epilogue.md"
CANONICAL_TOKEN="subagent-shipping-epilogue"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-332 subagent-shipping-epilogue reference guard ==="
echo

# ── Test 1: the canonical file exists and has substantive content ───────────
echo "--- Test 1: canonical epilogue file exists and is non-empty ---"
if [ ! -f "$EPILOGUE_FILE" ]; then
    fail "$EPILOGUE_FILE does not exist"
elif [ "$(wc -l < "$EPILOGUE_FILE")" -lt 30 ]; then
    fail "$EPILOGUE_FILE is suspiciously short (< 30 lines)"
else
    ok "epilogue file present (${EPILOGUE_FILE#$REPO_ROOT/})"
fi

# ── Test 2: every known prompt-builder references the canonical token ──────
echo "--- Test 2: each known prompt builder references '$CANONICAL_TOKEN' ---"
PROMPT_BUILDERS=(
    "crates/chump-orchestrator/src/dispatch.rs"
    "src/execute_gap.rs"
)
for f in "${PROMPT_BUILDERS[@]}"; do
    if [ ! -f "$REPO_ROOT/$f" ]; then
        fail "$f does not exist (renamed? deleted? update this guard)"
        continue
    fi
    if grep -qF "$CANONICAL_TOKEN" "$REPO_ROOT/$f"; then
        ok "$f references the canonical token"
    else
        fail "$f does NOT reference '$CANONICAL_TOKEN' — paste-the-epilogue contract violated"
    fi
done

# ── Test 3: any *new* file that constructs a `claude -p` or `chump --execute-gap`
# prompt must also reference the token. We scan src/ + crates/ + scripts/ for
# the prompt-shape signal ("Chump dispatched agent" — the literal string both
# builders use as the task header) and require any file matching it to also
# contain the canonical token.
echo "--- Test 3: any new file building a 'Chump dispatched agent' prompt must reference the token ---"
PROMPT_SIGNATURE='Chump dispatched agent'
SCAN_PATHS=("src" "crates" "scripts")
unreferenced=0
cd "$REPO_ROOT"
# `grep -lr` prints unique filenames (relative to CWD = REPO_ROOT) that
# contain the signature. Avoids the absolute-path double-prefix bug.
for path in "${SCAN_PATHS[@]}"; do
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        # Skip the canonical doc itself + this test + any test-* file
        # (tests legitimately reference the signature for verification).
        case "$file" in
            scripts/dispatch/subagent-shipping-epilogue.md) continue ;;
            scripts/ci/test-*) continue ;;
        esac
        if grep -qF "$CANONICAL_TOKEN" "$file"; then
            continue
        fi
        echo "  WARN: $file contains '$PROMPT_SIGNATURE' but not '$CANONICAL_TOKEN'"
        unreferenced=$((unreferenced+1))
    done < <(grep -lr -F "$PROMPT_SIGNATURE" "$path" 2>/dev/null || true)
done
if [ "$unreferenced" -eq 0 ]; then
    ok "no unreferenced prompt builders found"
else
    fail "$unreferenced file(s) build a dispatched-agent prompt without the canonical token"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
