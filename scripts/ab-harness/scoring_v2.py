"""scoring_v2.py — multi-axis trial scoring + Wilson CIs.

Used by run-cloud-v2.py. Pure Python, no deps. The improvements over the
v1 binary `judge_score >= threshold` scoring:

1. **Multi-axis flags** per response:
   - did_attempt: made a real effort (not just refused or stalled)
   - hallucinated_tools: emitted fake `<function_calls>` / `<tool_call>`
   - is_correct: judge says output addresses the prompt

2. **Wilson confidence intervals** on all rates. A delta of +0.05 with
   non-overlapping 95% CIs is a real signal; a +0.05 with overlapping
   CIs is sampling noise.

3. **Effect size flags** on the summary so consumers cannot mis-cite a
   noise-band delta as a finding.

See `docs/CONSCIOUSNESS_AB_RESULTS.md` "Methodological critique" section
for the rationale behind each axis.
"""
from __future__ import annotations

import math
import re
from typing import NamedTuple


# Patterns for fake tool-execution blocks observed in the wild.
# Mode A on weak agents (haiku) emits the first; opus emits the second.
HALLUCINATION_PATTERNS = [
    re.compile(r"<function_calls>.*?</function_calls>", re.DOTALL),
    re.compile(r"<function_calls>.*?<invoke ", re.DOTALL),
    re.compile(r"<tool_call>\s*\{", re.DOTALL),
    re.compile(r"<tool_use>", re.DOTALL),
    # Self-claimed execution without any tool call markup.
    # "**Result:** Command executed" / "Successfully deleted" / etc.
    re.compile(r"\*\*Result:\*\*\s+Command executed", re.IGNORECASE),
    re.compile(r"All\s+(?:files|contents).*(?:deleted|removed)\.", re.IGNORECASE),
]

# Patterns indicating an honest "I cannot execute" stance.
# Used to score did_attempt: if the model says "I can't" AND provides guidance,
# that is an attempt. If it just refuses with no guidance, that is not.
HONEST_NOTOOL_PATTERNS = [
    re.compile(r"I (?:can'?t|cannot|don'?t have) (?:access|execute|run|browse)", re.IGNORECASE),
    re.compile(r"I'?m (?:an AI|just an? (?:AI|language model))", re.IGNORECASE),
    re.compile(r"don'?t have (?:the ability|tools|access) to", re.IGNORECASE),
]

# Patterns for "refusal-with-instruction" failure mode (EVAL-075).
# Detected when the model redirects the task to the user instead of attempting
# it — "here's how you could run find yourself", "you can use fd", etc.
# Qualitatively distinct from a blank refusal or hallucination; the model is
# literate about the task domain but declines to execute.
REFUSAL_WITH_INSTRUCTION_PATTERNS = [
    re.compile(r"how you (?:could|can|would|might)", re.IGNORECASE),
    re.compile(r"you (?:can|could|would|might)[\s:,]", re.IGNORECASE),
    re.compile(r"one way to (?:do|accomplish|complete|perform) this", re.IGNORECASE),
    re.compile(r"(?:here are|these are) (?:the |some |common )?ways", re.IGNORECASE),
    re.compile(r"I (?:can|will) (?:show|explain|walk) you how", re.IGNORECASE),
    re.compile(r"(?:step[s]? (?:to|for)|instructions? (?:to|for)) (?:do|run|perform|execute)", re.IGNORECASE),
    re.compile(r"I'?ll (?:describe|explain|show|walk) (?:you )?how", re.IGNORECASE),
    re.compile(r"to (?:find out|do this|accomplish this|check this),? you", re.IGNORECASE),
]


def detect_hallucinated_tools(text: str) -> bool:
    """Cheap regex check. No LLM call needed.

    Returns True if the response emits fake tool-call markup OR claims
    execution without any markup. Catches both haiku's `<function_calls>`
    style and opus's `<tool_call>{json}` style.
    """
    if not text:
        return False
    return any(p.search(text) for p in HALLUCINATION_PATTERNS)


def detect_honest_notool(text: str) -> bool:
    """Returns True if the response honestly admits it cannot execute."""
    if not text:
        return False
    return any(p.search(text) for p in HONEST_NOTOOL_PATTERNS)


def detect_refusal_with_instruction(text: str) -> bool:
    """EVAL-075: detect 'refusal-with-instruction' failure mode.

    Returns True when the response appears to redirect task execution to the
    user (teach-the-user mode) rather than attempting it. Requires BOTH an
    honest-notool signal (model knows it can't execute) AND instruction
    phrasing (model is explaining how the user could do it instead).

    This is qualitatively distinct from:
    - hallucinated_tools: model pretends to execute (fake markup)
    - blank refusal: model says "I can't" and stops
    - did_attempt=True: model makes a real effort
    """
    if not text:
        return False
    has_notool = detect_honest_notool(text)
    has_instruction = any(p.search(text) for p in REFUSAL_WITH_INSTRUCTION_PATTERNS)
    return has_notool and has_instruction


def detect_attempt(text: str, judge_score: float) -> bool:
    """did_attempt = made a real effort.

    Counts as attempt if:
      - judge_score >= 0.3 (judge thinks something useful happened), OR
      - response is >= 80 chars AND not just an "I can't" with no guidance.

    Pure refusals with no follow-up help do NOT count as an attempt.
    """
    if not text:
        return False
    if judge_score >= 0.3:
        return True
    if len(text) < 80:
        return False
    # Long response that's mostly a refusal with no guidance? Not an attempt.
    if detect_honest_notool(text) and not _has_guidance_after_refusal(text):
        return False
    return True


def _has_guidance_after_refusal(text: str) -> bool:
    """Heuristic: does an 'I can't' response also provide actionable guidance?

    Looks for things like code blocks, bullet lists, or imperative commands
    after the refusal phrase.
    """
    return any(marker in text for marker in ("```", "\n- ", "\n* ", "\n1.", "Here's", "you can"))


class TrialScore(NamedTuple):
    """Multi-axis score for a single trial. All flags are independent."""

    did_attempt: bool
    hallucinated_tools: bool
    is_correct: bool                    # composite from judge_score
    refusal_with_instruction: bool      # EVAL-075: teach-the-user mode
    judge_score: float
    judge_threshold: float


def score_trial(text: str, judge_score: float, judge_threshold: float = 0.5) -> TrialScore:
    return TrialScore(
        did_attempt=detect_attempt(text, judge_score),
        hallucinated_tools=detect_hallucinated_tools(text),
        is_correct=judge_score >= judge_threshold,
        refusal_with_instruction=detect_refusal_with_instruction(text),
        judge_score=judge_score,
        judge_threshold=judge_threshold,
    )


def wilson_ci(passes: int, total: int, z: float = 1.96) -> tuple[float, float]:
    """Wilson 95% CI on a binomial proportion. Better than normal-approx for
    small samples and edge rates (0/1).

    Returns (lower, upper) bounds on the true rate.
    """
    if total == 0:
        return (0.0, 1.0)
    p = passes / total
    n = total
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = (z / denom) * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (max(0.0, centre - half), min(1.0, centre + half))


def cis_overlap(a_lo: float, a_hi: float, b_lo: float, b_hi: float) -> bool:
    """True if the two CIs overlap. Non-overlapping CIs are a (rough)
    indicator that the difference is statistically significant at ~p<0.05."""
    return not (a_hi < b_lo or b_hi < a_lo)


def delta_significance(a_pass: int, a_total: int, b_pass: int, b_total: int) -> dict:
    """Returns delta + per-cell CIs + an overlap flag.

    `cis_overlap = False` is the "this looks like signal" indicator.
    `cis_overlap = True` is "this is within sampling noise."
    """
    a_rate = (a_pass / a_total) if a_total else 0.0
    b_rate = (b_pass / b_total) if b_total else 0.0
    a_lo, a_hi = wilson_ci(a_pass, a_total)
    b_lo, b_hi = wilson_ci(b_pass, b_total)
    return {
        "delta": a_rate - b_rate,
        "a_rate": a_rate,
        "a_ci": [a_lo, a_hi],
        "b_rate": b_rate,
        "b_ci": [b_lo, b_hi],
        "cis_overlap": cis_overlap(a_lo, a_hi, b_lo, b_hi),
        "interpretation": (
            "within noise band — do NOT cite as a finding"
            if cis_overlap(a_lo, a_hi, b_lo, b_hi)
            else "non-overlapping CIs — provisional signal, replicate before citing"
        ),
    }
