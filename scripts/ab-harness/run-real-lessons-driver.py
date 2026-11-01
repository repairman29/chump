#!/usr/bin/env python3
"""EVAL-013: Task-specific real lessons A/B driver.

For each task in real_lessons_tasks.json:
  Mode A: prepend the matching lesson as a LESSONS system-prompt block
  Mode B: no lesson (baseline)

Scores each trial via the cloud judge (Anthropic API).

Usage (called from run-real-lessons.sh):
    scripts/ab-harness/run-real-lessons-driver.py \\
        --fixture fixtures/real_lessons_tasks.json \\
        --lessons-dir fixtures/real-lessons/ \\
        --out logs/ab/real-lessons-<ts>.jsonl \\
        --limit 30 \\
        --judge claude-haiku-4-5 \\
        --tag real-lessons
"""
from __future__ import annotations

import argparse
import json
import os
import time
import urllib.error
import urllib.request
import http.client
import socket
from pathlib import Path
from typing import Any


DEFAULT_JUDGE = "claude-haiku-4-5"
ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"


def load_lesson_block(lessons_dir: Path, task: dict[str, Any]) -> str:
    """Return the LESSONS system-prompt block for mode A, or '' for mode B."""
    fname = task.get("matching_lesson_file", "")
    if not fname:
        return ""
    path = lessons_dir / fname
    if not path.exists():
        return ""
    data = json.loads(path.read_text())
    directives = data.get("directives", [])
    if not directives:
        return ""
    lines = ["LESSONS (from prior reflections — apply these):"]
    for d in directives:
        lines.append(f"  • [{d.get('priority', 'HIGH')}] {d['directive']}")
    return "\n".join(lines) + "\n"


def call_cloud(
    api_key: str,
    model: str,
    system_prompt: str,
    user_prompt: str,
    timeout: int = 60,
    retries: int = 2,
) -> tuple[bool, str]:
    """Call Anthropic API. Returns (success, text)."""
    payload = {
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
    last_err = "no attempt"
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
            last_err = str(exc)
            if attempt < retries:
                time.sleep(3 + attempt * 5)
                continue
            return False, f"api_error: {last_err}"
        for block in body.get("content", []):
            if block.get("type") == "text":
                return True, block["text"]
        return False, "no_text_block"
    return False, f"api_error: exhausted retries — {last_err}"


def call_judge(
    api_key: str,
    judge_model: str,
    rubric: str,
    response_text: str,
    threshold: float = 0.5,
) -> tuple[float, str, bool]:
    """Score a trial via the judge. Returns (score, reasoning, passed)."""
    system = (
        "You are an impartial evaluator. Return ONLY JSON: "
        '{"score": <float 0.0..1.0>, "reasoning": "<one sentence>"}. '
        "No prose, no markdown."
    )
    user = f"RUBRIC:\n{rubric}\n\nASSISTANT RESPONSE:\n{response_text or '(empty)'}"
    payload = {
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


def main() -> int:
    ap = argparse.ArgumentParser(description="EVAL-013 real-lessons A/B driver")
    ap.add_argument("--fixture", required=True)
    ap.add_argument("--lessons-dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=30)
    ap.add_argument("--judge", default=DEFAULT_JUDGE)
    ap.add_argument("--judge-threshold", type=float, default=0.5)
    ap.add_argument("--tag", default="real-lessons")
    ap.add_argument("--model", default="claude-haiku-4-5")
    args = ap.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set.")
        return 1

    fixture = json.loads(Path(args.fixture).read_text())
    tasks = fixture["tasks"][: args.limit]
    lessons_dir = Path(args.lessons_dir)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    trials: list[dict[str, Any]] = []
    total = len(tasks) * 2
    done = 0

    for task in tasks:
        lesson_block = load_lesson_block(lessons_dir, task)
        rubric = task.get("judge_rubric", "")
        prompt = task["prompt"]

        for mode in ("A", "B"):
            # Mode A: lesson injected as system prefix. Mode B: no lesson.
            system_prompt = lesson_block if mode == "A" else ""
            success, response_text = call_cloud(api_key, args.model, system_prompt, prompt)
            preview = response_text[:800] if success else response_text

            score, reasoning, passed = call_judge(
                api_key, args.judge, rubric, preview, args.judge_threshold
            ) if success and rubric else (0.0, "no_rubric", False)

            trial: dict[str, Any] = {
                "tag": args.tag,
                "task_id": task["id"],
                "category": task.get("category", ""),
                "mode": mode,
                "prompt": prompt,
                "lesson_injected": bool(system_prompt),
                "lesson_file": task.get("matching_lesson_file", ""),
                "success": success,
                "final_text_preview": preview,
                "judge_score": score,
                "judge_reasoning": reasoning,
                "judge_passed": passed,
                "scored": success and passed,
            }
            trials.append(trial)
            done += 1
            print(
                f"  [{done:3d}/{total}] {task['id']} mode={mode} "
                f"judge={score:.2f} {'✓' if passed else '✗'}"
            )
            with out_path.open("a") as f:
                f.write(json.dumps(trial) + "\n")

            time.sleep(0.5)  # Rate limit

    # Write summary.
    by_mode: dict[str, dict[str, Any]] = {}
    by_cat: dict[str, dict[str, dict[str, Any]]] = {}
    for t in trials:
        m = by_mode.setdefault(t["mode"], {"passed": 0, "failed": 0})
        m["passed" if t["scored"] else "failed"] += 1
        cm = by_cat.setdefault(t["category"], {}).setdefault(t["mode"], {"passed": 0, "failed": 0})
        cm["passed" if t["scored"] else "failed"] += 1

    def rate(m: dict) -> float:
        tot = m["passed"] + m["failed"]
        return round(m["passed"] / tot, 3) if tot else 0.0

    for m in by_mode.values():
        m["rate"] = rate(m)
    for cat in by_cat.values():
        for m in cat.values():
            m["rate"] = rate(m)

    a_rate = by_mode.get("A", {}).get("rate", 0.0)
    b_rate = by_mode.get("B", {}).get("rate", 0.0)
    delta = round(a_rate - b_rate, 3)

    summary = {
        "tag": args.tag,
        "task_count": len(tasks),
        "trial_count": len(trials),
        "judge_model": args.judge,
        "test_model": args.model,
        "by_mode": by_mode,
        "by_category": by_cat,
        "delta": delta,
        "delta_sign": "+" if delta >= 0 else "-",
        "note": (
            "EVAL-013: positive delta means task-specific lessons helped. "
            "Compare to EVAL-011 generic-lesson delta to measure specificity benefit."
        ),
    }
    summary_path = out_path.with_suffix(".summary.json")
    summary_path.write_text(json.dumps(summary, indent=2))

    print(f"\n=== {args.tag} summary ===")
    print(f"Mode A (with specific lesson): {by_mode.get('A', {}).get('rate', 0):.1%}")
    print(f"Mode B (no lesson):            {by_mode.get('B', {}).get('rate', 0):.1%}")
    print(f"Delta (A − B):                 {delta:+.3f}")
    print(f"Summary written: {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
