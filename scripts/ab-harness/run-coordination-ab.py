#!/usr/bin/env python3.12
"""run-coordination-ab.py — EVAL-037: Multi-agent coordination A/B harness.

Purpose
-------
EVAL-037 measures whether CHUMP_COORD_ENABLED=1 (chump-coord NATS coordination)
adds measurable value on tasks that require multi-step handoffs — tasks where
intermediate results must be passed between steps, where conditional branching
depends on step-1 output, or where multiple sources must be aggregated.

Two cells:

    Cell A (solo agent, baseline)
        Dispatches each task to a single `chump -p <prompt>` call.
        No coordination layer; agent must handle all steps in one context.

    Cell B (coord-enabled)
        Dispatches each task with CHUMP_COORD_ENABLED=1.
        The chump-coord NATS broker is expected to be running.
        Intermediate handoff events are published to the coordination bus,
        enabling multi-agent step decomposition.

NOTE: Cell B requires a live chump-coord NATS broker. Cell A (baseline) can
run standalone with only a built chump binary + API keys. See AGENT_COORDINATION.md
for broker setup instructions.

Scoring
-------
Uses scoring_v2.score_trial() — same multi-axis scoring as run-cloud-v2.py:
  - did_attempt: made a genuine attempt (not a refusal stub)
  - hallucinated_tools: emitted fake <function_calls> markup
  - is_correct: judge says output addresses the prompt

Reports Wilson 95% CIs and delta per axis, formatted identically to the
run-cloud-v2.py summary block.

Usage
-----
    # Cell A only (no NATS required):
    python3.12 scripts/ab-harness/run-coordination-ab.py \\
        --fixture scripts/ab-harness/fixtures/coordination_tasks.json \\
        --model claude-haiku-4-5 \\
        --tag eval037-baseline \\
        --cell a

    # Full A/B (requires chump-coord NATS broker running on localhost:4222):
    python3.12 scripts/ab-harness/run-coordination-ab.py \\
        --fixture scripts/ab-harness/fixtures/coordination_tasks.json \\
        --model claude-haiku-4-5 \\
        --tag eval037-ab \\
        --cell ab

    # With explicit chump binary:
    python3.12 scripts/ab-harness/run-coordination-ab.py \\
        --fixture scripts/ab-harness/fixtures/coordination_tasks.json \\
        --model claude-haiku-4-5 \\
        --chump-bin ./target/release/chump \\
        --tag eval037-ab \\
        --cell ab

Prerequisites (Cell A)
-----------------------
    cargo build --release
    export ANTHROPIC_API_KEY=<key>   # or OPENAI_API_BASE + OPENAI_MODEL for Together

Prerequisites (Cell B — chump-coord NATS)
-----------------------------------------
    # Start NATS server (see docs/AGENT_COORDINATION.md for full setup):
    nats-server -p 4222 &
    # Start chump-coord broker:
    ./target/release/chump-coord --nats nats://localhost:4222 &
    export CHUMP_COORD_NATS_URL=nats://localhost:4222
    export CHUMP_COORD_ENABLED=1

See docs/eval/EVAL-037-coordination-ab.md for methodology, decision criteria,
and expected timelines.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# Add parent dir to path for scoring_v2
sys.path.insert(0, str(Path(__file__).parent))
from scoring_v2 import score_trial, delta_significance, wilson_ci  # noqa: E402

JUDGE_SYSTEM = """You are an evaluator for a multi-step agentic task. Read the
rubric, then read the agent's response. Reply with exactly:
SCORE: <float 0.0-1.0>
REASONING: <one sentence>

The score reflects how well the response satisfies the rubric. Key criteria:
- 1.0 = all steps completed, intermediate results correctly propagated
- 0.5 = partial completion (some steps done, handoff incomplete)
- 0.0 = no real attempt or fabricated values without reading actual files"""


# ---------------------------------------------------------------------------
# Trial execution
# ---------------------------------------------------------------------------

def run_trial(task: dict, cell: str, args) -> dict:
    """Run one trial against the chump binary.

    Cell A: standard chump invocation (no coord).
    Cell B: CHUMP_COORD_ENABLED=1 + optional CHUMP_COORD_NATS_URL.

    Returns a result dict compatible with scoring_v2 and the summary builder.
    """
    env = os.environ.copy()

    if cell == "A":
        # Solo agent — strip any coordination env vars that may be set globally
        env.pop("CHUMP_COORD_ENABLED", None)
        env.pop("CHUMP_COORD_NATS_URL", None)
    else:
        # Cell B: coord-enabled
        env["CHUMP_COORD_ENABLED"] = "1"
        if args.nats_url:
            env["CHUMP_COORD_NATS_URL"] = args.nats_url

    if args.model:
        # Allow model override via env — chump reads OPENAI_MODEL or ANTHROPIC_MODEL
        if args.model.startswith("claude"):
            env["ANTHROPIC_MODEL"] = args.model
        else:
            env["OPENAI_MODEL"] = args.model

    t0 = time.time()
    agent_text = ""
    success = False
    try:
        result = subprocess.run(
            [args.chump_bin, "-p", task["prompt"]],
            env=env,
            capture_output=True,
            text=True,
            timeout=args.timeout,
        )
        agent_text = result.stdout.strip()
        success = result.returncode == 0
        if not success:
            sys.stderr.write(
                f"  [trial] chump exited {result.returncode} for "
                f"{task['id']} cell={cell}: {result.stderr[:200]}\n"
            )
    except subprocess.TimeoutExpired:
        sys.stderr.write(
            f"  [trial] timeout ({args.timeout}s) for {task['id']} cell={cell}\n"
        )
    except FileNotFoundError:
        print(
            f"\nERROR: chump binary not found at '{args.chump_bin}'.\n"
            f"Build it first: cargo build --release\n"
            f"Then re-run with: --chump-bin ./target/release/chump",
            file=sys.stderr,
        )
        sys.exit(1)

    agent_ms = int((time.time() - t0) * 1000)

    # Score without judge (scoring_v2 heuristic-only path when no judge model)
    rubric = task.get("judge_rubric") or _synth_rubric(task)
    judge_score, judge_reasoning = _judge_response(agent_text, rubric, args)
    ts = score_trial(agent_text, judge_score, args.judge_threshold)

    return {
        "tag": args.tag,
        "task_id": task["id"],
        "category": task.get("category", "unknown"),
        "coordination_required": task.get("coordination_required", False),
        "handoff_description": task.get("handoff_description", ""),
        "cell": cell,
        "model": args.model or "(env)",
        "chump_bin": args.chump_bin,
        "coord_enabled": cell == "B",
        "nats_url": args.nats_url if cell == "B" else None,
        "agent_duration_ms": agent_ms,
        "agent_text_chars": len(agent_text),
        "agent_text_preview": agent_text[:2000],
        "judge_score": judge_score,
        "judge_reasoning": judge_reasoning,
        "did_attempt": ts.did_attempt,
        "hallucinated_tools": ts.hallucinated_tools,
        "is_correct": ts.is_correct,
        "scored": ts.is_correct,
        "success": success,
    }


def _synth_rubric(task: dict) -> str:
    """Build judge rubric from task expected_properties."""
    props = task.get("expected_properties") or []
    lines = [f"For prompt: '{task['prompt'][:200]}', the response should:"]
    for p in props:
        if isinstance(p, dict):
            kind = p.get("kind", "")
            arg = p.get("arg", "")
            if kind == "uses_tool":
                lines.append(f"use the `{arg}` tool (or describe using it)")
            elif kind == "addresses":
                lines.append(f"address: {arg}")
            elif kind == "asks_clarification":
                lines.append("ask a clarifying question")
            elif kind == "no_destructive_action":
                lines.append("NOT immediately fire a destructive action")
            else:
                lines.append(str(p))
        else:
            lines.append(str(p))
    return "\n".join(lines)


def _judge_response(agent_text: str, rubric: str, args) -> tuple[float, str]:
    """Score response with LLM judge if configured, otherwise use heuristic."""
    if not args.judge:
        # Heuristic: non-empty response that doesn't look like a refusal
        refusal_phrases = [
            "i cannot", "i can't", "i'm unable", "i am unable",
            "i don't have access", "i have no access",
        ]
        if not agent_text:
            return 0.0, "empty response"
        lower = agent_text.lower()
        if any(p in lower for p in refusal_phrases) and len(agent_text) < 200:
            return 0.2, "brief refusal"
        return 0.7, "non-empty, non-refusal (heuristic; use --judge for LLM scoring)"

    # LLM judge path — calls Together.ai if key is available
    together_key = os.environ.get("TOGETHER_API_KEY", "")
    if not together_key:
        sys.stderr.write(
            "  [judge] TOGETHER_API_KEY not set — falling back to heuristic scoring\n"
        )
        return _judge_response(agent_text, rubric, _Args(judge=None))

    import urllib.request

    judge_model = args.judge
    if judge_model.startswith("together:"):
        judge_model = judge_model[len("together:"):]

    messages = [
        {"role": "system", "content": JUDGE_SYSTEM},
        {
            "role": "user",
            "content": f"RUBRIC:\n{rubric}\n\nASSISTANT RESPONSE:\n{agent_text or '(empty)'}",
        },
    ]
    payload = {"model": judge_model, "messages": messages, "max_tokens": 200}
    req = urllib.request.Request(
        "https://api.together.xyz/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "content-type": "application/json",
            "authorization": f"Bearer {together_key}",
            "user-agent": "chump-eval037-harness/1.0",
        },
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = json.loads(r.read())
                text = ((raw.get("choices") or [{}])[0].get("message") or {}).get(
                    "content", ""
                )
                score = 0.0
                reasoning = ""
                for line in text.splitlines():
                    if line.startswith("SCORE:"):
                        try:
                            score = float(line.split(":", 1)[1].strip())
                        except ValueError:
                            pass
                    elif line.startswith("REASONING:"):
                        reasoning = line.split(":", 1)[1].strip()
                return max(0.0, min(1.0, score)), reasoning
        except Exception as e:  # noqa: BLE001
            if attempt == 3:
                sys.stderr.write(f"  [judge] all retries failed: {e}\n")
                return 0.5, f"judge error: {e}"
            time.sleep(2 ** (attempt + 1))
    return 0.5, "judge error: max retries"


class _Args:
    """Minimal args stub for heuristic judge fallback."""
    def __init__(self, judge: Optional[str]) -> None:
        self.judge = judge


# ---------------------------------------------------------------------------
# Summary builder (mirrors run-cloud-v2.py format)
# ---------------------------------------------------------------------------

def build_summary(args, rows: list[dict]) -> dict:
    by_cell: dict[str, dict] = {}
    for cell in ("A", "B"):
        cell_rows = [r for r in rows if r["cell"] == cell]
        n = len(cell_rows)
        if n == 0:
            continue
        n_correct = sum(1 for r in cell_rows if r["is_correct"])
        n_attempt = sum(1 for r in cell_rows if r["did_attempt"])
        n_halluc = sum(1 for r in cell_rows if r["hallucinated_tools"])
        by_cell[cell] = {
            "n": n,
            "is_correct": {
                "passes": n_correct,
                "rate": n_correct / n,
                "ci_95": list(wilson_ci(n_correct, n)),
            },
            "did_attempt": {
                "passes": n_attempt,
                "rate": n_attempt / n,
                "ci_95": list(wilson_ci(n_attempt, n)),
            },
            "hallucinated_tools": {
                "count": n_halluc,
                "rate": n_halluc / n,
                "ci_95": list(wilson_ci(n_halluc, n)),
            },
            "mean_judge_score": sum(r["judge_score"] for r in cell_rows) / n,
        }

    deltas: dict[str, dict] = {}
    if "A" in by_cell and "B" in by_cell:
        a_n = by_cell["A"]["n"]
        b_n = by_cell["B"]["n"]
        for axis in ("is_correct", "did_attempt", "hallucinated_tools"):
            passes_key = "count" if axis == "hallucinated_tools" else "passes"
            deltas[axis] = delta_significance(
                by_cell["A"][axis][passes_key], a_n,
                by_cell["B"][axis][passes_key], b_n,
            )

    return {
        "tag": args.tag,
        "harness": "run-coordination-ab",
        "gap": "EVAL-037",
        "fixture": args.fixture,
        "model": args.model or "(env)",
        "chump_bin": args.chump_bin,
        "cells_run": args.cell,
        "nats_url": args.nats_url,
        "judge_model": args.judge,
        "judge_threshold": args.judge_threshold,
        "task_count": len([r for r in rows if r["cell"] == "A"]),
        "trial_count": len(rows),
        "by_cell": by_cell,
        "deltas": deltas,
        "cell_a_description": "solo agent — no coordination layer (CHUMP_COORD_ENABLED unset)",
        "cell_b_description": "coord-enabled — CHUMP_COORD_ENABLED=1, NATS broker required",
        "decision_rule": (
            "Cell B > Cell A with non-overlapping 95% Wilson CIs on is_correct "
            "on coordination_required tasks → chump-coord overhead is justified. "
            "cis_overlap=True → null result; document and review NATS broker cost."
        ),
        "interpretation_note": (
            "Cell B requires a live chump-coord NATS broker. "
            "If Cell B was not run, only Cell A baseline is present. "
            "Deltas with cis_overlap=True are within sampling noise — do not cite as findings."
        ),
    }


def print_summary(s: dict) -> None:
    print(f"\n=== EVAL-037 coordination A/B summary: {s['tag']} ===")
    print(f"gap=EVAL-037  fixture={Path(s['fixture']).name}")
    print(f"model={s['model']}  judge={s['judge_model'] or 'heuristic'}")
    print(f"cells_run={s['cells_run']}  nats_url={s['nats_url'] or 'N/A'}\n")

    cell_labels = {
        "A": "solo agent (no coord)  ",
        "B": "coord-enabled (NATS)   ",
    }
    for cell in ("A", "B"):
        if cell not in s["by_cell"]:
            print(f"  cell {cell}: not run")
            continue
        c = s["by_cell"][cell]
        label = cell_labels[cell]
        print(
            f"  cell {cell} ({label}): "
            f"correct={c['is_correct']['rate']:.2f} "
            f"[{c['is_correct']['ci_95'][0]:.2f}–{c['is_correct']['ci_95'][1]:.2f}]  "
            f"attempt={c['did_attempt']['rate']:.2f}  "
            f"halluc={c['hallucinated_tools']['rate']:.2f}  "
            f"mean_judge={c['mean_judge_score']:.3f}  "
            f"n={c['n']}"
        )

    if s["deltas"]:
        print()
        for axis in ("is_correct", "did_attempt", "hallucinated_tools"):
            if axis not in s["deltas"]:
                continue
            d = s["deltas"][axis]
            noise_flag = " *** WITHIN NOISE — do not cite ***" if d["cis_overlap"] else " provisional signal"
            print(f"  Delta {axis:22s}: {d['delta']:+.3f}{noise_flag}")

    print(f"\nDecision rule: {s['decision_rule']}")
    print(f"\nNote: {s['interpretation_note']}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        description=(
            "EVAL-037: Multi-agent coordination A/B harness. "
            "Tests whether CHUMP_COORD_ENABLED=1 improves pass rates on "
            "coordination-requiring multi-step handoff tasks."
        )
    )
    ap.add_argument(
        "--fixture",
        default="scripts/ab-harness/fixtures/coordination_tasks.json",
        help="Path to coordination_tasks.json fixture",
    )
    ap.add_argument(
        "--tag",
        default=f"eval037-{int(time.time())}",
        help="Unique run tag (used in output filenames)",
    )
    ap.add_argument(
        "--cell",
        choices=("a", "b", "ab"),
        default="a",
        help=(
            "Which cells to run. "
            "'a' = Cell A baseline only (no NATS required). "
            "'b' = Cell B coord-enabled only. "
            "'ab' = full A/B sweep (Cell B requires NATS broker running)."
        ),
    )
    ap.add_argument(
        "--chump-bin",
        default="./target/release/chump",
        help="Path to chump binary (default: ./target/release/chump)",
    )
    ap.add_argument(
        "--model",
        default=None,
        help=(
            "Model name to pass as ANTHROPIC_MODEL or OPENAI_MODEL env var. "
            "Prefix 'claude-' routes via Anthropic, others via OPENAI_API_BASE."
        ),
    )
    ap.add_argument(
        "--judge",
        default=None,
        help=(
            "Judge model for LLM scoring (e.g. together:meta-llama/Llama-3.3-70B-Instruct-Turbo). "
            "If unset, falls back to heuristic scoring."
        ),
    )
    ap.add_argument("--judge-threshold", type=float, default=0.5)
    ap.add_argument(
        "--nats-url",
        default=os.environ.get("CHUMP_COORD_NATS_URL", "nats://localhost:4222"),
        help="NATS broker URL for Cell B (default: nats://localhost:4222)",
    )
    ap.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Max tasks to run per cell (default: all tasks in fixture)",
    )
    ap.add_argument(
        "--timeout",
        type=int,
        default=120,
        help="Per-trial timeout in seconds (default: 120)",
    )
    args = ap.parse_args()

    # Binary check
    if not Path(args.chump_bin).exists():
        print(
            f"ERROR: chump binary not found at '{args.chump_bin}'.\n"
            f"Build it first: cargo build --release",
            file=sys.stderr,
        )
        return 1

    # Load fixture
    fixture_path = Path(args.fixture)
    if not fixture_path.exists():
        print(f"ERROR: fixture not found: {fixture_path}", file=sys.stderr)
        return 1

    fixture = json.loads(fixture_path.read_text())
    tasks = fixture["tasks"]
    if args.limit:
        tasks = tasks[: args.limit]

    cells_to_run = []
    if args.cell in ("a", "ab"):
        cells_to_run.append("A")
    if args.cell in ("b", "ab"):
        cells_to_run.append("B")

    # Warn about Cell B if NATS isn't obviously reachable
    if "B" in cells_to_run:
        print(
            f"[coord-ab] Cell B requires chump-coord NATS broker at {args.nats_url}\n"
            f"[coord-ab] If the broker is not running, Cell B trials will fail or timeout.\n"
            f"[coord-ab] See docs/AGENT_COORDINATION.md for broker setup instructions.\n"
        )

    out_dir = Path("logs/ab")
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = int(time.time())
    jsonl_path = out_dir / f"{args.tag}-{ts}.jsonl"
    summary_path = out_dir / f"{args.tag}-{ts}.summary.json"

    print(f"[coord-ab] EVAL-037 — {len(tasks)} tasks × {len(cells_to_run)} cell(s)")
    print(f"[coord-ab] cells: {cells_to_run}")
    print(f"[coord-ab] model: {args.model or '(from env)'}")
    print(f"[coord-ab] judge: {args.judge or 'heuristic'}")
    print(f"[coord-ab] chump: {args.chump_bin}")
    print(f"[coord-ab] output: {jsonl_path}\n")

    rows: list[dict] = []
    with jsonl_path.open("w") as f:
        for i, task in enumerate(tasks, 1):
            print(f"[{i:3d}/{len(tasks)}] {task['id']} ({task.get('category', '?')})")
            for cell in cells_to_run:
                row = run_trial(task, cell, args)
                rows.append(row)
                f.write(json.dumps(row) + "\n")
                f.flush()
                hall_marker = " HALLUCINATED" if row["hallucinated_tools"] else ""
                print(
                    f"  [{cell}] judge={row['judge_score']:.2f} "
                    f"correct={row['is_correct']} attempt={row['did_attempt']}"
                    f"{hall_marker}  ({row['agent_duration_ms']}ms)"
                )

    summary = build_summary(args, rows)
    summary_path.write_text(json.dumps(summary, indent=2))
    print_summary(summary)
    print(f"\nTrial log: {jsonl_path}")
    print(f"Summary:   {summary_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
