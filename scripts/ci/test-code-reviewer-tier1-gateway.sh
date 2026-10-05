#!/usr/bin/env bash
# test-code-reviewer-tier1-gateway.sh — regression test for INFRA-3466.
#
# The Tier-1 cascade pre-check in scripts/coord/code-reviewer-agent.sh used to
# hand-walk CHUMP_PROVIDER_1..10 from .env and hand-roll a `curl` + raw API
# key call to a hardcoded slot (default: groq). That duplicated the exact
# auth ladder (.env sourcing, key handling, HTTP call) that Tier-2 already
# gets for free from the shared `chump llm-complete` gateway (INFRA-3462).
# INFRA-3466 migrates Tier-1 onto the same gateway, biased to a cheap model
# class (default: haiku) via `--model`, killing the slot-duplication.
#
# This test stubs `gh` (PR diff plumbing) and `chump llm-complete` (gateway)
# to simulate a confident Tier-1 APPROVE on a small diff and asserts:
#   (1) the reviewer calls `chump llm-complete` with `--model haiku` (the
#       cascade model-class flag), not a hand-rolled curl to a named slot.
#   (2) Tier-1 short-circuits Tier-2 — the gateway is invoked exactly once,
#       proving the Anthropic call was skipped.
#   (3) the final verdict is APPROVE, carried through from the Tier-1 response.
#
# Run:
#   ./scripts/ci/test-code-reviewer-tier1-gateway.sh
#
# Exits non-zero on any failure.

set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== INFRA-3466 code-reviewer Tier-1 gateway-migration regression test ==="
echo

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ── Fake `gh` — serves a tiny, non-docs, non-sensitive diff for PR 998 ──────
cat > "$TMPDIR/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "diff" ]]; then
    if [[ "$*" == *"--name-only"* ]]; then
        echo "src/fake_module.rs"
    else
        cat <<'DIFF'
diff --git a/src/fake_module.rs b/src/fake_module.rs
index 0000000..1111111 100644
--- a/src/fake_module.rs
+++ b/src/fake_module.rs
@@ -1,1 +1,2 @@
 fn existing() {}
+fn added() {}
DIFF
    fi
    exit 0
fi
echo "fake gh: unhandled args: $*" >&2
exit 1
GHEOF
chmod +x "$TMPDIR/gh"

# ── Fake `chump` — records every invocation's args, always answers APPROVE ──
CALL_LOG="$TMPDIR/calls.log"
: > "$CALL_LOG"
cat > "$TMPDIR/chump" <<CHUMPEOF
#!/usr/bin/env bash
echo "\$*" >> "$CALL_LOG"
if [[ "\$1" == "llm-complete" ]]; then
    cat < /dev/stdin > /dev/null
    printf 'APPROVE: trivial one-line addition\nSPIRIT: GENUINE - adds real behaviour\nCORRECTNESS: SOUND - trivial, no logic risk\nHARMONY: FITS - matches existing style\n'
    exit 0
fi
echo "fake chump: unhandled args: \$*" >&2
exit 1
CHUMPEOF
chmod +x "$TMPDIR/chump"

OUTPUT=$(PATH="$TMPDIR:$PATH" CHUMP_LLM_BIN="$TMPDIR/chump" \
    bash "$REPO_ROOT/scripts/coord/code-reviewer-agent.sh" 998 2>&1)
RC=$?

# (1) Reviewer routes Tier-1 through `chump llm-complete --model haiku`.
if grep -qE '^llm-complete .*--model haiku' "$CALL_LOG"; then
    ok "Tier-1 calls 'chump llm-complete --model haiku' (shared gateway, not hand-rolled curl)"
else
    fail "no 'llm-complete --model haiku' invocation found. Calls:\n$(cat "$CALL_LOG")"
fi

# (2) Gateway invoked exactly once — proves Tier-2 Anthropic call was skipped.
CALL_COUNT=$(wc -l < "$CALL_LOG" | tr -d ' ')
if [[ "$CALL_COUNT" -eq 1 ]]; then
    ok "gateway invoked exactly once — Tier-1 APPROVE short-circuited Tier-2"
else
    fail "expected exactly 1 gateway call, got $CALL_COUNT. Calls:\n$(cat "$CALL_LOG")"
fi

# (3) Final verdict is APPROVE, carried through from the Tier-1 response, and
#     the reviewer exits 0 (APPROVE exit code).
if [[ $RC -eq 0 ]] && echo "$OUTPUT" | grep -q "^APPROVE:"; then
    ok "final verdict is APPROVE (exit 0), carried from Tier-1 gateway response"
else
    fail "expected exit 0 + APPROVE verdict, got exit $RC. Output:\n$OUTPUT"
fi

echo
echo "=== Result ==="
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
