#!/usr/bin/env bash
# test-code-reviewer-spirit.sh — CREDIBLE-191 slice-1
#
# Guards the SPIRIT lens added to scripts/coord/code-reviewer-agent.sh: the
# stub-detection axis that downgrades a letter-correct APPROVE to a blocking
# CONCERN when the diff FAKES the behaviour (EFFECTIVE-351 stub-false-green).
#
# DEPTH: smoke + parse-logic unit.
#   - Covered: the exact grep/sed SPIRIT parse + the STUB→CONCERN downgrade rule,
#     over GENUINE / PARTIAL / STUB / absent / malformed fixtures; and a
#     structural guard that the live script still contains the gate.
#   - GAP (not covered): no end-to-end run of the full reviewer against a real
#     STUB PR (that path shells git + gh + `chump llm-complete`); the model's
#     ability to *emit* SPIRIT: STUB on a genuine stub is not asserted here.
#     Follow-up: an integration fixture PR + a ci.yml wiring step.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../coord/code-reviewer-agent.sh"
fail=0
check() { # desc expected actual
    if [[ "$2" == "$3" ]]; then echo "  ok: $1"; else echo "  FAIL: $1 — expected [$2] got [$3]"; fail=1; fi
}

# Mirror the script's parse + downgrade so a fixture RESPONSE yields a final verdict.
final_verdict() { # RESPONSE (via stdin) — echoes the post-SPIRIT verdict
    local RESPONSE VERDICT_LINE VERDICT SPIRIT_LINE SPIRIT
    RESPONSE="$(cat)"
    VERDICT_LINE=$(echo "$RESPONSE" | grep -E '^(APPROVE|CONCERN|ESCALATE):' | head -1)
    [[ -z "$VERDICT_LINE" ]] && VERDICT_LINE="ESCALATE: no format"
    VERDICT=$(echo "$VERDICT_LINE" | cut -d: -f1)
    SPIRIT_LINE=$(echo "$RESPONSE" | grep -E '^SPIRIT:[[:space:]]*(GENUINE|PARTIAL|STUB)' | head -1)
    SPIRIT=$(echo "$SPIRIT_LINE" | sed -E 's/^SPIRIT:[[:space:]]*([A-Z]+).*/\1/')
    if [[ "$SPIRIT" == "STUB" && "$VERDICT" == "APPROVE" ]]; then VERDICT="CONCERN"; fi
    # CREDIBLE-191 slice-2: CORRECTNESS + HARMONY lenses, same additive/fail-open rule.
    local CORR HARM
    CORR=$(echo "$RESPONSE" | grep -E '^CORRECTNESS:[[:space:]]*(SOUND|UNSURE|FALSE-GREEN)' | head -1 | sed -E 's/^CORRECTNESS:[[:space:]]*([A-Z-]+).*/\1/')
    if [[ "$CORR" == "FALSE-GREEN" && "$VERDICT" == "APPROVE" ]]; then VERDICT="CONCERN"; fi
    HARM=$(echo "$RESPONSE" | grep -E '^HARMONY:[[:space:]]*(FITS|HACKY|REGRESSION-RISK)' | head -1 | sed -E 's/^HARMONY:[[:space:]]*([A-Z-]+).*/\1/')
    if [[ "$HARM" == "REGRESSION-RISK" && "$VERDICT" == "APPROVE" ]]; then VERDICT="CONCERN"; fi
    echo "$VERDICT"
}

echo "test-code-reviewer-spirit (CREDIBLE-191):"

# 1. STUB downgrades a would-be APPROVE → CONCERN (the whole point).
check "STUB overrides APPROVE" "CONCERN" \
    "$(printf 'APPROVE: looks clean\nSPIRIT: STUB - returns hardcoded 0, real logic is a todo!()\n' | final_verdict)"

# 2. GENUINE leaves APPROVE intact.
check "GENUINE keeps APPROVE" "APPROVE" \
    "$(printf 'APPROVE: solid\nSPIRIT: GENUINE - implements the real diff\n' | final_verdict)"

# 3. PARTIAL is informational — does NOT block in slice-1.
check "PARTIAL keeps APPROVE" "APPROVE" \
    "$(printf 'APPROVE: fine\nSPIRIT: PARTIAL - edge case X still open\n' | final_verdict)"

# 4. Fail-open: no SPIRIT line → verdict unchanged (pre-CREDIBLE-191 behaviour).
check "absent SPIRIT keeps APPROVE" "APPROVE" \
    "$(printf 'APPROVE: no spirit line emitted\n' | final_verdict)"

# 5. Malformed SPIRIT value → treated as absent (fail-open, no downgrade).
check "malformed SPIRIT keeps APPROVE" "APPROVE" \
    "$(printf 'APPROVE: ok\nSPIRIT: MAYBE - garbage\n' | final_verdict)"

# 6. STUB does NOT upgrade a CONCERN (only downgrades APPROVE).
check "STUB leaves CONCERN" "CONCERN" \
    "$(printf 'CONCERN: new dep added\nSPIRIT: STUB - also faked\n' | final_verdict)"

# --- CREDIBLE-191 slice-2: CORRECTNESS + HARMONY lenses ---
# 7. FALSE-GREEN downgrades APPROVE (broken-but-green half of EFFECTIVE-351).
check "FALSE-GREEN overrides APPROVE" "CONCERN" \
    "$(printf 'APPROVE: ok\nSPIRIT: GENUINE - real\nCORRECTNESS: FALSE-GREEN - inverted condition, test never hits it\nHARMONY: FITS - fine\n' | final_verdict)"

# 8. REGRESSION-RISK downgrades APPROVE.
check "REGRESSION-RISK overrides APPROVE" "CONCERN" \
    "$(printf 'APPROVE: ok\nSPIRIT: GENUINE - real\nCORRECTNESS: SOUND - right\nHARMONY: REGRESSION-RISK - caller foo() not updated\n' | final_verdict)"

# 9. SOUND + FITS keep APPROVE (informational verdicts never block).
check "SOUND+FITS keep APPROVE" "APPROVE" \
    "$(printf 'APPROVE: ok\nSPIRIT: GENUINE - real\nCORRECTNESS: SOUND - right\nHARMONY: FITS - clean\n' | final_verdict)"

# 10. HACKY / UNSURE are informational — do NOT block.
check "HACKY+UNSURE keep APPROVE" "APPROVE" \
    "$(printf 'APPROVE: ok\nCORRECTNESS: UNSURE - could not verify\nHARMONY: HACKY - band-aid but works\n' | final_verdict)"

# 11. Fail-open: no correctness/harmony lines → verdict unchanged.
check "absent new lenses keep APPROVE" "APPROVE" \
    "$(printf 'APPROVE: ok\nSPIRIT: GENUINE - real\n' | final_verdict)"

# 12. FALSE-GREEN does NOT upgrade a CONCERN.
check "FALSE-GREEN leaves CONCERN" "CONCERN" \
    "$(printf 'CONCERN: dep added\nCORRECTNESS: FALSE-GREEN - also wrong\n' | final_verdict)"

# 13. Structural guard: the live script still carries all three lens gates.
if grep -q 'SPIRIT: STUB overrides APPROVE' "$SCRIPT" \
   && grep -q 'CORRECTNESS: FALSE-GREEN overrides APPROVE' "$SCRIPT" \
   && grep -q 'HARMONY: REGRESSION-RISK overrides APPROVE' "$SCRIPT"; then
    echo "  ok: live script contains the SPIRIT + CORRECTNESS + HARMONY gates"
else
    echo "  FAIL: a lens gate is missing from $SCRIPT"; fail=1
fi

if [[ $fail -eq 0 ]]; then echo "PASS"; else echo "FAILED"; exit 1; fi
