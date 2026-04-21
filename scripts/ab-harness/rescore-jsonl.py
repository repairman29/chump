#!/usr/bin/env python3
"""rescore-jsonl.py — re-score existing A/B JSONL files with a non-Anthropic judge.

Reads a JSONL produced by run-catattack-sweep.py or the cloud harness
(with agent_text_preview + task_id fields), calls a Together.ai model as
judge, and emits per-row judge_score_<slug> + judge_reasoning_<slug> fields
to a new JSONL.  Computes and prints judge-agreement statistics.

Usage:
    python3 scripts/ab-harness/rescore-jsonl.py \\
        --input logs/ab/eval-042-crossjudge-reflection-*.jsonl \\
        --rescore-with-judge together:Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8 \\
        --output logs/ab/eval-068-crossjudge-qwen3.jsonl

    python3 scripts/ab-harness/rescore-jsonl.py \\
        --input logs/ab/eval-042-crossjudge-*.jsonl \\
        --rescore-with-judge together:deepseek-ai/DeepSeek-V3 \\
        --output logs/ab/eval-068-crossjudge-deepseek.jsonl

Environment:
    TOGETHER_API_KEY   — required for together: judge models
    ANTHROPIC_API_KEY  — required for anthropic: judge models

Output format (one JSON per line):
    Each input row is emitted with two added fields:
      judge_score_<slug>     : 1 or 0 (or null if judge call failed)
      judge_reasoning_<slug> : string from judge

Agreement report is printed to stdout at the end.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Task prompt lookup — built from catattack sweep + perception fixture
# ---------------------------------------------------------------------------

def _load_catattack_tasks() -> dict[str, dict]:
    """Extract task definitions from run-catattack-sweep.py via ast.literal_eval."""
    script = Path(__file__).parent / "run-catattack-sweep.py"
    if not script.exists():
        return {}
    import ast, re
    src = script.read_text()
    # Find the TASKS list literal
    m = re.search(r"TASKS\s*=\s*(\[.*?\])", src, re.DOTALL)
    if not m:
        return {}
    try:
        tasks = ast.literal_eval(m.group(1))
        return {t["id"]: t for t in tasks if "id" in t}
    except Exception:
        return {}


def _load_fixture(name: str) -> dict[str, dict]:
    fixture = Path(__file__).parent / "fixtures" / name
    if not fixture.exists():
        return {}
    data = json.loads(fixture.read_text())
    tasks = data.get("tasks", data) if isinstance(data, dict) else data
    return {t["id"]: t for t in tasks if "id" in t}


def _load_perception_tasks() -> dict[str, dict]:
    return _load_fixture("perception_tasks.json")


def build_task_lookup() -> dict[str, dict]:
    lookup: dict[str, dict] = {}
    lookup.update(_load_catattack_tasks())
    # Load every *_tasks.json fixture — covers perception, neuromod,
    # memory_recall, multiturn, longitudinal, coordination, etc.
    fixtures_dir = Path(__file__).parent / "fixtures"
    if fixtures_dir.is_dir():
        for fp in fixtures_dir.glob("*_tasks.json"):
            lookup.update(_load_fixture(fp.name))
    return lookup


# ---------------------------------------------------------------------------
# Judge prompt
# ---------------------------------------------------------------------------

_JUDGE_TEMPLATE = """\
Task: {task_prompt}
AI Response: {ai_response}

Did the AI response correctly address the task?

Scoring rules (EVAL-072, 2026-04-20):
1. Binary only — no partial credit. Score 1 only if the task was FULLY completed as
   specified by the rubric. Partial attempts, near-misses, and "showed work but did
   not finish" all score 0.
2. Tool-use rubrics — if the task rubric requires the agent to USE a tool (not just
   describe one), then an honest polite decline, an explanation of inability, or a
   refusal to invoke the tool scores 0. Politeness does not substitute for completion.
3. Read the rubric literally. Do not award credit for reasoning that is adjacent to
   the correct answer but does not produce it. Do not round up 0.4 to 1.

Reply with exactly: CORRECT: 1 or CORRECT: 0"""


def _make_judge_prompt(task_prompt: str, ai_response: str) -> str:
    return _JUDGE_TEMPLATE.format(
        task_prompt=task_prompt,
        ai_response=ai_response if ai_response.strip() else "(no output)",
    )


def _parse_judge_reply(text: str) -> Optional[int]:
    """Return 1, 0, or None from a judge reply."""
    t = text.strip().upper()
    if "CORRECT: 1" in t:
        return 1
    if "CORRECT: 0" in t:
        return 0
    # Lenient: look for a lone 1 or 0 at end
    import re
    m = re.search(r"\b([01])\s*$", t)
    if m:
        return int(m.group(1))
    return None


# ---------------------------------------------------------------------------
# Together.ai call
# ---------------------------------------------------------------------------

def _call_together(model: str, prompt: str, *, max_tokens: int = 64, retries: int = 3) -> Optional[str]:
    api_key = os.environ.get("TOGETHER_API_KEY", "")
    if not api_key:
        print("  [warn] TOGETHER_API_KEY not set — skipping", file=sys.stderr)
        return None

    payload = json.dumps({
        "model": model,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.0,
    }).encode()

    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                "https://api.together.xyz/v1/chat/completions",
                data=payload,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                    "User-Agent": "chump-eval-harness/1.0",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.load(resp)
                return data["choices"][0]["message"]["content"]
        except urllib.error.HTTPError as e:
            body = e.read().decode()[:200]
            if e.code == 429:
                wait = 2 ** attempt
                print(f"  [rate-limit] attempt {attempt+1}, sleeping {wait}s: {body}", file=sys.stderr)
                time.sleep(wait)
            else:
                print(f"  [http-error {e.code}] {body}", file=sys.stderr)
                return None
        except Exception as exc:
            print(f"  [error] {exc}", file=sys.stderr)
            if attempt < retries - 1:
                time.sleep(1)
    return None


def _call_anthropic(model: str, prompt: str, *, max_tokens: int = 64) -> Optional[str]:
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        return None
    payload = json.dumps({
        "model": model,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    try:
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
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
            return data["content"][0]["text"]
    except Exception as exc:
        print(f"  [anthropic-error] {exc}", file=sys.stderr)
        return None


def call_judge(judge_spec: str, prompt: str) -> tuple[Optional[int], str]:
    """Call the specified judge and return (score, reasoning)."""
    if judge_spec.startswith("together:"):
        model = judge_spec[len("together:"):]
        reply = _call_together(model, prompt)
    elif judge_spec.startswith("anthropic:"):
        model = judge_spec[len("anthropic:"):]
        reply = _call_anthropic(model, prompt)
    else:
        # Bare model name — assume Together
        reply = _call_together(judge_spec, prompt)

    if reply is None:
        return None, "(judge call failed)"
    score = _parse_judge_reply(reply)
    return score, reply.strip()


# ---------------------------------------------------------------------------
# Field name slug
# ---------------------------------------------------------------------------

def judge_slug(judge_spec: str) -> str:
    """Convert 'together:Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8' → 'qwen3_coder_480b'."""
    model = judge_spec.split(":")[-1]
    # Take last path component, lowercase, collapse non-alnum to _
    import re
    name = model.split("/")[-1].lower()
    # Strip common suffixes
    for suf in ["-instruct-fp8", "-instruct", "-fp8", "-turbo"]:
        if name.endswith(suf):
            name = name[: -len(suf)]
    return re.sub(r"[^a-z0-9]+", "_", name).strip("_")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", nargs="+", required=True, help="Input JSONL files")
    ap.add_argument(
        "--rescore-with-judge",
        required=True,
        help="Judge spec, e.g. together:Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8",
    )
    ap.add_argument("--output", help="Output JSONL (default: stdout)")
    ap.add_argument("--dry-run", action="store_true", help="Print first 5 rows, no API calls")
    ap.add_argument("--max-rows", type=int, default=0, help="Limit rows per file (0=all)")
    args = ap.parse_args()

    judge_spec = args.rescore_with_judge
    slug = judge_slug(judge_spec)
    score_field = f"judge_score_{slug}"
    reason_field = f"judge_reasoning_{slug}"

    task_lookup = build_task_lookup()
    print(f"Task lookup: {len(task_lookup)} tasks loaded", file=sys.stderr)
    print(f"Judge: {judge_spec} → field slug '{slug}'", file=sys.stderr)

    out = open(args.output, "w") if args.output else sys.stdout

    total = matched = agreed = failed = 0
    per_faculty: dict[str, dict] = {}

    for input_path in args.input:
        rows = []
        with open(input_path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        rows.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue

        if args.max_rows:
            rows = rows[: args.max_rows]

        faculty = Path(input_path).stem.split("-")[0] if "-" in Path(input_path).stem else Path(input_path).stem
        faculty_stats = per_faculty.setdefault(faculty, {"total": 0, "matched": 0, "agreed": 0, "failed": 0})
        print(f"\n--- {input_path} ({len(rows)} rows) ---", file=sys.stderr)

        for i, row in enumerate(rows):
            total += 1
            faculty_stats["total"] += 1

            # Skip rows that are clearly noise
            if row.get("truncated_to_free_disk_space"):
                out.write(json.dumps(row) + "\n")
                continue

            task_id = row.get("task_id", "")
            agent_text = row.get("agent_text_preview") or row.get("response_text") or row.get("response") or ""
            orig_score = row.get("judge_score")

            # Look up task prompt
            task_info = task_lookup.get(task_id)
            if not task_info:
                row[score_field] = None
                row[reason_field] = f"(task {task_id!r} not in lookup)"
                out.write(json.dumps(row) + "\n")
                failed += 1
                faculty_stats["failed"] += 1
                continue

            task_prompt = task_info.get("prompt") or task_info.get("user_message") or task_id
            rubric = task_info.get("judge_rubric") or task_info.get("expected_properties") or ""
            if rubric:
                task_prompt = f"{task_prompt}\n[Rubric: {rubric}]"

            if args.dry_run:
                print(f"  [{i}] task={task_id} agent_text={repr(agent_text)[:60]} orig_score={orig_score}")
                row[score_field] = None
                row[reason_field] = "(dry-run)"
                out.write(json.dumps(row) + "\n")
                if i >= 4:
                    break
                continue

            judge_prompt = _make_judge_prompt(task_prompt, agent_text)
            new_score, reasoning = call_judge(judge_spec, judge_prompt)

            row[score_field] = new_score
            row[reason_field] = reasoning
            out.write(json.dumps(row) + "\n")
            out.flush()

            matched += 1
            faculty_stats["matched"] += 1

            if new_score is not None and orig_score is not None:
                orig_bin = 1 if float(orig_score) >= 0.5 else 0
                if new_score == orig_bin:
                    agreed += 1
                    faculty_stats["agreed"] += 1
                else:
                    print(
                        f"  [disagree] {task_id}: orig={orig_score} new={new_score} | {reasoning[:60]}",
                        file=sys.stderr,
                    )
            elif new_score is None:
                failed += 1
                faculty_stats["failed"] += 1

            if (i + 1) % 10 == 0:
                so_far = faculty_stats["agreed"]
                so_far_n = faculty_stats["matched"]
                pct = 100 * so_far / so_far_n if so_far_n else 0
                print(f"  {i+1}/{len(rows)} — agreement so far: {so_far}/{so_far_n} ({pct:.0f}%)", file=sys.stderr)

    if args.output:
        out.close()

    # ── Agreement report ──────────────────────────────────────────────────────
    print("\n" + "=" * 60)
    print(f"EVAL-068 Cross-Judge Agreement Report")
    print(f"New judge: {judge_spec}")
    print("=" * 60)
    print(f"{'Faculty':<30} {'Rows':>5} {'Scored':>7} {'Agree':>7} {'Agree%':>7}")
    print("-" * 60)
    for fac, s in sorted(per_faculty.items()):
        n = s["matched"]
        a = s["agreed"]
        pct = 100 * a / n if n else 0
        print(f"{fac:<30} {s['total']:>5} {n:>7} {a:>7} {pct:>6.1f}%")
    print("-" * 60)
    overall = 100 * agreed / matched if matched else 0
    print(f"{'TOTAL':<30} {total:>5} {matched:>7} {agreed:>7} {overall:>6.1f}%")
    print("=" * 60)
    if overall >= 80:
        print("✓ Agreement ≥80% — Anthropic judge results are cross-validated.")
    else:
        print("✗ Agreement <80% — File EVAL-069 to investigate judge methodology.")


if __name__ == "__main__":
    main()
