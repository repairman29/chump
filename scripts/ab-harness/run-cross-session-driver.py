#!/usr/bin/env python3
"""EVAL-019: Cross-session continuity A/B driver.

For each pair-task in cross_session_tasks.json:
  Mode A: system prompt includes the session-1 context fact (simulating
          what entity-keyed blackboard prefetch would inject).
  Mode B: no system prompt — fresh session with no prior context.

The session-2 prompt is identical in both modes. The only difference is
whether the prior-session context is present.

Scores via Anthropic judge: did the response engage with the session-1
context (mention the project name, tech decision, specific detail)?

Usage (called from run-cross-session.sh):
    run-cross-session-driver.py
        --fixture fixtures/cross_session_tasks.json
        --out logs/ab/cross-session-<ts>.jsonl
        --limit 20 --judge claude-haiku-4-5 --model claude-haiku-4-5
        --tag cross-session
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
    "## Prior session context (retrieved from memory)\n\n"
    "The following fact was recorded in a previous session with this user:\n\n"
    "  {fact}\n\n"
    "Apply this context when answering the user's question."
)


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
        "max_tokens": 1024,
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
    ap = argparse.ArgumentParser(description="EVAL-019 cross-session A/B driver")
    ap.add_argument("--fixture", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=20)
    ap.add_argument("--judge", default=DEFAULT_JUDGE)
    ap.add_argument("--judge-threshold", type=float, default=0.5)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--tag", default="cross-session")
    args = ap.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set.")
        return 1

    fixture = json.loads(Path(args.fixture).read_text())
    tasks = fixture["tasks"][: args.limit]
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    trials: list[dict[str, Any]] = []
    total = len(tasks) * 2

    for i, task in enumerate(tasks):
        prompt = task["session_2_prompt"]
        fact = task["session_1_context"]
        rubric = task.get("judge_rubric", "")
        expected = task.get("expected_in_response", "")

        for mode in ("A", "B"):
            # Mode A: inject session-1 context as system prompt prefix
            # Mode B: no system prompt (fresh session)
            system_prompt = CONTEXT_HEADER.format(fact=fact) if mode == "A" else ""

            success, response_text = call_cloud(api_key, args.model, system_prompt, prompt)
            preview = response_text[:800] if success else response_text

            # Structural check: does the response mention the expected term?
            structural_pass = success and bool(expected) and expected.lower() in preview.lower()

            # Judge score
            score, reasoning, judge_passed = call_judge(
                api_key, args.judge, rubric, preview, args.judge_threshold
            ) if success and rubric else (0.0, "no_rubric", False)

            trial: dict[str, Any] = {
                "tag": args.tag,
                "task_id": task["id"],
                "category": task.get("category", ""),
                "mode": mode,
                "prompt": prompt,
                "session_1_context": fact if mode == "A" else "",
                "context_injected": mode == "A",
                "success": success,
                "final_text_preview": preview,
                "expected_term": expected,
                "structural_pass": structural_pass,
                "judge_score": score,
                "judge_reasoning": reasoning,
                "judge_passed": judge_passed,
                "scored": success and judge_passed,
            }
            trials.append(trial)
            idx = (i * 2) + (0 if mode == "A" else 1) + 1
            print(
                f"  [{idx:3d}/{total}] {task['id']} mode={mode} "
                f"judge={score:.2f} struct={'✓' if structural_pass else '✗'} "
                f"{'✓' if judge_passed else '✗'}"
            )
            with out_path.open("a") as f:
                f.write(json.dumps(trial) + "\n")

            time.sleep(0.5)

    # Compute summary with Wilson CIs.
    by_mode: dict[str, dict[str, Any]] = {}
    by_cat: dict[str, dict[str, dict[str, Any]]] = {}
    for t in trials:
        m = by_mode.setdefault(t["mode"], {"passed": 0, "failed": 0, "struct_passed": 0})
        m["passed" if t["scored"] else "failed"] += 1
        m["struct_passed"] += int(t.get("structural_pass", False))
        cm = by_cat.setdefault(t["category"], {}).setdefault(t["mode"], {"passed": 0, "failed": 0})
        cm["passed" if t["scored"] else "failed"] += 1

    for mode_key, m in by_mode.items():
        n = m["passed"] + m["failed"]
        m["rate"] = round(m["passed"] / n, 3) if n else 0.0
        lo, hi = wilson_ci(m["passed"], n)
        m["ci_lo"] = round(lo, 3)
        m["ci_hi"] = round(hi, 3)
        m["struct_rate"] = round(m["struct_passed"] / n, 3) if n else 0.0

    for cat in by_cat.values():
        for m in cat.values():
            n = m["passed"] + m["failed"]
            m["rate"] = round(m["passed"] / n, 3) if n else 0.0

    a = by_mode.get("A", {})
    b = by_mode.get("B", {})
    delta = round(a.get("rate", 0.0) - b.get("rate", 0.0), 3)
    struct_delta = round(a.get("struct_rate", 0.0) - b.get("struct_rate", 0.0), 3)

    # CIs overlap?
    cis_overlap = a.get("ci_lo", 0.0) < b.get("ci_hi", 1.0) and b.get("ci_lo", 0.0) < a.get("ci_hi", 1.0)

    summary: dict[str, Any] = {
        "tag": args.tag,
        "task_count": len(tasks),
        "trial_count": len(trials),
        "judge_model": args.judge,
        "test_model": args.model,
        "by_mode": by_mode,
        "by_category": by_cat,
        "delta": delta,
        "structural_delta": struct_delta,
        "cis_overlap": cis_overlap,
        "interpretation": (
            "EVAL-019 continuity test. Positive delta = entity prefetch successfully "
            "bridges session context. cis_overlap=False required for a publishable finding."
        ),
    }
    summary_path = out_path.with_suffix(".summary.json")
    summary_path.write_text(json.dumps(summary, indent=2))

    print(f"\n=== {args.tag} summary ===")
    print(f"Mode A (with session-1 context): {a.get('rate', 0):.1%}  "
          f"CI [{a.get('ci_lo',0):.2f}, {a.get('ci_hi',0):.2f}]")
    print(f"Mode B (no prior context):       {b.get('rate', 0):.1%}  "
          f"CI [{b.get('ci_lo',0):.2f}, {b.get('ci_hi',0):.2f}]")
    print(f"Judge delta  (A − B): {delta:+.3f}")
    print(f"Struct delta (A − B): {struct_delta:+.3f}")
    print(f"CIs overlap: {cis_overlap}  ({'inconclusive' if cis_overlap else 'provisional signal'})")
    print(f"Summary: {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
