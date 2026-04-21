#!/usr/bin/env python3.12
"""
EVAL-049 — Binary-mode ablation harness.

Runs CHUMP_BYPASS_* env-var sweeps through the chump Rust binary so that
belief_state, surprisal EMA, and neuromodulation can be measured in real
binary execution (not via direct API calls).

Motivation: run-ablation-sweep.py and run-cloud-v2.py call the Anthropic API
directly — the chump binary is never invoked, so CHUMP_BYPASS_* flags have no
effect. This script fixes that by invoking `chump --chump "<task>"` in a
subprocess with the relevant env var set for Cell B (bypass active).

EVAL-060 additions:
  --use-llm-judge   Replace exit-code scoring with LLM judge (claude-haiku-4-5).
                    The judge receives the task prompt and the binary's stdout and
                    replies CORRECT: 1 or CORRECT: 0. Falls back to exit-code
                    scoring if the judge call fails. Required for any publishable
                    ablation result.
  --aa-baseline     Cell B also uses bypass=OFF (same as Cell A). Use to validate
                    the instrument: A/A delta must be ≈0. Run this before any
                    real sweep.

Usage:
    python3 scripts/ab-harness/run-binary-ablation.py \\
        --module all \\
        --n-per-cell 5 \\
        --dry-run

    python3 scripts/ab-harness/run-binary-ablation.py \\
        --module belief_state \\
        --n-per-cell 30 \\
        --binary ./target/release/chump

    # A/A calibration check (instrument validation):
    python3 scripts/ab-harness/run-binary-ablation.py \\
        --module belief_state \\
        --n-per-cell 30 \\
        --use-llm-judge \\
        --aa-baseline

Dependencies: subprocess, json, math, argparse, datetime, os, sys, time (stdlib).
              Optional: anthropic (pip install anthropic) for --use-llm-judge.
              Falls back to requests if anthropic SDK not installed.
"""

import argparse
import datetime
import json
import math
import os
import subprocess
import sys
import time
from datetime import timezone

# ---------------------------------------------------------------------------
# Task set — same domain as EVAL-043 fixtures; self-contained so no fixture
# file is required and --dry-run works with zero dependencies.
# ---------------------------------------------------------------------------

TASKS = [
    {"id": "t001", "category": "factual", "prompt": "What is 17 multiplied by 23?"},
    {"id": "t002", "category": "factual", "prompt": "Name the capital city of Japan."},
    {"id": "t003", "category": "reasoning", "prompt": "If all A are B and all B are C, are all A also C? Answer yes or no and briefly explain."},
    {"id": "t004", "category": "reasoning", "prompt": "A bat and ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost?"},
    {"id": "t005", "category": "factual", "prompt": "What programming language was Rust originally developed by Mozilla?"},
    {"id": "t006", "category": "instruction", "prompt": "List the three primary colours in painting."},
    {"id": "t007", "category": "reasoning", "prompt": "Sort the following numbers in ascending order: 7, 2, 9, 1, 4."},
    {"id": "t008", "category": "factual", "prompt": "How many sides does a hexagon have?"},
    {"id": "t009", "category": "instruction", "prompt": "Give a one-sentence summary of what HTTP stands for."},
    {"id": "t010", "category": "reasoning", "prompt": "If today is Wednesday and you add 10 days, what day of the week is it?"},
    {"id": "t011", "category": "factual", "prompt": "What is the chemical symbol for gold?"},
    {"id": "t012", "category": "instruction", "prompt": "Write a Python function that returns the square of a number."},
    {"id": "t013", "category": "reasoning", "prompt": "A shop sells apples for $0.50 each. If you buy 6 apples with a $5 bill, how much change do you receive?"},
    {"id": "t014", "category": "factual", "prompt": "In which year did World War II end?"},
    {"id": "t015", "category": "instruction", "prompt": "Explain in one sentence what a binary search algorithm does."},
    {"id": "t016", "category": "reasoning", "prompt": "If a train travels at 60 mph and needs to cover 150 miles, how many hours will the journey take?"},
    {"id": "t017", "category": "factual", "prompt": "What is the SI unit of electric current?"},
    {"id": "t018", "category": "instruction", "prompt": "Name two advantages of using version control systems like git."},
    {"id": "t019", "category": "reasoning", "prompt": "There are 5 red balls and 3 blue balls in a bag. What fraction of the balls are blue?"},
    {"id": "t020", "category": "factual", "prompt": "What does CPU stand for in computing?"},
    {"id": "t021", "category": "instruction", "prompt": "Describe what a deadlock is in operating systems in two sentences."},
    {"id": "t022", "category": "reasoning", "prompt": "If x + 5 = 12, what is x?"},
    {"id": "t023", "category": "factual", "prompt": "Which planet in our solar system has the most moons?"},
    {"id": "t024", "category": "instruction", "prompt": "What is the difference between a stack and a queue data structure?"},
    {"id": "t025", "category": "reasoning", "prompt": "A rectangle has a length of 8 cm and a width of 5 cm. What is its perimeter?"},
    {"id": "t026", "category": "factual", "prompt": "What is the boiling point of water at sea level in Celsius?"},
    {"id": "t027", "category": "instruction", "prompt": "List three key principles of object-oriented programming."},
    {"id": "t028", "category": "reasoning", "prompt": "If you flip a fair coin 3 times, how many possible outcomes are there?"},
    {"id": "t029", "category": "factual", "prompt": "What does RAM stand for in computing?"},
    {"id": "t030", "category": "instruction", "prompt": "In one sentence, explain what a hash function does."},
]

# ---------------------------------------------------------------------------
# Module → bypass env-var mapping
# ---------------------------------------------------------------------------

MODULES = {
    "belief_state": "CHUMP_BYPASS_BELIEF_STATE",
    "surprisal": "CHUMP_BYPASS_SURPRISAL",
    "neuromod": "CHUMP_BYPASS_NEUROMOD",
    "spawn_lessons": "CHUMP_BYPASS_SPAWN_LESSONS",
    "blackboard": "CHUMP_BYPASS_BLACKBOARD",
    "perception": "CHUMP_BYPASS_PERCEPTION",
}

# ---------------------------------------------------------------------------
# LLM judge (EVAL-060) — replaces exit-code scoring with semantic correctness
# ---------------------------------------------------------------------------

_JUDGE_MODEL = "claude-haiku-4-5"
_JUDGE_MAX_TOKENS = 20

_JUDGE_PROMPT_TEMPLATE = """\
Task: {task_prompt}
AI Response: {ai_response}

Did the AI response correctly address the task? Reply with exactly: CORRECT: 1 or CORRECT: 0"""


def _call_judge_anthropic_sdk(task_prompt: str, ai_response: str) -> bool | None:
    """Call the judge via the anthropic Python SDK. Returns True/False or None on error."""
    try:
        import anthropic  # type: ignore
    except ImportError:
        return None  # SDK not installed — caller will try requests fallback

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        return None

    client = anthropic.Anthropic(api_key=api_key)
    prompt = _JUDGE_PROMPT_TEMPLATE.format(
        task_prompt=task_prompt,
        ai_response=ai_response if ai_response.strip() else "(no output)",
    )
    try:
        message = client.messages.create(
            model=_JUDGE_MODEL,
            max_tokens=_JUDGE_MAX_TOKENS,
            messages=[{"role": "user", "content": prompt}],
        )
        verdict_text = message.content[0].text.strip()
        if "CORRECT: 1" in verdict_text:
            return True
        if "CORRECT: 0" in verdict_text:
            return False
        return None  # unparseable
    except Exception:
        return None


def _call_judge_requests(task_prompt: str, ai_response: str) -> bool | None:
    """Call the judge via raw HTTP requests (fallback when anthropic SDK absent)."""
    import urllib.request
    import urllib.error

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        return None

    prompt = _JUDGE_PROMPT_TEMPLATE.format(
        task_prompt=task_prompt,
        ai_response=ai_response if ai_response.strip() else "(no output)",
    )
    payload = json.dumps({
        "model": _JUDGE_MODEL,
        "max_tokens": _JUDGE_MAX_TOKENS,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=payload,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read())
        verdict_text = body["content"][0]["text"].strip()
        if "CORRECT: 1" in verdict_text:
            return True
        if "CORRECT: 0" in verdict_text:
            return False
        return None
    except Exception:
        return None


def llm_judge_correctness(task_prompt: str, ai_response: str) -> bool | None:
    """
    Ask claude-haiku-4-5 whether the AI response correctly addressed the task.

    Returns True (correct), False (incorrect), or None (judge call failed).
    None triggers fallback to exit-code scoring in the caller.

    Tries anthropic SDK first; falls back to raw urllib if SDK absent.
    """
    result = _call_judge_anthropic_sdk(task_prompt, ai_response)
    if result is None:
        result = _call_judge_requests(task_prompt, ai_response)
    return result


# ---------------------------------------------------------------------------
# Statistical helpers
# ---------------------------------------------------------------------------

def wilson_ci(n_successes: int, n: int, z: float = 1.96) -> tuple[float, float]:
    """Wilson score 95% confidence interval for a proportion."""
    if n == 0:
        return (0.0, 0.0)
    p_hat = n_successes / n
    denom = 1 + z * z / n
    centre = (p_hat + z * z / (2 * n)) / denom
    half = (z / denom) * math.sqrt(p_hat * (1 - p_hat) / n + z * z / (4 * n * n))
    return (max(0.0, centre - half), min(1.0, centre + half))


# ---------------------------------------------------------------------------
# Scoring heuristic
# ---------------------------------------------------------------------------

def score_trial(
    returncode: int,
    stdout: str,
    use_llm_judge: bool = False,
    task_prompt: str = "",
) -> dict:
    """
    Score a trial result.

    Default (use_llm_judge=False): EVAL-049 exit-code heuristic.
      correct = exit code 0 AND output length > 10 chars.
      NOTE: this is the broken instrument that EVAL-060 diagnoses — low baseline
      accuracy because chump almost always exits 1 without a live API key.

    LLM-judge path (use_llm_judge=True, requires ANTHROPIC_API_KEY):
      Calls claude-haiku-4-5 with the task prompt + stdout to assess semantic
      correctness. Falls back to exit-code heuristic if the judge call fails.

    Returns dict with keys: correct (bool), hallucination (bool), scorer (str).
    """
    hallucination = any(
        phrase in stdout for phrase in ["I cannot", "I don't know", "I can't", "I do not know"]
    )

    if use_llm_judge and task_prompt:
        judge_result = llm_judge_correctness(task_prompt, stdout)
        if judge_result is not None:
            return {
                "correct": judge_result,
                "hallucination": hallucination,
                "scorer": "llm_judge",
            }
        # Judge call failed — fall back to exit-code heuristic
        correct = (returncode == 0) and (len(stdout.strip()) > 10)
        return {
            "correct": correct,
            "hallucination": hallucination,
            "scorer": "exit_code_fallback",
        }

    # Default exit-code heuristic (EVAL-049 baseline, kept for backwards compatibility)
    correct = (returncode == 0) and (len(stdout.strip()) > 10)
    return {
        "correct": correct,
        "hallucination": hallucination,
        "scorer": "exit_code",
    }


# ---------------------------------------------------------------------------
# Trial runner
# ---------------------------------------------------------------------------

def run_trial(
    binary: str,
    task: dict,
    module: str,
    cell: str,  # "A" (bypass off) or "B" (bypass on)
    timeout_secs: int = 300,
    dry_run: bool = False,
    use_llm_judge: bool = False,
    aa_baseline: bool = False,
    agent_provider: str = "anthropic",
    agent_model: str | None = None,
) -> dict:
    """
    Run one trial and return a result dict suitable for JSONL output.
    cell="A" → normal run (bypass flag NOT set)
    cell="B" → ablation run (CHUMP_BYPASS_<MODULE>=1), unless aa_baseline=True
               in which case Cell B also runs with bypass=OFF (A/A calibration check).

    use_llm_judge: if True, score with claude-haiku-4-5 instead of exit-code heuristic.
    aa_baseline:   if True, both cells run with bypass=OFF. A/A delta should be ≈0.
                   Use this to validate the instrument before real sweeps.
    """
    bypass_var = MODULES[module]
    env = os.environ.copy()

    # Cell B: activate the bypass (unless A/A baseline mode — both cells bypass OFF)
    if cell == "B" and not aa_baseline:
        env[bypass_var] = "1"
    else:
        # Ensure bypass is explicitly disabled (Cell A always; Cell B in aa_baseline mode)
        env.pop(bypass_var, None)
        env[bypass_var] = "0"

    # RESEARCH-027: route the chump binary's LLM calls to the specified provider.
    if agent_provider == "together":
        together_key = os.environ.get("TOGETHER_API_KEY", "")
        if not together_key:
            raise RuntimeError("--agent-provider together requires TOGETHER_API_KEY in env")
        env["OPENAI_API_BASE"] = "https://api.together.xyz/v1"
        env["OPENAI_API_KEY"] = together_key
        if agent_model:
            env["OPENAI_MODEL"] = agent_model
    elif agent_provider == "ollama":
        ollama_base = os.environ.get("OLLAMA_BASE", "http://localhost:11434/v1")
        env["OPENAI_API_BASE"] = ollama_base
        env["OPENAI_API_KEY"] = "ollama"
        if agent_model:
            env["OPENAI_MODEL"] = agent_model

    # Clear session history between trials to prevent context contamination
    # (mirrors the run.sh session-clearing logic).
    chump_home = env.get("CHUMP_HOME", os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    session_file = os.path.join(chump_home, "sessions", "cli", "cli", "messages.json")
    if not dry_run and os.path.isfile(session_file):
        try:
            with open(session_file, "w") as f:
                f.write('{"session_id":"cli","messages":[],"time_stamp":"2025-11-19T00:00:00Z"}\n')
        except OSError:
            pass  # best-effort

    cmd = [binary, "--chump", task["prompt"]]

    if dry_run:
        bypass_on = cell == "B" and not aa_baseline
        env_prefix = f"{bypass_var}={'1' if bypass_on else '0'}"
        judge_tag = " [llm-judge]" if use_llm_judge else ""
        aa_tag = " [aa-baseline]" if aa_baseline else ""
        print(f"  [dry-run]{judge_tag}{aa_tag} {env_prefix} {' '.join(cmd)}")
        return {
            "ts": datetime.datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "module": module,
            "cell": cell,
            "task_id": task["id"],
            "category": task["category"],
            "bypass_var": bypass_var,
            "bypass_active": bypass_on,
            "aa_baseline": aa_baseline,
            "scorer": "llm_judge" if use_llm_judge else "exit_code",
            "correct": None,
            "hallucination": None,
            "exit_code": None,
            "output_chars": None,
            "duration_ms": None,
            "dry_run": True,
        }

    start_ms = int(time.time() * 1000)
    try:
        result = subprocess.run(
            cmd,
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout_secs,
            stdin=subprocess.DEVNULL,
        )
        returncode = result.returncode
        stdout = result.stdout
    except subprocess.TimeoutExpired:
        returncode = -1
        stdout = ""
    except Exception as exc:
        returncode = -2
        stdout = f"ERROR: {exc}"

    end_ms = int(time.time() * 1000)
    duration_ms = end_ms - start_ms

    scores = score_trial(
        returncode=returncode,
        stdout=stdout,
        use_llm_judge=use_llm_judge,
        task_prompt=task["prompt"],
    )

    bypass_on = cell == "B" and not aa_baseline

    return {
        "ts": datetime.datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "module": module,
        "cell": cell,
        "task_id": task["id"],
        "category": task["category"],
        "bypass_var": bypass_var,
        "bypass_active": bypass_on,
        "aa_baseline": aa_baseline,
        "agent_provider": agent_provider,
        "agent_model": agent_model,
        "scorer": scores["scorer"],
        "correct": scores["correct"],
        "hallucination": scores["hallucination"],
        "exit_code": returncode,
        "output_chars": len(stdout.strip()),
        "duration_ms": duration_ms,
        # EVAL-068: persist response_text (truncated) so future runs can be
        # cross-judged retroactively by scripts/ab-harness/rescore-jsonl.py
        # without re-executing the chump binary. 2000 chars is enough for the
        # short-form factual/reasoning/instruction tasks in this fixture and
        # keeps JSONL row size under 4 KB.
        "response_text": stdout.strip()[:2000],
        "dry_run": False,
    }


# ---------------------------------------------------------------------------
# Summary table printer
# ---------------------------------------------------------------------------

def print_summary(results: list[dict], aa_baseline: bool = False) -> None:
    """Print accuracy + Wilson 95% CI + delta per module."""
    modules_seen = sorted(set(r["module"] for r in results if not r.get("dry_run")))
    if not modules_seen:
        print("\n[summary] No live results to summarise (dry-run only).")
        return

    # Detect scorer(s) used
    scorers_used = set(r.get("scorer", "exit_code") for r in results if not r.get("dry_run"))
    scorer_label = "+".join(sorted(scorers_used))

    header = f"{'Module':<16} {'n(A)':<6} {'n(B)':<6} {'Acc A':<8} {'Acc B':<8} {'CI_A_lo':<9} {'CI_A_hi':<9} {'CI_B_lo':<9} {'CI_B_hi':<9} {'Delta':<8} {'Verdict'}"
    print("\n" + "=" * len(header))
    if aa_baseline:
        print(f"  A/A CALIBRATION MODE — both cells bypass=OFF (instrument validation)")
    print(f"  Scorer: {scorer_label}")
    print(header)
    print("-" * len(header))

    for mod in modules_seen:
        a_rows = [r for r in results if r["module"] == mod and r["cell"] == "A" and not r.get("dry_run")]
        b_rows = [r for r in results if r["module"] == mod and r["cell"] == "B" and not r.get("dry_run")]

        nA = len(a_rows)
        nB = len(b_rows)
        corrA = sum(1 for r in a_rows if r["correct"])
        corrB = sum(1 for r in b_rows if r["correct"])

        accA = corrA / nA if nA > 0 else 0.0
        accB = corrB / nB if nB > 0 else 0.0
        ciA = wilson_ci(corrA, nA)
        ciB = wilson_ci(corrB, nB)
        delta = accB - accA  # positive = bypass hurts (fewer correct)

        # Verdict: need enough samples to say anything
        if nA < 5 or nB < 5:
            verdict = "INSUFFICIENT n"
        elif aa_baseline:
            # In A/A mode the only valid outcome is ≈0 delta
            if abs(delta) <= 0.05:
                verdict = "A/A OK — delta≈0"
            else:
                verdict = "A/A FAIL — instrument noise > 0.05"
        elif abs(delta) <= 0.05:
            verdict = "NO SIGNAL"
        elif delta < -0.05:
            verdict = "BYPASS HELPS (+acc)"
        else:
            verdict = "BYPASS HURTS (-acc)"

        print(
            f"{mod:<16} {nA:<6} {nB:<6} {accA:<8.3f} {accB:<8.3f} "
            f"{ciA[0]:<9.3f} {ciA[1]:<9.3f} {ciB[0]:<9.3f} {ciB[1]:<9.3f} "
            f"{delta:<+8.3f} {verdict}"
        )

    print("=" * len(header))
    if aa_baseline:
        print("A/A mode: delta≈0 confirms instrument validity. Run without --aa-baseline for real ablation.")
    else:
        print("Note: Delta = Acc(B) - Acc(A). Negative delta means bypass *improves* accuracy.")
        print("      Full n=30+ run required for any publishable claim (per RESEARCH_INTEGRITY.md).")
        if "exit_code" in scorers_used and "llm_judge" not in scorers_used:
            print("      WARNING: exit-code scorer active (EVAL-060 broken instrument). Use --use-llm-judge.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="EVAL-049/EVAL-060 binary-mode ablation harness — measures CHUMP_BYPASS_* impact via chump binary.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Dry-run — prints subprocess commands, no binary needed:
  python3 scripts/ab-harness/run-binary-ablation.py --dry-run

  # Quick smoke test (n=5):
  python3 scripts/ab-harness/run-binary-ablation.py --n-per-cell 5

  # Full publishable run (n=30) with LLM judge (EVAL-060 fixed instrument):
  python3 scripts/ab-harness/run-binary-ablation.py --n-per-cell 30 --use-llm-judge

  # A/A calibration check — validates the instrument before real sweeps:
  python3 scripts/ab-harness/run-binary-ablation.py \\
      --module belief_state --n-per-cell 30 --use-llm-judge --aa-baseline

  # Single module:
  python3 scripts/ab-harness/run-binary-ablation.py --module belief_state --n-per-cell 5

Output:
  logs/ab/eval049-binary-<ts>.jsonl   — one JSONL line per trial
  Summary table printed to stdout at completion

EVAL-060 note:
  The default exit-code scorer (exit code 0 + len > 10) is a broken instrument for
  chump binary runs — baseline accuracy is 0–10% because chump exits 1 on most trials
  without a live API key. Use --use-llm-judge for any result you intend to publish.
  Always run --aa-baseline first to confirm delta≈0 (instrument calibration check).
""",
    )
    p.add_argument(
        "--module",
        choices=list(MODULES.keys()) + ["all"],
        default="all",
        help="Which bypass module to sweep (default: all)",
    )
    p.add_argument(
        "--n-per-cell",
        type=int,
        default=5,
        metavar="N",
        help="Tasks per cell (A and B each). Use 30 for a full publishable run (default: 5).",
    )
    p.add_argument(
        "--binary",
        default="./target/release/chump",
        metavar="PATH",
        help="Path to the chump binary (default: ./target/release/chump)",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print subprocess commands without executing them. Works with no binary or API keys.",
    )
    p.add_argument(
        "--timeout",
        type=int,
        default=300,
        metavar="SECS",
        help="Per-trial timeout in seconds (default: 300)",
    )
    p.add_argument(
        "--output-dir",
        default=None,
        metavar="DIR",
        help="Directory for JSONL output (default: logs/ab/ relative to repo root)",
    )
    p.add_argument(
        "--use-llm-judge",
        action="store_true",
        dest="use_llm_judge",
        help=(
            "EVAL-060: Score with claude-haiku-4-5 instead of exit-code heuristic. "
            "Requires ANTHROPIC_API_KEY. Falls back to exit-code if judge call fails. "
            "Required for any publishable ablation result."
        ),
    )
    p.add_argument(
        "--aa-baseline",
        action="store_true",
        dest="aa_baseline",
        help=(
            "EVAL-060: A/A calibration mode — Cell B also uses bypass=OFF (same as Cell A). "
            "Expected result: delta≈0. Run this before any real ablation sweep to validate "
            "the instrument. Pair with --use-llm-judge for the LLM-judge calibration."
        ),
    )
    p.add_argument(
        "--agent-provider",
        choices=("anthropic", "together", "ollama"),
        default="anthropic",
        dest="agent_provider",
        help=(
            "RESEARCH-027: provider for the chump binary's LLM calls. "
            "anthropic = Anthropic API via ANTHROPIC_API_KEY (default). "
            "together = Together.ai OpenAI-compatible endpoint; sets "
            "OPENAI_API_BASE=https://api.together.xyz/v1 and TOGETHER_API_KEY in the "
            "subprocess env (requires TOGETHER_API_KEY in current env). "
            "ollama = local Ollama endpoint; sets OPENAI_API_BASE=http://localhost:11434/v1."
        ),
    )
    p.add_argument(
        "--agent-model",
        default=None,
        dest="agent_model",
        metavar="NAME",
        help=(
            "RESEARCH-027: model name to route the chump binary to. Sets OPENAI_MODEL "
            "in the subprocess env so chump picks it up. "
            "Example: --agent-provider together --agent-model meta-llama/Llama-3.3-70B-Instruct-Turbo"
        ),
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()

    # Resolve binary path
    binary = args.binary
    if not os.path.isabs(binary):
        # Make relative to the repo root (two directories up from this script)
        script_dir = os.path.dirname(os.path.abspath(__file__))
        repo_root = os.path.dirname(os.path.dirname(script_dir))
        binary = os.path.join(repo_root, binary.lstrip("./"))
    binary = os.path.normpath(binary)

    # Binary existence check (skip in dry-run)
    if not args.dry_run:
        if not os.path.isfile(binary):
            print(
                f"ERROR: chump binary not found at {binary}\n"
                "Build it first:\n"
                "  cargo build --release --bin chump\n"
                "Or specify a different path with --binary <path>.",
                file=sys.stderr,
            )
            sys.exit(1)
        if not os.access(binary, os.X_OK):
            print(
                f"ERROR: {binary} exists but is not executable.\n"
                "Try: chmod +x {binary}",
                file=sys.stderr,
            )
            sys.exit(1)

    # Resolve output directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(os.path.dirname(script_dir))
    out_dir = args.output_dir or os.path.join(repo_root, "logs", "ab")
    if not args.dry_run:
        os.makedirs(out_dir, exist_ok=True)

    ts = int(time.time())
    aa_tag = "-aa" if args.aa_baseline else ""
    judge_tag = "-judge" if args.use_llm_judge else ""
    out_path = os.path.join(out_dir, f"eval049-binary{judge_tag}{aa_tag}-{ts}.jsonl")

    # Resolve modules to sweep
    if args.module == "all":
        modules_to_run = list(MODULES.keys())
    else:
        modules_to_run = [args.module]

    n = args.n_per_cell
    tasks_subset = TASKS[:n]
    if len(tasks_subset) < n:
        # Repeat tasks if n > len(TASKS)
        tasks_subset = (TASKS * (n // len(TASKS) + 1))[:n]

    total_trials = len(modules_to_run) * 2 * n
    print(f"[eval-049] Binary-mode ablation harness")
    print(f"[eval-049] Binary:  {binary}")
    print(f"[eval-049] Modules: {', '.join(modules_to_run)}")
    print(f"[eval-049] n/cell:  {n}  (total trials: {total_trials})")
    print(f"[eval-049] Scorer:  {'llm_judge (claude-haiku-4-5)' if args.use_llm_judge else 'exit_code (EVAL-049 baseline — BROKEN per EVAL-060)'}")
    if args.aa_baseline:
        print(f"[eval-049] Mode:    A/A CALIBRATION (both cells bypass=OFF — expected delta≈0)")
    if args.dry_run:
        print(f"[eval-049] Mode:    DRY-RUN (no subprocess execution)")
    else:
        print(f"[eval-049] Output:  {out_path}")
    print()

    all_results: list[dict] = []

    for module in modules_to_run:
        bypass_var = MODULES[module]
        print(f"--- Module: {module} ({bypass_var}) ---")

        for cell in ["A", "B"]:
            if args.aa_baseline:
                label = "A/A calibration (bypass OFF)" if cell == "A" else "A/A calibration (bypass OFF — same as A)"
            else:
                label = "control (bypass OFF)" if cell == "A" else "ablation (bypass ON)"
            print(f"  Cell {cell}: {label}")

            for i, task in enumerate(tasks_subset):
                result = run_trial(
                    binary=binary,
                    task=task,
                    module=module,
                    cell=cell,
                    timeout_secs=args.timeout,
                    dry_run=args.dry_run,
                    use_llm_judge=args.use_llm_judge,
                    aa_baseline=args.aa_baseline,
                    agent_provider=args.agent_provider,
                    agent_model=args.agent_model,
                )
                all_results.append(result)

                if not args.dry_run:
                    status = "OK" if result["correct"] else "FAIL"
                    hallu = " [halluc]" if result["hallucination"] else ""
                    scorer_note = f" scorer={result.get('scorer', '?')}"
                    print(
                        f"    [{i+1}/{n}] {task['id']} {status}{hallu}{scorer_note} "
                        f"exit={result['exit_code']} chars={result['output_chars']} "
                        f"ms={result['duration_ms']}"
                    )

        print()

    # Write JSONL output
    if not args.dry_run:
        with open(out_path, "w") as f:
            for row in all_results:
                f.write(json.dumps(row) + "\n")
        print(f"[eval-049] Wrote {len(all_results)} trial rows to {out_path}")

    # Print summary table
    print_summary(all_results, aa_baseline=args.aa_baseline)

    if args.dry_run:
        print(
            "\n[eval-049] Dry-run complete. To run for real:\n"
            "  cargo build --release --bin chump\n"
            "  # First: A/A calibration (validate instrument):\n"
            "  python3 scripts/ab-harness/run-binary-ablation.py \\\n"
            "      --module belief_state --n-per-cell 30 --use-llm-judge --aa-baseline\n"
            "  # Then: real ablation sweep:\n"
            "  python3 scripts/ab-harness/run-binary-ablation.py --n-per-cell 30 --use-llm-judge"
        )
    else:
        print(
            f"\n[eval-049] Done. Full results: {out_path}\n"
            "  Note: n=30+ per cell required for publishable claims (RESEARCH_INTEGRITY.md).\n"
            "  Use --use-llm-judge for semantic correctness scoring (EVAL-060 fixed instrument).\n"
            "  Run --aa-baseline first to validate instrument (expected delta≈0)."
        )


if __name__ == "__main__":
    main()
