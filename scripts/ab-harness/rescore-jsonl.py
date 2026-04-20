#!/usr/bin/env python3
"""
EVAL-068 — Cross-judge re-scorer for binary-mode ablation JSONLs.

Reads a JSONL produced by run-binary-ablation.py with the EVAL-068 patch
(response_text field present), re-scores each trial with a non-Anthropic
judge (Together-served Qwen3-Coder-480B or DeepSeek-V3.1), and writes a
new JSONL with judge_score_<model> + judge_reasoning_<model> fields
appended to each row.

Purpose: closes EVAL-060 acceptance criterion #4 (cross-family judge
validation) without re-running the binary. RESEARCH_INTEGRITY.md requires
at least one non-Anthropic judge for any externally-cited result; the
existing eval049-binary-judge-*.jsonl files were single-judge
(claude-haiku-4-5) only.

Usage:
    # Score with Qwen3-Coder-480B as the judge
    python3 scripts/ab-harness/rescore-jsonl.py \\
        --input logs/ab/eval049-binary-judge-1776710960.jsonl \\
        --judge together:Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8 \\
        --output logs/ab/eval049-binary-judge-qwen-1776710960.jsonl

    # Or DeepSeek
    python3 scripts/ab-harness/rescore-jsonl.py \\
        --input logs/ab/eval049-binary-judge-1776710960.jsonl \\
        --judge together:deepseek-ai/DeepSeek-V3.1 \\
        --output logs/ab/eval049-binary-judge-deepseek-1776710960.jsonl

Requires TOGETHER_API_KEY in env or .env (sourced from repo root).

Produces:
    - Output JSONL: each row has the original fields + new
      judge_score_<safe_model_name>, judge_reasoning_<safe_model_name>,
      and judge_correct_<safe_model_name> (binary)
    - Stdout summary: cross-judge agreement % vs the original
      `correct` field, per cell

Caveats:
    - Input JSONL MUST have `response_text` field (added by EVAL-068 patch
      to run-binary-ablation.py). Older JSONLs that pre-date the patch
      cannot be cross-judged retroactively because they only stored
      output_chars (length), not the actual response.
    - Cost on Together: ~$0.005 per trial (input ~500 tokens + output
      ~30 tokens). 100-trial JSONL ≈ $0.50. Hard cap at $5 per run via
      --max-cost flag (kills if exceeded).
    - Judge prompt is identical to the original Anthropic-judge prompt
      in run-binary-ablation.py for direct comparability.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request


JUDGE_PROMPT = """You are scoring an AI assistant's response to a task.

Task: {task_prompt}
AI Response: {ai_response}

Did the AI response correctly address the task? Reply with exactly: CORRECT: 1 or CORRECT: 0"""


def load_env():
    """Source .env from repo root if present so TOGETHER_API_KEY resolves."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(os.path.dirname(script_dir))
    env_path = os.path.join(repo_root, ".env")
    if not os.path.isfile(env_path):
        return
    for line in open(env_path):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        v = v.strip().strip('"').strip("'")
        if k and not os.environ.get(k):
            os.environ[k] = v


def call_together_judge(model: str, task_prompt: str, ai_response: str) -> tuple[bool | None, str]:
    """Returns (correct, raw_text). correct=None on API error."""
    api_key = os.environ.get("TOGETHER_API_KEY", "")
    if not api_key:
        return None, "ERROR: TOGETHER_API_KEY not set"
    user_prompt = JUDGE_PROMPT.format(
        task_prompt=task_prompt,
        ai_response=ai_response if ai_response.strip() else "(no output)",
    )
    payload = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": user_prompt}],
        "max_tokens": 30,
        "temperature": 0,
    }).encode()
    req = urllib.request.Request(
        "https://api.together.xyz/v1/chat/completions",
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
        text = data.get("choices", [{}])[0].get("message", {}).get("content", "")
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        return None, f"ERROR: {type(e).__name__}: {e}"
    except Exception as e:
        return None, f"ERROR: {type(e).__name__}: {e}"

    # Parse "CORRECT: 1" or "CORRECT: 0" — be tolerant of extra whitespace/text
    correct = None
    for line in text.splitlines():
        s = line.strip().upper()
        if s.startswith("CORRECT:"):
            try:
                correct = bool(int(s.split(":", 1)[1].strip()[:1]))
                break
            except (ValueError, IndexError):
                pass
    return correct, text


def safe_model_name(model: str) -> str:
    """Convert 'together:Qwen/Qwen3-Coder-480B-...' to 'qwen3_coder_480b' for field key suffixes."""
    base = model.split(":", 1)[-1].split("/")[-1]
    safe = "".join(c if c.isalnum() else "_" for c in base.lower())
    # Collapse runs of underscores
    while "__" in safe:
        safe = safe.replace("__", "_")
    return safe.strip("_")


def parse_args():
    p = argparse.ArgumentParser(
        description="EVAL-068 cross-judge re-scorer for binary-mode ablation JSONLs",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--input", required=True, help="Input JSONL (from run-binary-ablation.py with EVAL-068 patch)")
    p.add_argument("--judge", required=True,
                   help="Judge model. Format: together:<model_id>. "
                        "Examples: together:Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8, "
                        "together:deepseek-ai/DeepSeek-V3.1")
    p.add_argument("--output", required=True, help="Output JSONL with rescored fields appended")
    p.add_argument("--max-cost", type=float, default=5.0, metavar="USD",
                   help="Hard cap on judge spend in USD (kills if exceeded). Default: 5.0")
    p.add_argument("--task-fixture", default=None,
                   help="Optional: path to a task fixture JSON to look up full prompts by task_id. "
                        "If absent, uses the prompt embedded in the JSONL (or task_id as fallback).")
    p.add_argument("--limit", type=int, default=None,
                   help="Score at most N trials (for testing). Default: all rows.")
    return p.parse_args()


def load_task_fixture(path: str | None) -> dict:
    if not path or not os.path.isfile(path):
        return {}
    try:
        data = json.load(open(path))
        # Support both {"tasks": [...]} and bare list
        tasks = data.get("tasks", data) if isinstance(data, dict) else data
        return {t.get("id", ""): t.get("prompt", "") for t in tasks if isinstance(t, dict)}
    except (OSError, json.JSONDecodeError):
        return {}


def main():
    args = parse_args()
    load_env()

    if not args.judge.startswith("together:"):
        print(f"ERROR: --judge must start with 'together:', got: {args.judge}", file=sys.stderr)
        sys.exit(2)

    fixture = load_task_fixture(args.task_fixture)

    # Built-in fallback: the EVAL-049 task fixture is hardcoded in
    # run-binary-ablation.py; mirror it here so we don't need a side-channel
    # fixture file for the common case.
    builtin_tasks = {
        "t001": "What is 17 multiplied by 23?",
        "t002": "Name the capital city of Japan.",
        "t003": "If all A are B and all B are C, are all A also C? Answer yes or no and briefly explain.",
        "t004": "A bat and ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost?",
        "t005": "What programming language was Rust originally developed by Mozilla?",
        "t006": "List the three primary colours in painting.",
        "t007": "Sort the following numbers in ascending order: 7, 2, 9, 1, 4.",
        "t008": "How many sides does a hexagon have?",
        "t009": "Give a one-sentence summary of what HTTP stands for.",
        "t010": "If today is Wednesday and you add 10 days, what day of the week is it?",
        "t011": "What is the chemical symbol for gold?",
        "t012": "Write a Python function that returns the square of a number.",
        "t013": "A shop sells apples for $0.50 each. If you buy 6 apples with a $5 bill, how much change do you receive?",
        "t014": "In which year did World War II end?",
        "t015": "Explain in one sentence what a binary search algorithm does.",
        "t016": "If a train travels at 60 mph and needs to cover 150 miles, how many hours will the journey take?",
        "t017": "What is the SI unit of electric current?",
        "t018": "Name two advantages of using version control systems like git.",
        "t019": "There are 5 red balls and 3 blue balls in a bag. What fraction of the balls are blue?",
        "t020": "What does CPU stand for in computing?",
        "t021": "Describe what a deadlock is in operating systems in two sentences.",
        "t022": "If x + 5 = 12, what is x?",
        "t023": "Which planet in our solar system has the most moons?",
        "t024": "What is the difference between a stack and a queue data structure?",
        "t025": "A rectangle has a length of 8 cm and a width of 5 cm. What is its perimeter?",
        "t026": "What is the boiling point of water at sea level in Celsius?",
        "t027": "List three key principles of object-oriented programming.",
        "t028": "If you flip a fair coin 3 times, how many possible outcomes are there?",
        "t029": "What does RAM stand for in computing?",
        "t030": "In one sentence, explain what a hash function does.",
    }
    fixture = {**builtin_tasks, **fixture}

    rows = [json.loads(l) for l in open(args.input) if l.strip()]
    if args.limit:
        rows = rows[: args.limit]

    judge_field_suffix = safe_model_name(args.judge)
    score_field = f"judge_correct_{judge_field_suffix}"
    reasoning_field = f"judge_reasoning_{judge_field_suffix}"

    # Cost estimation: ~500 input + 30 output tokens at $2/M input + $2/M output
    # for Qwen3-Coder-480B-FP8; cheaper for DeepSeek-V3.1.
    cost_per_trial_estimate = 0.005  # USD; conservative
    estimated_total = cost_per_trial_estimate * len(rows)
    print(f"[rescore-jsonl] input={args.input}", file=sys.stderr)
    print(f"[rescore-jsonl] judge={args.judge}", file=sys.stderr)
    print(f"[rescore-jsonl] rows={len(rows)} (estimated ${estimated_total:.2f}, cap ${args.max_cost:.2f})", file=sys.stderr)
    if estimated_total > args.max_cost:
        print(f"[rescore-jsonl] ERROR: estimated cost ${estimated_total:.2f} exceeds --max-cost ${args.max_cost:.2f}", file=sys.stderr)
        print(f"[rescore-jsonl] Use --limit N to score a subset, or raise --max-cost.", file=sys.stderr)
        sys.exit(2)

    enriched = []
    n_scored = 0
    n_failed = 0
    n_agree_with_orig = 0
    cumulative_cost = 0.0
    for i, row in enumerate(rows):
        # Get the response text — only present in JSONLs from post-EVAL-068 sweeps
        response_text = row.get("response_text", "")
        task_id = row.get("task_id", "")
        task_prompt = fixture.get(task_id, "")
        if not response_text:
            row[score_field] = None
            row[reasoning_field] = "SKIP: response_text missing (pre-EVAL-068 JSONL)"
            enriched.append(row)
            n_failed += 1
            continue
        if not task_prompt:
            row[score_field] = None
            row[reasoning_field] = f"SKIP: task_prompt unknown for task_id={task_id}"
            enriched.append(row)
            n_failed += 1
            continue

        correct, raw_text = call_together_judge(args.judge, task_prompt, response_text)
        cumulative_cost += cost_per_trial_estimate
        if correct is None:
            n_failed += 1
            row[score_field] = None
            row[reasoning_field] = raw_text[:200]
        else:
            n_scored += 1
            row[score_field] = correct
            row[reasoning_field] = raw_text[:200]
            orig_correct = row.get("correct")
            if orig_correct is not None and bool(orig_correct) == correct:
                n_agree_with_orig += 1
        enriched.append(row)

        if cumulative_cost > args.max_cost:
            print(f"[rescore-jsonl] HARD CAP HIT at trial {i+1}/{len(rows)}: ${cumulative_cost:.2f} > ${args.max_cost:.2f}", file=sys.stderr)
            # Flush remaining unscored rows as-is
            for remaining in rows[i+1:]:
                remaining[score_field] = None
                remaining[reasoning_field] = "SKIP: --max-cost cap hit before reaching this trial"
                enriched.append(remaining)
            break

        if (i + 1) % 10 == 0:
            print(f"  [{i+1}/{len(rows)}] cost so far: ${cumulative_cost:.2f}", file=sys.stderr)

    # Write output
    with open(args.output, "w") as f:
        for row in enriched:
            f.write(json.dumps(row) + "\n")

    # Summary
    print()
    print(f"[rescore-jsonl] === SUMMARY ===")
    print(f"[rescore-jsonl] scored: {n_scored}/{len(rows)}")
    print(f"[rescore-jsonl] failed (API/missing data): {n_failed}/{len(rows)}")
    print(f"[rescore-jsonl] cumulative cost: ${cumulative_cost:.2f}")
    if n_scored > 0:
        agreement_pct = 100.0 * n_agree_with_orig / n_scored
        print(f"[rescore-jsonl] agreement with original judge ({row.get('scorer','?')}): "
              f"{n_agree_with_orig}/{n_scored} = {agreement_pct:.1f}%")
        if agreement_pct < 80.0:
            print(f"[rescore-jsonl] WARNING: agreement <80% — RESEARCH_INTEGRITY.md flags this for "
                  f"judge-methodology investigation. File EVAL-069 follow-up gap.")
    print(f"[rescore-jsonl] output: {args.output}")


if __name__ == "__main__":
    main()
