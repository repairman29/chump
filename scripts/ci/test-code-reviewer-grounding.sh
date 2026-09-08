#!/usr/bin/env bash
# test-code-reviewer-grounding.sh — CREDIBLE-207
#
# Guards the grounding check added to scripts/coord/code-reviewer-agent.sh:
# a CONCERN verdict with no file:line citation in its reason is treated as
# ungrounded and downgraded to ESCALATE, instead of silently blocking a
# clean merge on a hallucinated/boilerplate concern (PR #3495 EFFECTIVE-373
# precedent: reviewer raised CONCERN listing "new unwrap()/expect() in
# production" + "new external dependencies added", both demonstrably false
# in that diff).
#
# DEPTH: smoke + parse-logic unit, mirroring test-code-reviewer-spirit.sh.
#   - Covered: the exact grounding regex + CONCERN->ESCALATE downgrade rule,
#     over grounded / ungrounded / APPROVE / ESCALATE fixtures; and a
#     structural guard that the live script still contains the gate.
#   - GAP (not covered): no end-to-end run against a real LLM response —
#     the model's ability to actually emit a file:line citation is not
#     asserted here (same gap class as the SPIRIT-lens test).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../coord/code-reviewer-agent.sh"
fail=0
check() { # desc expected actual
    if [[ "$2" == "$3" ]]; then echo "  ok: $1"; else echo "  FAIL: $1 — expected [$2] got [$3]"; fail=1; fi
}

# Mirror the script's parse + grounding-downgrade so a fixture RESPONSE yields
# a final verdict. Only the VERDICT is asserted (echoed) by this helper.
final_verdict() { # RESPONSE (via stdin) — echoes the post-grounding verdict
    local RESPONSE VERDICT_LINE VERDICT REASON
    RESPONSE="$(cat)"
    VERDICT_LINE=$(echo "$RESPONSE" | grep -E '^(APPROVE|CONCERN|ESCALATE):' | head -1)
    [[ -z "$VERDICT_LINE" ]] && VERDICT_LINE="ESCALATE: no format"
    VERDICT=$(echo "$VERDICT_LINE" | cut -d: -f1)
    REASON=$(echo "$VERDICT_LINE" | cut -d: -f2- | sed 's/^ //')
    if [[ "$VERDICT" == "CONCERN" ]] && ! echo "$REASON" | grep -qE '[A-Za-z0-9_./-]+\.[A-Za-z0-9_]+:[0-9]+'; then
        VERDICT="ESCALATE"
    fi
    echo "$VERDICT"
}

echo "test-code-reviewer-grounding (CREDIBLE-207):"

# 1. A CONCERN with no file:line citation is ungrounded -> downgrades to ESCALATE.
check "ungrounded CONCERN downgrades to ESCALATE" "ESCALATE" \
    "$(printf 'CONCERN: new unwrap()/expect() in production, new external dependencies added\n' | final_verdict)"

# 2. A CONCERN that cites a file:line is grounded -> stays CONCERN (still blocks).
check "grounded CONCERN stays CONCERN" "CONCERN" \
    "$(printf 'CONCERN: src/foo.rs:42 unwrap() on untrusted input\n' | final_verdict)"

# 3. Multiple concerns, at least one grounded -> stays CONCERN.
check "one grounded concern among many stays CONCERN" "CONCERN" \
    "$(printf 'CONCERN: vague style nit, crates/chump-core/src/bar.rs:17 off-by-one in loop bound\n' | final_verdict)"

# 4. APPROVE is untouched by the grounding check (only applies to CONCERN).
check "APPROVE unaffected by grounding check" "APPROVE" \
    "$(printf 'APPROVE: clean diff, no issues\n' | final_verdict)"

# 5. ESCALATE is untouched by the grounding check (already the ceiling).
check "ESCALATE unaffected by grounding check" "ESCALATE" \
    "$(printf 'ESCALATE: touches auth boundary\n' | final_verdict)"

# 6. Structural guard: the live script still carries the grounding gate.
if grep -q 'CONCERN has no file:line citation' "$SCRIPT" \
   && grep -q 'treating as ungrounded, downgrading to ESCALATE' "$SCRIPT"; then
    echo "  ok: live script contains the grounding gate"
else
    echo "  FAIL: grounding gate missing from $SCRIPT"; fail=1
fi

# 7. Structural guard: the prompt instructs the model to cite file:line evidence.
if grep -q 'MUST point at a specific file:line' "$SCRIPT"; then
    echo "  ok: live script's prompt requires file:line citations for CONCERN"
else
    echo "  FAIL: prompt grounding instruction missing from $SCRIPT"; fail=1
fi

if [[ $fail -eq 0 ]]; then echo "PASS"; else echo "FAILED"; exit 1; fi
