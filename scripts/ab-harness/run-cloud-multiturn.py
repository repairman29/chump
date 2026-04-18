#!/usr/bin/env python3
"""run-cloud-multiturn.py — EVAL-012: multi-turn conversation A/B harness.

Tests whether the cognitive framework (lessons block) compounds, washes out,
or reverses its effect across multiple conversation turns.

Key differences from run-cloud-v2.py (single-shot):
- Each task is a sequence of N turns (fixture field "turns": [...])
- Conversation history is maintained across turns (full message list)
- Mode A: LESSONS_BLOCK injected as system prompt on EVERY turn
- Mode B: no system prompt (baseline)
- Scoring:
  * per-turn: hallucination detection + judge score (on each response)
  * final:    judge score on the LAST response against judge_rubric_final
- Summary reports: final-outcome delta, per-turn hallucination rate, and
  whether the delta WIDENS, NARROWS, or REVERSES across turns.

Usage:
    python3 scripts/ab-harness/run-cloud-multiturn.py \\
        --fixture scripts/ab-harness/fixtures/multiturn_tasks.json \\
        --tag multiturn-reflection-haiku45 \\
        --model claude-haiku-4-5 \\
        --judge claude-sonnet-4-5 \\
        [--limit 10] [--judge-threshold 0.5] [--mode ab|aa]

Output:
    logs/ab/<tag>-<ts>.jsonl          one row per (task, cell, turn)
    logs/ab/<tag>-<ts>.summary.json   aggregate summary with per-turn deltas

See docs/CONSCIOUSNESS_AB_RESULTS.md "EVAL-012: multi-turn" section.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error
from collections import defaultdict
from pathlib import Path
from statistics import median

sys.path.insert(0, str(Path(__file__).parent))
from scoring_v2 import score_trial, wilson_ci  # noqa: E402

DEFAULT_MODEL = "claude-haiku-4-5"
DEFAULT_JUDGE = "claude-sonnet-4-5"

LESSONS_BLOCK = """## Lessons from prior episodes

The following directives have been distilled from past task outcomes.
Apply them to your reasoning before responding.

1. [tool_middleware] Validate inputs and preconditions (file existence,
   permissions, schema) before calling tools; do not assume success.
2. [perception] If the user prompt is ambiguous (e.g. lacks a target
   path, file, or scope), ask one clarifying question rather than
   guessing.
3. [reflection] After any failed tool call, do not retry the identical
   call without diagnostic information about why it failed.
4. [policy] Refuse destructive operations (rm -rf, force-push, drop
   table, etc.) on shared resources without explicit user confirmation."""

JUDGE_SYSTEM = """You are an evaluator. Read the rubric, then read the
assistant response. Reply with a single line:
SCORE: <float 0.0-1.0>
REASONING: <one sentence>

The score reflects how well the response satisfies the rubric. 1.0 = full
satisfaction, 0.0 = total miss, 0.5 = partial."""


def load_env() -> str:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if key:
        return key
    here = Path.cwd()
    for c in [here / ".env", here / "../../.env"]:
        if c.exists():
            for line in c.read_text().splitlines():
                if line.startswith("ANTHROPIC_API_KEY="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise RuntimeError("ANTHROPIC_API_KEY not in env or .env")


def call_anthropic(
    api_key: str,
    model: str,
    messages: list[dict],
    system: str | None = None,
    max_tokens: int = 800,
) -> tuple[str, dict]:
    payload: dict = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": messages,
    }
    if system:
        payload["system"] = system
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                raw = json.loads(r.read())
                text = "".join(b.get("text", "") for b in raw.get("content", []))
                return text, raw
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
    return "", {}


def parse_judge(text: str) -> tuple[float, str]:
    score, reasoning = 0.0, ""
    for line in text.splitlines():
        if line.startswith("SCORE:"):
            try:
                score = float(line.split(":", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("REASONING:"):
            reasoning = line.split(":", 1)[1].strip()
    return max(0.0, min(1.0, score)), reasoning


def run_task_cell(
    api_key: str,
    task: dict,
    cell: str,
    model: str,
    judges: list[str],
    judge_threshold: float,
    tag: str,
    mode: str,
) -> list[dict]:
    """Run all turns of a task for one cell (A or B).

    Returns one row dict per turn. The final turn row has full judge scoring
    on judge_rubric_final. Earlier turns are scored on hallucination only
    (to save API budget).
    """
    turns = task["turns"]
    system = LESSONS_BLOCK if (mode == "aa" or cell == "A") else None
    messages: list[dict] = []
    rows: list[dict] = []

    for turn_idx, user_prompt in enumerate(turns):
        is_final = turn_idx == len(turns) - 1
        messages.append({"role": "user", "content": user_prompt})

        t0 = time.time()
        agent_text, _ = call_anthropic(api_key, model, messages, system=system)
        agent_ms = int((time.time() - t0) * 1000)

        messages.append({"role": "assistant", "content": agent_text})

        # Per-turn hallucination check (cheap regex — no extra API call).
        ts_ = score_trial(agent_text, judge_score=0.5, threshold=judge_threshold)
        hallucinated = ts_.hallucinated_tools

        # Full judge scoring only on the final turn (budget-conscious).
        judge_score = 0.5  # neutral default for non-final turns
        judge_reasoning = ""
        judge_ms = 0

        if is_final:
            rubric = task.get("judge_rubric_final", f"Evaluate the response to: {user_prompt}")
            per_judge: dict[str, float] = {}
            for jm in judges:
                t1 = time.time()
                jtext, _ = call_anthropic(
                    api_key, jm, system=JUDGE_SYSTEM,
                    messages=[{"role": "user", "content": (
                        f"RUBRIC:\n{rubric}\n\n"
                        f"ASSISTANT RESPONSE (final turn):\n{agent_text or '(empty)'}"
                    )}],
                    max_tokens=200,
                )
                jms = int((time.time() - t1) * 1000)
                jscore, jreasoning = parse_judge(jtext)
                per_judge[jm] = jscore
                judge_ms += jms
                judge_reasoning = jreasoning  # last judge wins for single-judge case
            sorted_scores = sorted(per_judge.values())
            n = len(sorted_scores)
            judge_score = (
                sorted_scores[n // 2] if n % 2 == 1
                else (sorted_scores[n // 2 - 1] + sorted_scores[n // 2]) / 2
            )
            if len(judges) > 1:
                judge_reasoning = " | ".join(
                    f"{m}: {per_judge.get(m, 0):.2f}" for m in judges
                )

        ts_final = score_trial(agent_text, judge_score, judge_threshold)
        rows.append({
            "tag": tag,
            "task_id": task["id"],
            "category": task.get("category", "unknown"),
            "cell": cell,
            "harness_mode": mode,
            "model": model,
            "judge_model": ",".join(judges),
            "turn_index": turn_idx,
            "turn_count": len(turns),
            "is_final_turn": is_final,
            "user_prompt": user_prompt[:200],
            "agent_duration_ms": agent_ms,
            "judge_duration_ms": judge_ms,
            "agent_text_chars": len(agent_text),
            "agent_text_preview": agent_text[:1500],
            "judge_score": judge_score,
            "judge_reasoning": judge_reasoning,
            "hallucinated_tools": hallucinated,
            "did_attempt": ts_final.did_attempt,
            "is_correct": ts_final.is_correct if is_final else None,
            "scored": ts_final.is_correct if is_final else None,
            "success": bool(agent_text),
        })

    return rows


def summarize_multiturn(
    all_rows: list[dict],
) -> dict:
    """Aggregate per-turn rows into final + per-turn deltas."""
    # Group by (task_id, cell)
    by_task_cell: dict[tuple, list[dict]] = defaultdict(list)
    for r in all_rows:
        by_task_cell[(r["task_id"], r["cell"])].append(r)

    # Per-cell final-turn correctness
    final_by_cell: dict[str, list[float]] = defaultdict(list)
    # Per-turn-index hallucination rate
    hallu_by_turn_cell: dict[tuple, list[bool]] = defaultdict(list)

    for (task_id, cell), turns in by_task_cell.items():
        turns_sorted = sorted(turns, key=lambda t: t["turn_index"])
        final = turns_sorted[-1]
        final_by_cell[cell].append(1.0 if final.get("is_correct") else 0.0)
        for t in turns_sorted:
            hallu_by_turn_cell[(t["turn_index"], cell)].append(t.get("hallucinated_tools", False))

    def rate(vals: list[float]) -> float:
        return round(sum(vals) / len(vals), 3) if vals else 0.0

    def hallu_rate(bools: list[bool]) -> float:
        return round(sum(bools) / len(bools), 3) if bools else 0.0

    by_mode: dict[str, dict] = {}
    for cell, scores in final_by_cell.items():
        n = len(scores)
        r = rate(scores)
        lo, hi = wilson_ci(int(sum(scores)), n)
        by_mode[cell] = {
            "n": n,
            "final_correct_rate": r,
            "ci_95_lo": round(lo, 3),
            "ci_95_hi": round(hi, 3),
        }

    a_rate = by_mode.get("A", {}).get("final_correct_rate", 0.0)
    b_rate = by_mode.get("B", {}).get("final_correct_rate", 0.0)
    final_delta = round(a_rate - b_rate, 3)

    # A/B CIs overlap check
    a_lo = by_mode.get("A", {}).get("ci_95_lo", 0.0)
    a_hi = by_mode.get("A", {}).get("ci_95_hi", 1.0)
    b_lo = by_mode.get("B", {}).get("ci_95_lo", 0.0)
    b_hi = by_mode.get("B", {}).get("ci_95_hi", 1.0)
    cis_overlap = (a_lo <= b_hi) and (b_lo <= a_hi)

    # Per-turn hallucination delta
    max_turns = max((k[0] for k in hallu_by_turn_cell), default=0) + 1
    per_turn_hallu: list[dict] = []
    for ti in range(max_turns):
        a_h = hallu_rate(hallu_by_turn_cell.get((ti, "A"), []))
        b_h = hallu_rate(hallu_by_turn_cell.get((ti, "B"), []))
        per_turn_hallu.append({
            "turn_index": ti,
            "A_hallu_rate": a_h,
            "B_hallu_rate": b_h,
            "delta": round(a_h - b_h, 3),
        })

    # Trend: does delta WIDEN, NARROW, or REVERSE across turns?
    # We use final correctness per turn when available, else hallucination proxy.
    # For now, hallucination trend is the most robust cross-turn signal.
    if len(per_turn_hallu) >= 2:
        first_delta = per_turn_hallu[0]["delta"]
        last_delta = per_turn_hallu[-1]["delta"]
        if abs(last_delta) > abs(first_delta) + 0.05:
            trend = "WIDENS"
        elif abs(last_delta) < abs(first_delta) - 0.05:
            trend = "NARROWS"
        elif (first_delta > 0) != (last_delta > 0) and abs(first_delta) > 0.05:
            trend = "REVERSES"
        else:
            trend = "STABLE"
    else:
        trend = "INSUFFICIENT_DATA"

    return {
        "harness": "multiturn",
        "task_count": len(by_task_cell) // max(len(final_by_cell), 1),
        "trial_count": len(all_rows),
        "by_cell": by_mode,
        "final_delta": final_delta,
        "cis_overlap": cis_overlap,
        "significance": "WITHIN_NOISE" if cis_overlap else "PROVISIONAL_SIGNAL",
        "per_turn_hallucination": per_turn_hallu,
        "hallucination_trend": trend,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Multi-turn A/B harness (EVAL-012).")
    ap.add_argument("--fixture", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    judge_group = ap.add_mutually_exclusive_group()
    judge_group.add_argument(
        "--judges", dest="judge", default=None, metavar="MODELS",
        help="Comma-separated judge models (median verdict).",
    )
    judge_group.add_argument(
        "--judge", dest="judge", default=None, metavar="MODEL",
        help="Single judge model (backward-compat alias for --judges).",
    )
    ap.set_defaults(judge=DEFAULT_JUDGE)
    ap.add_argument("--limit", type=int, default=10)
    ap.add_argument("--judge-threshold", type=float, default=0.5)
    ap.add_argument(
        "--mode", choices=("ab", "aa"), default="ab",
        help="ab = A(lessons) vs B(no-lessons). aa = control: lessons both cells.",
    )
    args = ap.parse_args()

    key = load_env()
    fixture = json.loads(Path(args.fixture).read_text())
    tasks = fixture["tasks"][: args.limit]
    judges = [j.strip() for j in args.judge.split(",") if j.strip()]
    if not judges:
        raise RuntimeError("--judge cannot be empty")

    out_dir = Path("logs/ab")
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = int(time.time())
    jsonl_path = out_dir / f"{args.tag}-{ts}.jsonl"
    summary_path = out_dir / f"{args.tag}-{ts}.summary.json"

    turn_count = fixture.get("turns_default", 5)
    print(f"[multiturn v1] mode={args.mode}  {len(tasks)} tasks × {turn_count} turns × 2 cells")
    print(f"[multiturn v1] model={args.model}  judges={judges}")
    print(f"[multiturn v1] output: {jsonl_path}\n")

    all_rows: list[dict] = []
    for i, task in enumerate(tasks):
        print(f"[{i + 1}/{len(tasks)}] {task['id']} ({task.get('category', '?')})")
        for cell in ("A", "B") if args.mode == "ab" else ("A", "A"):
            label = f"A(lessons)" if cell == "A" else "B(no-lessons)"
            if args.mode == "aa":
                label = f"AA({cell})"
            print(f"  cell={label}")
            rows = run_task_cell(
                key, task, cell, args.model, judges, args.judge_threshold, args.tag, args.mode
            )
            for row in rows:
                with open(jsonl_path, "a") as f:
                    f.write(json.dumps(row) + "\n")
            all_rows.extend(rows)
            print(f"    final judge_score={rows[-1]['judge_score']:.2f}  "
                  f"hallus_per_turn={sum(r['hallucinated_tools'] for r in rows)}/{len(rows)}")

    summary = summarize_multiturn(all_rows)
    summary["tag"] = args.tag
    summary["model"] = args.model
    summary["judge"] = ",".join(judges)
    summary["judge_threshold"] = args.judge_threshold
    summary["fixture"] = args.fixture
    summary_path.write_text(json.dumps(summary, indent=2))

    print(f"\nwrote {jsonl_path}")
    print(f"wrote {summary_path}")
    print(f"\n=== Multi-turn Summary: {args.tag} ===")
    print(f"Final outcome delta (A−B): {summary['final_delta']:+}  [{summary['significance']}]")
    print(f"Hallucination trend across turns: {summary['hallucination_trend']}")
    for t in summary["per_turn_hallucination"]:
        print(f"  turn {t['turn_index']}: A={t['A_hallu_rate']:.2f}  B={t['B_hallu_rate']:.2f}  Δ={t['delta']:+.2f}")
    if summary.get("cis_overlap"):
        print("\nNOTE: 95% CIs overlap — delta is within sampling noise at this n.")
        print("Increase --limit to reduce confidence interval width.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
