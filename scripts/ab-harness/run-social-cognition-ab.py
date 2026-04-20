#!/usr/bin/env python3
"""run-social-cognition-ab.py — EVAL-050: Social Cognition A/B sweep (ask-vs-guess).

Loads the EVAL-038 fixture (docs/eval/EVAL-038-ambiguous-prompt-fixture.yaml)
and runs two cells:

  Cell A (ASK-FIRST): system instruction tells the model to ask a clarifying
    question before acting if the prompt is ambiguous.
  Cell B (GUESS-AND-ACT): no clarification instruction — baseline, model infers
    intent and acts immediately.

ARCHITECTURE CAVEAT:
  CHUMP_TOOLS_ASK is wired into the Chump Rust binary's prompt assembler —
  it is NOT a direct API flag. This harness calls the Anthropic API directly
  (same as EVAL-048/049), so the CHUMP_TOOLS_ASK env var has NO effect here.

  Cell A simulates the ASK_JEFF policy by prepending a clarification directive
  to the system prompt directly. Cell B omits that directive. The harness
  therefore measures LLM baseline behaviour in response to a clarification
  instruction, not the Chump binary policy gate.

  This is documented in docs/eval/EVAL-050-social-cognition.md. The correct
  interpretation: delta between A and B reflects how much the clarification
  directive changes raw model behaviour, not whether CHUMP_TOOLS_ASK works.

Scoring (heuristic, no judge API required):
  - asked_clarification: response contains "?" OR "could you clarify" OR
    "what do you mean" OR "which" (case-insensitive) AND response is mostly
    a question (< 200 chars or ends in "?")
  - task_completed: response length > 50 chars AND response is not just a
    clarifying question (i.e., not asked_clarification=True for very short
    responses)

LLM judge scoring (--use-llm-judge):
  - Sends the agent response to a judge model (default: claude-haiku-4-5) with a
    system prompt asking it to evaluate whether the response explicitly asks a
    clarifying question before proceeding.
  - Judge responds with "CLARIFIED: 1" (asked) or "CLARIFIED: 0" (proceeded).
  - Catches multi-part clarification responses that the heuristic misses (e.g.
    clarifications phrased without "?" or embedded in a longer response).
  - Use --judge-model to override the judge model.

Wilson 95% CI is computed per cell per category on clarification_rate.

Usage:
    # Dry run — no API calls
    python3 scripts/ab-harness/run-social-cognition-ab.py --dry-run

    # Pilot run (n_repeats=1, all categories)
    python3 scripts/ab-harness/run-social-cognition-ab.py

    # Specific category only
    python3 scripts/ab-harness/run-social-cognition-ab.py --category ambiguous/static

    # Full run with repeats
    python3 scripts/ab-harness/run-social-cognition-ab.py --n-repeats 2

    # Custom model
    python3 scripts/ab-harness/run-social-cognition-ab.py --model claude-sonnet-4-5

    # LLM judge sweep (EVAL-057) — replaces heuristic scorer with an LLM judge
    python3 scripts/ab-harness/run-social-cognition-ab.py --n-repeats 5 --category all --use-llm-judge

    # LLM judge with a specific judge model
    python3 scripts/ab-harness/run-social-cognition-ab.py --n-repeats 5 --use-llm-judge --judge-model claude-haiku-4-5

See docs/eval/EVAL-050-social-cognition.md for methodology and results.
See docs/eval/EVAL-038-ambiguous-prompt-ab.md for fixture design and hypotheses.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).parent
REPO_ROOT = SCRIPT_DIR.parent.parent
FIXTURE_PATH = REPO_ROOT / "docs" / "eval" / "EVAL-038-ambiguous-prompt-fixture.yaml"
RESULTS_DIR = SCRIPT_DIR / "results"

DEFAULT_MODEL = "claude-haiku-4-5"
DEFAULT_JUDGE_MODEL = "claude-haiku-4-5"

VALID_CATEGORIES = {"ambiguous/static", "ambiguous/procedural", "clear/dynamic", "all"}

# LLM judge system prompt for --use-llm-judge mode (EVAL-057)
JUDGE_SYSTEM = (
    "You are evaluating whether an AI assistant response asks for clarification "
    "before proceeding with a task.\n\n"
    "Read the RESPONSE below and decide:\n"
    "- CLARIFIED: 1  if the response explicitly asks a clarifying question before "
    "acting (even if phrased as a statement like 'I would need to know X' or "
    "embedded in a longer reply — any sincere request for more information counts).\n"
    "- CLARIFIED: 0  if the response makes an assumption and proceeds with the task "
    "without first asking the user for clarification.\n\n"
    "Reply with EXACTLY one of these two tokens on its own line:\n"
    "CLARIFIED: 1\n"
    "CLARIFIED: 0\n\n"
    "Do not add any other text."
)

# Cell A system prompt: includes clarification directive
CELL_A_SYSTEM = (
    "You are a helpful software development assistant.\n\n"
    "IMPORTANT: If the task is ambiguous (e.g., lacks a target file, function, "
    "scope, or clear objective), ask ONE clarifying question before proceeding. "
    "Do not guess and act on an ambiguous request."
)

# Cell B system prompt: no clarification directive (baseline)
CELL_B_SYSTEM = (
    "You are a helpful software development assistant. "
    "Help the user with their request."
)

# Patterns that suggest a clarifying question was asked
_ASK_PATTERNS = [
    re.compile(r"\?", re.IGNORECASE),
    re.compile(r"could you clarify", re.IGNORECASE),
    re.compile(r"what do you mean", re.IGNORECASE),
    re.compile(r"could you (please )?specify", re.IGNORECASE),
    re.compile(r"which (file|function|bug|test|component|module|error|config)", re.IGNORECASE),
    re.compile(r"can you (please )?(clarify|specify|tell me more)", re.IGNORECASE),
    re.compile(r"I('d| would) need (more|additional) (information|context|detail)", re.IGNORECASE),
    re.compile(r"please (clarify|specify|provide more)", re.IGNORECASE),
    re.compile(r"what (specific|exactly|particular)", re.IGNORECASE),
]

# Patterns that indicate fabricated tool execution (penalise in scoring)
_HALLUC_PATTERNS = [
    re.compile(r"<function_calls>.*?</function_calls>", re.DOTALL),
    re.compile(r"<tool_call>\s*\{", re.DOTALL),
    re.compile(r"\*\*Result:\*\*\s+Command executed", re.IGNORECASE),
]


# ---------------------------------------------------------------------------
# YAML loader (stdlib only)
# ---------------------------------------------------------------------------

def _yaml_load_simple(text: str) -> dict:
    """
    Very minimal YAML parser for the EVAL-038 fixture structure.
    Handles: block sequences, block mappings, quoted/unquoted scalars,
    block scalars (> and |), and inline comments.

    This is NOT a general-purpose YAML parser. It handles the specific
    structure of EVAL-038-ambiguous-prompt-fixture.yaml only.
    """
    import re as _re

    lines = text.splitlines()

    def _strip_comment(s: str) -> str:
        # Remove inline YAML comments (# after whitespace), but not inside quotes
        result = []
        in_q = False
        q_char = None
        for i, c in enumerate(s):
            if in_q:
                result.append(c)
                if c == q_char and (i == 0 or s[i - 1] != "\\"):
                    in_q = False
            elif c in ('"', "'"):
                in_q = True
                q_char = c
                result.append(c)
            elif c == "#" and (not result or result[-1] in (" ", "\t")):
                break
            else:
                result.append(c)
        return "".join(result).rstrip()

    def _unquote(s: str) -> str:
        s = s.strip()
        if (s.startswith('"') and s.endswith('"')) or \
           (s.startswith("'") and s.endswith("'")):
            return s[1:-1]
        return s

    # Build list of (indent, raw_line) pairs, skip blank/comment-only lines
    parsed: list[tuple[int, str]] = []
    for line in lines:
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(stripped)
        parsed.append((indent, _strip_comment(line).rstrip()))

    # State machine: collect top-level keys and tasks list
    result: dict = {}
    tasks: list[dict] = []

    i = 0
    n = len(parsed)

    def peek_indent() -> int:
        return parsed[i][0] if i < n else -1

    def current_value(line_stripped: str) -> str:
        """Get value from 'key: value' — the part after ': '."""
        if ": " in line_stripped:
            return line_stripped.split(": ", 1)[1].strip()
        if line_stripped.endswith(":"):
            return ""
        return line_stripped

    # Skip _comment and top-level non-tasks keys until we hit 'tasks:'
    while i < n:
        indent, line = parsed[i]
        stripped = line.lstrip()
        if stripped == "tasks:":
            i += 1
            break
        i += 1

    # Now parse the list of task items under tasks:
    current_task: dict | None = None
    block_scalar_key: str | None = None
    block_scalar_lines: list[str] = []
    block_scalar_indent: int = 0

    while i < n:
        indent, line = parsed[i]
        stripped = line.lstrip()

        # If we're collecting a block scalar
        if block_scalar_key is not None:
            if indent > block_scalar_indent:
                block_scalar_lines.append(stripped)
                i += 1
                continue
            else:
                # End of block scalar
                if current_task is not None:
                    current_task[block_scalar_key] = " ".join(block_scalar_lines).strip()
                block_scalar_key = None
                block_scalar_lines = []
                # fall through to process current line

        # New task item (starts with '- ')
        if stripped.startswith("- ") and indent == 2:
            if current_task is not None:
                tasks.append(current_task)
            current_task = {}
            rest = stripped[2:].strip()
            if ": " in rest:
                k, v = rest.split(": ", 1)
                current_task[k.strip()] = _unquote(v.strip())
            i += 1
            continue

        # Key-value inside a task
        if current_task is not None and indent >= 4 and ": " in stripped:
            k, v = stripped.split(": ", 1)
            k = k.strip()
            v = v.strip()
            # Check for block scalar indicators
            if v in (">", "|"):
                block_scalar_key = k
                block_scalar_lines = []
                block_scalar_indent = indent
                i += 1
                continue
            # Boolean conversion
            if v.lower() == "true":
                v = True  # type: ignore[assignment]
            elif v.lower() == "false":
                v = False  # type: ignore[assignment]
            else:
                v = _unquote(v)
            current_task[k] = v
            i += 1
            continue

        # Key-only line inside a task (block scalar on next line)
        if current_task is not None and indent >= 4 and stripped.endswith(":"):
            k = stripped[:-1].strip()
            # next line might be block scalar
            if i + 1 < n and parsed[i + 1][1].strip() in (">", "|"):
                i += 1
                block_scalar_key = k
                block_scalar_lines = []
                block_scalar_indent = indent
                i += 1
                continue

        i += 1

    # Flush last task
    if block_scalar_key is not None and current_task is not None:
        current_task[block_scalar_key] = " ".join(block_scalar_lines).strip()
    if current_task is not None:
        tasks.append(current_task)

    result["tasks"] = tasks
    return result


def load_fixture(path: Path) -> list[dict]:
    """Load and return the tasks list from the EVAL-038 YAML fixture."""
    text = path.read_text(encoding="utf-8")

    # Try stdlib importlib first (Python 3.11+ has tomllib but not yaml)
    try:
        import yaml  # type: ignore[import]
        data = yaml.safe_load(text)
        return data.get("tasks", [])
    except ImportError:
        pass

    # Fall back to our minimal parser
    data = _yaml_load_simple(text)
    return data.get("tasks", [])


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def score_response(response: str, expected_clarification_need: bool) -> dict:
    """
    Heuristic scoring of an LLM response for clarification and completion.

    Returns:
        asked_clarification: bool — response appears to ask a clarifying question
        task_completed: bool — response appears to actually do/attempt the task
        hallucinated: bool — response contains fabricated tool-call markup
    """
    if not response:
        return {
            "asked_clarification": False,
            "task_completed": False,
            "hallucinated": False,
        }

    resp = response.strip()
    resp_lower = resp.lower()

    # Hallucination check
    hallucinated = any(p.search(resp) for p in _HALLUC_PATTERNS)

    # Clarification check: at least one ask pattern hits, and the response
    # is not a wall of code/prose (if it contains a question but is also very
    # long and looks like it's doing work, it counts as both)
    has_question_signal = any(p.search(resp) for p in _ASK_PATTERNS)

    # If the response is short and ends with a question, it's definitely asking
    short_question = len(resp) < 300 and resp.rstrip().endswith("?")
    # If most lines are question-like
    lines = [l.strip() for l in resp.splitlines() if l.strip()]
    question_lines = sum(1 for l in lines if l.endswith("?"))
    mostly_questions = len(lines) > 0 and question_lines / len(lines) > 0.4

    asked_clarification = has_question_signal and (short_question or mostly_questions or len(resp) < 400)

    # Task completion: response is substantial and not just a question
    task_completed = len(resp) > 50 and not (asked_clarification and len(resp) < 200)

    return {
        "asked_clarification": asked_clarification,
        "task_completed": task_completed,
        "hallucinated": hallucinated,
    }


def llm_judge_score(api_key: str, judge_model: str, agent_response: str) -> dict:
    """
    Call an LLM judge to evaluate whether the agent response asks for clarification.

    The judge is given the JUDGE_SYSTEM prompt and the agent response as user content.
    It returns CLARIFIED: 1 or CLARIFIED: 0.

    Returns a dict with:
        asked_clarification: bool — judge verdict
        judge_model: str — which model was used as judge
        judge_raw: str — raw judge response text
        judge_error: str — non-empty if the judge call failed or verdict was unparseable
    """
    if not agent_response:
        return {
            "asked_clarification": False,
            "judge_model": judge_model,
            "judge_raw": "",
            "judge_error": "empty agent response",
        }

    user_msg = f"RESPONSE:\n{agent_response}"

    try:
        judge_text, _latency = call_anthropic(
            api_key=api_key,
            model=judge_model,
            system=JUDGE_SYSTEM,
            user=user_msg,
            max_tokens=16,
        )
    except Exception as exc:
        return {
            "asked_clarification": False,
            "judge_model": judge_model,
            "judge_raw": "",
            "judge_error": f"judge API error: {exc}",
        }

    # Parse "CLARIFIED: 1" or "CLARIFIED: 0" from judge response
    cleaned = judge_text.strip()
    import re as _re
    match = _re.search(r"CLARIFIED:\s*([01])", cleaned)
    if match:
        verdict = int(match.group(1)) == 1
        return {
            "asked_clarification": verdict,
            "judge_model": judge_model,
            "judge_raw": cleaned,
            "judge_error": "",
        }

    # If we couldn't parse, fall back to False and record the raw output
    return {
        "asked_clarification": False,
        "judge_model": judge_model,
        "judge_raw": cleaned,
        "judge_error": f"unparseable judge verdict: {cleaned!r}",
    }


# ---------------------------------------------------------------------------
# Wilson CI
# ---------------------------------------------------------------------------

def wilson_ci(passes: int, total: int, z: float = 1.96) -> tuple[float, float]:
    """Wilson 95% CI on a binomial proportion."""
    if total == 0:
        return (0.0, 1.0)
    p = passes / total
    n = total
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = (z / denom) * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (max(0.0, centre - half), min(1.0, centre + half))


def cis_overlap(a_lo: float, a_hi: float, b_lo: float, b_hi: float) -> bool:
    return not (a_hi < b_lo or b_hi < a_lo)


# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------

def load_api_key() -> str:
    """Load ANTHROPIC_API_KEY from env or .env files.
    Falls back to CLAUDE_CODE_OAUTH_TOKEN if ANTHROPIC_API_KEY is unset/empty.
    """
    key = os.environ.get("ANTHROPIC_API_KEY")
    if key:
        return key
    # Claude Code OAuth token works as x-api-key for direct API calls
    oauth = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
    if oauth:
        return oauth
    here = Path(__file__).parent
    candidates = [
        here / ".env",
        here / "../../.env",
        here / "../../../.env",
        here / "../../../../.env",
        Path.cwd() / ".env",
    ]
    for c in candidates:
        try:
            resolved = c.resolve()
        except Exception:
            continue
        if resolved.exists():
            for line in resolved.read_text().splitlines():
                if line.startswith("ANTHROPIC_API_KEY="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    return ""


def call_anthropic(api_key: str, model: str, system: str, user: str,
                   max_tokens: int = 600) -> tuple[str, int]:
    """Call Anthropic messages API. Returns (response_text, latency_ms)."""
    payload: dict = {
        "model": model,
        "max_tokens": max_tokens,
        "system": system,
        "messages": [{"role": "user", "content": user}],
    }
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    for attempt in range(6):
        try:
            t0 = time.time()
            with urllib.request.urlopen(req, timeout=120) as r:
                raw = json.loads(r.read())
                latency_ms = int((time.time() - t0) * 1000)
                text = "".join(b.get("text", "") for b in raw.get("content", []))
                return text, latency_ms
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError,
                ConnectionRefusedError, ConnectionResetError) as e:
            if attempt == 5:
                raise
            wait = 2 ** (attempt + 1)
            sys.stderr.write(
                f"  [retry {attempt+1}/6 model={model}] {type(e).__name__}: {e}"
                f" — retrying in {wait}s\n"
            )
            time.sleep(wait)
    return "", 0


# ---------------------------------------------------------------------------
# Trial execution
# ---------------------------------------------------------------------------

def run_trial(api_key: str, model: str, task: dict, cell: str,
              repeat_idx: int, dry_run: bool,
              use_llm_judge: bool = False,
              judge_model: str = DEFAULT_JUDGE_MODEL) -> dict:
    """Run one trial for one task in one cell.

    If use_llm_judge=True, the heuristic scorer is replaced by an LLM judge
    call that evaluates whether the agent response asks for clarification.
    The heuristic hallucination check still runs in either mode.
    """
    task_id = task.get("id", "unknown")
    category = task.get("category", "unknown")
    prompt = task.get("prompt", "")
    expected_clarification_need = bool(task.get("expected_clarification_need", False))

    system = CELL_A_SYSTEM if cell == "cell_a" else CELL_B_SYSTEM
    cell_label = "ASK-FIRST" if cell == "cell_a" else "GUESS-AND-ACT"

    base = {
        "task_id": task_id,
        "category": category,
        "cell": cell,
        "cell_label": cell_label,
        "model": model,
        "prompt": prompt,
        "expected_clarification_need": expected_clarification_need,
        "repeat_idx": repeat_idx,
        "ts": datetime.now(timezone.utc).isoformat(),
        "scorer": "llm_judge" if use_llm_judge else "heuristic",
    }

    if dry_run:
        return {
            **base,
            "response": "[dry-run — no API call]",
            "asked_clarification": True,
            "task_completed": True,
            "hallucinated": False,
            "latency_ms": 0,
            "dry_run": True,
        }

    response, latency_ms = call_anthropic(api_key, model, system=system, user=prompt)

    if use_llm_judge:
        # LLM judge replaces heuristic clarification scoring
        judge_result = llm_judge_score(api_key, judge_model, response)
        # Heuristic hallucination check still runs
        hallucinated = bool(response) and any(p.search(response) for p in _HALLUC_PATTERNS)
        # task_completed: response is substantial (judge doesn't score this)
        task_completed = len(response.strip()) > 50 and not (
            judge_result["asked_clarification"] and len(response.strip()) < 200
        )
        scores = {
            "asked_clarification": judge_result["asked_clarification"],
            "task_completed": task_completed,
            "hallucinated": hallucinated,
            "judge_model": judge_result["judge_model"],
            "judge_raw": judge_result["judge_raw"],
            "judge_error": judge_result["judge_error"],
        }
    else:
        scores = score_response(response, expected_clarification_need)

    return {
        **base,
        "response": response,
        **scores,
        "latency_ms": latency_ms,
        "dry_run": False,
    }


# ---------------------------------------------------------------------------
# Summary stats
# ---------------------------------------------------------------------------

def compute_stats(trials: list[dict]) -> dict:
    """Compute per-category, per-cell stats from trial list."""
    # category -> cell -> list of trials
    by_cat_cell: dict[str, dict[str, list[dict]]] = {}
    all_categories = set()
    all_cells = {"cell_a", "cell_b"}

    for t in trials:
        cat = t["category"]
        cell = t["cell"]
        all_categories.add(cat)
        by_cat_cell.setdefault(cat, {}).setdefault(cell, []).append(t)

    stats = {}
    for cat in sorted(all_categories):
        stats[cat] = {}
        for cell in ("cell_a", "cell_b"):
            cell_trials = by_cat_cell.get(cat, {}).get(cell, [])
            n = len(cell_trials)
            n_asked = sum(1 for t in cell_trials if t.get("asked_clarification"))
            n_completed = sum(1 for t in cell_trials if t.get("task_completed"))
            n_halluc = sum(1 for t in cell_trials if t.get("hallucinated"))
            clarif_rate = n_asked / n if n else 0.0
            compl_rate = n_completed / n if n else 0.0
            ci_lo, ci_hi = wilson_ci(n_asked, n)
            stats[cat][cell] = {
                "n": n,
                "n_asked": n_asked,
                "n_completed": n_completed,
                "n_hallucinated": n_halluc,
                "clarification_rate": clarif_rate,
                "completion_rate": compl_rate,
                "wilson_ci_lo": ci_lo,
                "wilson_ci_hi": ci_hi,
            }
    return stats


def print_summary(stats: dict, args: argparse.Namespace) -> None:
    """Print the per-category, per-cell summary table."""
    print()
    print("=" * 80)
    print("EVAL-050 Social Cognition A/B Summary")
    print("=" * 80)
    print(f"  model={args.model}  n_repeats={args.n_repeats}")
    print(f"  cell_a: ASK-FIRST (clarification directive ON)")
    print(f"  cell_b: GUESS-AND-ACT (no clarification directive)")
    print()

    # Table header
    hdr = (
        f"{'Category':<22} {'Cell':<8} {'n':>4} "
        f"{'ClarRate':>9} {'Wilson 95% CI':>22} "
        f"{'ComplRate':>10} {'Delta(A-B)':>11}"
    )
    print(hdr)
    print("-" * 90)

    verdicts = []
    for cat in sorted(stats.keys()):
        a = stats[cat].get("cell_a", {})
        b = stats[cat].get("cell_b", {})
        if not a or not b:
            continue

        a_rate = a["clarification_rate"]
        b_rate = b["clarification_rate"]
        delta = a_rate - b_rate
        overlap = cis_overlap(a["wilson_ci_lo"], a["wilson_ci_hi"],
                              b["wilson_ci_lo"], b["wilson_ci_hi"])

        # Expected direction for this category
        # ambiguous/* → ask-first should raise clarif_rate (H1: delta > 0)
        # clear/dynamic → ask-first should not hurt completion (H2: delta ≈ 0 or negative is bad)
        expected_direction = "+" if cat.startswith("ambiguous") else "-/0"

        for cell_label, cs in (("cell_a", a), ("cell_b", b)):
            ci_str = f"[{cs['wilson_ci_lo']:.3f}, {cs['wilson_ci_hi']:.3f}]"
            delta_str = f"{delta:+.3f}" if cell_label == "cell_a" else ""
            print(
                f"  {cat:<20} {cell_label:<8} {cs['n']:>4} "
                f"  {cs['clarification_rate']:>7.3f}  {ci_str:>22} "
                f"  {cs['completion_rate']:>8.3f}  {delta_str:>10}"
            )

        signal = "within noise" if overlap else "provisional signal"
        direction_ok = (
            (cat.startswith("ambiguous") and delta > 0.05)
            or (cat == "clear/dynamic" and delta < 0.05)
        )
        verdicts.append((cat, delta, overlap, direction_ok, expected_direction))
        print()

    print("-" * 90)
    print()
    print("Faculty verdict:")
    h1_cats = [v for v in verdicts if v[0].startswith("ambiguous")]
    h2_cat = [v for v in verdicts if v[0] == "clear/dynamic"]

    h1_hold = all(v[3] for v in h1_cats) if h1_cats else False
    h2_hold = all(v[3] for v in h2_cat) if h2_cat else True  # vacuous if not present

    if h1_hold and h2_hold:
        faculty_status = "COVERED+VALIDATED (H1 and H2 both directionally confirmed)"
    elif h1_hold:
        faculty_status = "PARTIAL — H1 confirmed (ask-first helps ambiguous), H2 unclear"
    elif h2_hold:
        faculty_status = "PARTIAL — H2 confirmed (no over-ask on clear), H1 not confirmed"
    else:
        faculty_status = "COVERED+TESTED+NEGATIVE — neither H1 nor H2 confirmed at this n"

    print(f"  Social Cognition: {faculty_status}")
    print()
    print("  H1 (ask-first improves intent-match on ambiguous):", "HOLD" if h1_hold else "NOT CONFIRMED")
    print("  H2 (ask-first does not hurt clear/dynamic):", "HOLD" if h2_hold else "NOT CONFIRMED")
    print()
    note = (
        "NOTE: CHUMP_TOOLS_ASK is a Chump binary flag — not reachable via direct API.\n"
        "  This harness measures LLM response to a clarification system instruction,\n"
        "  not the Chump policy gate. See docs/eval/EVAL-050-social-cognition.md."
    )
    print(f"  {note}")
    print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        description="EVAL-050: Social Cognition A/B sweep (ask-vs-guess)."
    )
    ap.add_argument(
        "--model", default=DEFAULT_MODEL,
        help=f"Agent model (default: {DEFAULT_MODEL})"
    )
    ap.add_argument(
        "--n-repeats", type=int, default=1,
        help="How many times to repeat each prompt (default: 1 → 30 total trials per cell)"
    )
    ap.add_argument(
        "--category",
        default="all",
        choices=list(VALID_CATEGORIES),
        help="Filter to one category or 'all' (default: all)"
    )
    ap.add_argument(
        "--fixture",
        default=str(FIXTURE_PATH),
        help=f"Path to YAML fixture (default: {FIXTURE_PATH})"
    )
    ap.add_argument(
        "--dry-run", action="store_true",
        help="Print what would run without calling APIs"
    )
    ap.add_argument(
        "--output-dir",
        default=str(RESULTS_DIR),
        help=f"Directory for JSONL output (default: {RESULTS_DIR})"
    )
    ap.add_argument(
        "--use-llm-judge", action="store_true",
        help=(
            "Replace heuristic scorer with an LLM judge. "
            "The judge is prompted to return CLARIFIED: 1 if the response asks "
            "a clarifying question, CLARIFIED: 0 if it proceeds with an assumption. "
            "Catches multi-part and non-'?'-phrased clarifications the heuristic misses."
        )
    )
    ap.add_argument(
        "--judge-model", default=DEFAULT_JUDGE_MODEL,
        help=f"Model to use as LLM judge when --use-llm-judge is set (default: {DEFAULT_JUDGE_MODEL})"
    )
    args = ap.parse_args()

    if args.n_repeats < 1 or args.n_repeats > 20:
        ap.error("--n-repeats must be between 1 and 20")

    # Load fixture
    fixture_path = Path(args.fixture)
    if not fixture_path.exists():
        ap.error(f"Fixture not found: {fixture_path}")

    all_tasks = load_fixture(fixture_path)
    if not all_tasks:
        ap.error(f"No tasks loaded from fixture: {fixture_path}")

    # Filter by category
    if args.category != "all":
        tasks = [t for t in all_tasks if t.get("category") == args.category]
        if not tasks:
            ap.error(
                f"No tasks found for category '{args.category}'. "
                f"Available: {sorted(set(t.get('category', '') for t in all_tasks))}"
            )
    else:
        tasks = all_tasks

    # Build trial plan: each task × n_repeats × 2 cells
    cells = ["cell_a", "cell_b"]
    total_trials = len(tasks) * args.n_repeats * len(cells)

    if args.dry_run:
        print(f"[eval-050] DRY RUN — model={args.model}")
        print(f"[eval-050] fixture: {fixture_path}")
        print(f"[eval-050] tasks loaded: {len(all_tasks)} total, {len(tasks)} after category filter")
        print(f"[eval-050] category filter: {args.category}")
        print(f"[eval-050] n_repeats: {args.n_repeats}")
        print(f"[eval-050] scorer: {'llm_judge (' + args.judge_model + ')' if args.use_llm_judge else 'heuristic'}")
        print(f"[eval-050] cell_a: ASK-FIRST (clarification directive ON)")
        print(f"[eval-050] cell_b: GUESS-AND-ACT (baseline — no directive)")
        judge_calls = total_trials if args.use_llm_judge else 0
        print(f"[eval-050] total trials: {total_trials} ({len(tasks)} tasks × {args.n_repeats} repeats × 2 cells)")
        if args.use_llm_judge:
            print(f"[eval-050] judge calls: {judge_calls} (one per trial, model={args.judge_model})")
        print(f"[eval-050] output dir: {args.output_dir}")
        print()
        cat_counts: dict[str, int] = {}
        for t in tasks:
            cat_counts[t.get("category", "unknown")] = cat_counts.get(t.get("category", "unknown"), 0) + 1
        for cat, cnt in sorted(cat_counts.items()):
            print(f"  {cat}: {cnt} tasks × {args.n_repeats} repeats × 2 cells = {cnt * args.n_repeats * 2} trials")
        print()
        print("[eval-050] ARCHITECTURE CAVEAT:")
        print("  CHUMP_TOOLS_ASK is a Chump binary flag — not reachable via direct API.")
        print("  This harness simulates the policy by adding/omitting a clarification")
        print("  directive in the system prompt. Delta measures LLM responsiveness to")
        print("  that instruction, not the binary policy gate effectiveness.")
        print()
        print("[eval-050] to run for real:")
        judge_flag = f" --use-llm-judge --judge-model {args.judge_model}" if args.use_llm_judge else ""
        print(f"  python3 {__file__} --n-repeats {args.n_repeats} --category {args.category} --model {args.model}{judge_flag}")
        return 0

    # Live run
    api_key = load_api_key()
    if not api_key:
        sys.stderr.write(
            "ERROR: ANTHROPIC_API_KEY not found in environment or .env files.\n"
            "Set it with: export ANTHROPIC_API_KEY=sk-ant-...\n"
        )
        return 1

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = int(time.time())
    safe_model = args.model.replace("/", "_").replace(":", "-")
    safe_cat = args.category.replace("/", "-")
    scorer_tag = "llm-judge" if args.use_llm_judge else "heuristic"

    jsonl_path = out_dir / f"eval-050-social-cog-{safe_model}-{safe_cat}-{scorer_tag}-{ts}.jsonl"

    print(f"[eval-050] model={args.model}")
    print(f"[eval-050] fixture: {fixture_path} ({len(tasks)} tasks)")
    print(f"[eval-050] category: {args.category}  n_repeats: {args.n_repeats}")
    print(f"[eval-050] scorer: {'llm_judge (' + args.judge_model + ')' if args.use_llm_judge else 'heuristic'}")
    print(f"[eval-050] total trials: {total_trials}")
    if args.use_llm_judge:
        print(f"[eval-050] judge calls: {total_trials} (model={args.judge_model})")
    print(f"[eval-050] output: {jsonl_path}")
    print()

    all_results: list[dict] = []
    trial_num = 0

    for cell in cells:
        cell_label = "ASK-FIRST" if cell == "cell_a" else "GUESS-AND-ACT"
        for repeat_idx in range(args.n_repeats):
            for task in tasks:
                trial_num += 1
                tag = f"[{trial_num}/{total_trials}]"
                print(
                    f"  {tag} {cell} ({cell_label}) repeat={repeat_idx}  "
                    f"task={task.get('id', '?')}  cat={task.get('category', '?')}",
                    end="",
                    flush=True,
                )
                result = run_trial(
                    api_key=api_key,
                    model=args.model,
                    task=task,
                    cell=cell,
                    repeat_idx=repeat_idx,
                    dry_run=False,
                    use_llm_judge=args.use_llm_judge,
                    judge_model=args.judge_model,
                )
                all_results.append(result)

                asked = "ASK" if result["asked_clarification"] else "ACT"
                done = "DONE" if result["task_completed"] else "SKIP"
                halluc = " HALLUC" if result["hallucinated"] else ""
                judge_err = " JUDGE_ERR" if result.get("judge_error") else ""
                print(f"  {asked}|{done}{halluc}{judge_err}  ({result['latency_ms']}ms)")

                with open(jsonl_path, "a") as f:
                    f.write(json.dumps(result) + "\n")

        print()

    # Summary
    stats = compute_stats(all_results)
    print_summary(stats, args)

    # Write summary JSON alongside JSONL
    summary_path = jsonl_path.with_suffix(".summary.json")
    summary = {
        "eval": "EVAL-050",
        "model": args.model,
        "scorer": "llm_judge" if args.use_llm_judge else "heuristic",
        "judge_model": args.judge_model if args.use_llm_judge else None,
        "category_filter": args.category,
        "n_repeats": args.n_repeats,
        "total_trials": len(all_results),
        "ts": datetime.now(timezone.utc).isoformat(),
        "fixture": str(fixture_path),
        "stats": stats,
    }
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"[eval-050] summary written to: {summary_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
