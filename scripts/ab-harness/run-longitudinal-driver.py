#!/usr/bin/env python3.12
"""EVAL-021: Longitudinal accumulation A/B driver.

For each checkpoint C in [10, 25, 50, 75, 100]:
  Mode A: system prompt includes the accumulated session facts for sessions 1..C.
  Mode B: no system prompt (fresh session — no longitudinal context).

Runs all 20 held-out tasks at each checkpoint for both modes.
Total: 20 tasks × 5 checkpoints × 2 modes = 200 API calls.

Output:
  logs/ab/longitudinal-<ts>.jsonl      — one line per trial
  logs/ab/longitudinal-<ts>.summary.json — checkpoint-level pass rates + delta curve

Usage (called from run-longitudinal.sh):
    run-longitudinal-driver.py
        --fixture fixtures/longitudinal_trace.json
        --out logs/ab/longitudinal-<ts>.jsonl
        --judge claude-haiku-4-5 --model claude-haiku-4-5
        --tag longitudinal
"""
from __future__ import annotations

import argparse
import json
import os
import time
import urllib.request
import urllib.error
from pathlib import Path
from typing import Any


ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
DEFAULT_JUDGE = "claude-haiku-4-5"
DEFAULT_MODEL = "claude-haiku-4-5"

CONTEXT_HEADER = (
    "## Accumulated project memory ({n} facts from {cp} sessions)\n\n"
    "The following facts were recorded across {cp} prior sessions with this user "
    "about the stellar-api project. Apply this context when answering.\n\n"
    "{facts}\n"
)


def format_context(facts: list[str], checkpoint: int) -> str:
    lines = "\n".join(f"  • {f}" for f in facts)
    return CONTEXT_HEADER.format(n=len(facts), cp=checkpoint, facts=lines)


def call_cloud(
    api_key: str,
    model: str,
    system_prompt: str,
    user_prompt: str,
    timeout: int = 60,
    retries: int = 2,
) -> tuple[bool, str]:
    """Call Anthropic API. Returns (success, response_text)."""
    payload: dict[str, Any] = {
        "model": model,
        "max_tokens": 512,
        "messages": [{"role": "user", "content": user_prompt}],
    }
    if system_prompt:
        payload["system"] = system_prompt
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }
    for attempt in range(retries + 1):
        req = urllib.request.Request(
            ANTHROPIC_URL,
            data=json.dumps(payload).encode(),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = json.loads(resp.read().decode())
        except Exception as exc:
            if attempt < retries:
                time.sleep(3 + attempt * 5)
                continue
            return False, f"api_error: {exc}"
        for block in body.get("content", []):
            if block.get("type") == "text":
                return True, block["text"]
        return False, "no_text_block"
    return False, "exhausted_retries"


def call_judge(
    api_key: str,
    judge_model: str,
    rubric: str,
    response_text: str,
    threshold: float = 0.5,
) -> tuple[float, str, bool]:
    """Score a trial. Returns (score, reasoning, passed)."""
    system = (
        "You are an impartial evaluator. Return ONLY JSON: "
        '{"score": <float 0.0..1.0>, "reasoning": "<one sentence>"}. '
        "No markdown."
    )
    user = f"RUBRIC:\n{rubric}\n\nASSISTANT RESPONSE:\n{response_text or '(empty)'}"
    payload: dict[str, Any] = {
        "model": judge_model,
        "max_tokens": 256,
        "system": system,
        "messages": [{"role": "user", "content": user}],
    }
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }
    req = urllib.request.Request(
        ANTHROPIC_URL,
        data=json.dumps(payload).encode(),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read().decode())
        for block in body.get("content", []):
            if block.get("type") == "text":
                parsed = json.loads(block["text"])
                score = max(0.0, min(1.0, float(parsed.get("score", 0.0))))
                return score, str(parsed.get("reasoning", "")), score >= threshold
    except Exception as exc:
        return 0.0, f"judge_error: {exc}", False
    return 0.0, "no_text_block", False


def wilson_ci(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    """Wilson 95% confidence interval."""
    if n == 0:
        return 0.0, 0.0
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    margin = (z * (p * (1 - p) / n + z * z / (4 * n * n)) ** 0.5) / denom
    return max(0.0, centre - margin), min(1.0, centre + margin)


def main() -> int:
    ap = argparse.ArgumentParser(description="EVAL-021 longitudinal A/B driver")
    ap.add_argument("--fixture", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--judge", default=DEFAULT_JUDGE)
    ap.add_argument("--judge-threshold", type=float, default=0.5)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--tag", default="longitudinal")
    ap.add_argument(
        "--checkpoints",
        default="10,25,50,75,100",
        help="Comma-separated checkpoint list (default: 10,25,50,75,100)",
    )
    args = ap.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set.")
        return 1

    fixture = json.loads(Path(args.fixture).read_text())
    checkpoints = [int(c) for c in args.checkpoints.split(",")]
    tasks = fixture["held_out_tasks"]
    accumulated = fixture["accumulated_facts"]

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    total_calls = len(tasks) * len(checkpoints) * 2
    call_idx = 0

    all_trials: list[dict[str, Any]] = []

    for cp in checkpoints:
        cp_str = str(cp)
        facts = accumulated.get(cp_str, [])
        system_a = format_context(facts, cp)

        cp_trials: list[dict[str, Any]] = []

        for task in tasks:
            prompt = task["prompt"]
            rubric = task.get("judge_rubric", "")
            expected = task.get("expected_in_response", "")
            first_answerable = task.get("first_answerable_at", 0)

            for mode in ("A", "B"):
                call_idx += 1
                system_prompt = system_a if mode == "A" else ""
                success, response_text = call_cloud(
                    api_key, args.model, system_prompt, prompt
                )
                preview = response_text[:800] if success else response_text

                structural_pass = (
                    success and bool(expected)
                    and expected.lower() in preview.lower()
                )

                score, reasoning, judge_passed = (
                    call_judge(api_key, args.judge, rubric, preview, args.judge_threshold)
                    if success and rubric
                    else (0.0, "no_rubric", False)
                )

                trial: dict[str, Any] = {
                    "tag": args.tag,
                    "checkpoint": cp,
                    "task_id": task["id"],
                    "category": task.get("category", ""),
                    "first_answerable_at": first_answerable,
                    "mode": mode,
                    "context_injected": mode == "A",
                    "fact_count": len(facts) if mode == "A" else 0,
                    "prompt": prompt,
                    "success": success,
                    "final_text_preview": preview,
                    "expected_term": expected,
                    "structural_pass": structural_pass,
                    "judge_score": score,
                    "judge_reasoning": reasoning,
                    "judge_passed": judge_passed,
                    "scored": success and judge_passed,
                    # A task is "in scope" at this checkpoint if the fact was established
                    # by a session <= checkpoint.
                    "in_scope": first_answerable <= cp,
                }
                all_trials.append(trial)
                cp_trials.append(trial)
                with out_path.open("a") as f:
                    f.write(json.dumps(trial) + "\n")

                print(
                    f"  [{call_idx:3d}/{total_calls}] cp={cp:3d} {task['id']} "
                    f"mode={mode} judge={score:.2f} "
                    f"struct={'✓' if structural_pass else '✗'} "
                    f"{'✓' if judge_passed else '✗'}"
                )
                time.sleep(0.4)

    # -----------------------------------------------------------------------
    # Build summary: pass rate per (checkpoint, mode) + delta curve
    # -----------------------------------------------------------------------
    by_cp: dict[int, dict[str, dict[str, Any]]] = {}
    for t in all_trials:
        cp = t["checkpoint"]
        m = by_cp.setdefault(cp, {}).setdefault(
            t["mode"], {"passed": 0, "failed": 0, "struct_passed": 0, "in_scope_passed": 0, "in_scope_n": 0}
        )
        m["passed" if t["scored"] else "failed"] += 1
        m["struct_passed"] += int(t.get("structural_pass", False))
        if t.get("in_scope"):
            m["in_scope_n"] += 1
            if t["scored"]:
                m["in_scope_passed"] += 1

    # Compute rates + Wilson CIs
    checkpoint_summary: list[dict[str, Any]] = []
    for cp in checkpoints:
        modes = by_cp.get(cp, {})
        row: dict[str, Any] = {"checkpoint": cp}
        for mode in ("A", "B"):
            m = modes.get(mode, {"passed": 0, "failed": 0, "struct_passed": 0, "in_scope_passed": 0, "in_scope_n": 0})
            n = m["passed"] + m["failed"]
            rate = round(m["passed"] / n, 3) if n else 0.0
            lo, hi = wilson_ci(m["passed"], n)
            in_scope_rate = (
                round(m["in_scope_passed"] / m["in_scope_n"], 3)
                if m["in_scope_n"] else 0.0
            )
            row[f"mode_{mode}"] = {
                "passed": m["passed"],
                "failed": m["failed"],
                "rate": rate,
                "ci_lo": round(lo, 3),
                "ci_hi": round(hi, 3),
                "struct_rate": round(m["struct_passed"] / n, 3) if n else 0.0,
                "in_scope_rate": in_scope_rate,
            }
        a = row.get("mode_A", {})
        b = row.get("mode_B", {})
        row["delta"] = round(a.get("rate", 0) - b.get("rate", 0), 3)
        row["cis_overlap"] = (
            a.get("ci_lo", 0) < b.get("ci_hi", 1)
            and b.get("ci_lo", 0) < a.get("ci_hi", 1)
        )
        checkpoint_summary.append(row)

    # Monotonicity check: does mode A's delta grow with checkpoint?
    deltas = [row["delta"] for row in checkpoint_summary]
    is_monotone = all(deltas[i] <= deltas[i + 1] for i in range(len(deltas) - 1))

    summary: dict[str, Any] = {
        "tag": args.tag,
        "checkpoints": checkpoints,
        "task_count": len(tasks),
        "trial_count": len(all_trials),
        "judge_model": args.judge,
        "test_model": args.model,
        "checkpoint_summary": checkpoint_summary,
        "delta_curve": deltas,
        "delta_is_monotone": is_monotone,
        "interpretation": (
            "EVAL-021 longitudinal accumulation test. "
            "Positive and growing delta across checkpoints = evidence that "
            "accumulated session memory improves performance over time. "
            "delta_is_monotone=True and cis_overlap=False at checkpoint 100 "
            "is required for a publishable finding."
        ),
    }
    summary_path = out_path.with_suffix(".summary.json")
    summary_path.write_text(json.dumps(summary, indent=2))

    print(f"\n=== {args.tag} summary ===")
    print(f"{'CP':>4}  {'A rate':>8}  {'B rate':>8}  {'delta':>7}  {'overlap':>8}")
    for row in checkpoint_summary:
        a = row["mode_A"]
        b = row["mode_B"]
        print(
            f"{row['checkpoint']:>4}  "
            f"{a['rate']:>7.1%}  "
            f"{b['rate']:>7.1%}  "
            f"{row['delta']:>+7.3f}  "
            f"{'yes' if row['cis_overlap'] else 'no':>8}"
        )
    print(f"\nDelta curve: {deltas}")
    print(f"Monotone:    {is_monotone}")
    print(f"Summary:     {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
