#!/usr/bin/env python3.12
"""run-spawn-lessons-ab.py — MEM-006-VALIDATE: spawn-loaded lessons A/B harness.

Purpose
-------
MEM-006 shipped `load_spawn_lessons()` + `CHUMP_LESSONS_AT_SPAWN_N` env var in
`src/agent_loop/prompt_assembler.rs`. The existing `run-cloud-v2.py` harness calls
provider APIs *directly*, bypassing Chump's prompt assembler — so spawn-lesson
injection is never exercised. This harness closes that gap.

Two approaches are supported (--mode flag):

    binary  (Option A, preferred)
        Calls `chump -p "<prompt>"` as a subprocess.
        Cell A: CHUMP_LESSONS_AT_SPAWN_N=5 (spawn-loaded lessons injected by the
                assembler before the prompt reaches the provider).
        Cell B: CHUMP_LESSONS_AT_SPAWN_N unset (baseline — no spawn lessons).
        Requires a built `chump` binary (cargo build --release) and
        TOGETHER_API_KEY + OPENAI_API_BASE/OPENAI_MODEL pointing at a Together
        endpoint.

    python  (Option B, fallback)
        Reads improvement targets from sessions/chump_memory.db directly (Option B
        from the gap spec). Formats them using the same lessons-block wording as
        `format_lessons_block()` in src/reflection_db.rs, then calls Together
        directly — no Rust binary needed. Falls back to an empty lessons block
        when the DB is absent (clean-room environment).

Design
------
- Cell A: spawn-loaded lessons injected
- Cell B: no spawn-loaded lessons (baseline)
- n=50 per cell (default; override with --limit)
- Judge: cross-family (Together:meta-llama/Llama-3.3-70B-Instruct-Turbo)
- Model: together:Qwen/Qwen2.5-7B-Instruct-Turbo (free tier, as specified)
- Scoring: scoring_v2.score_trial() (multi-axis: did_attempt / hallucinated_tools / is_correct)
- Reporting: Wilson 95% CIs + cis_overlap flag

Cost estimate
-------------
n=50 × 2 cells × Qwen-7B-turbo ≈ $0.01 total (Together free tier).
Judge calls (Llama-3.3-70B): n=100 × ~200 tokens ≈ $0.02 additional.
Total: ~$0.03 for the full sweep.

Usage
-----
    # Option A: chump binary path
    python3.12 scripts/ab-harness/run-spawn-lessons-ab.py \\
        --fixture scripts/ab-harness/fixtures/reflection_tasks.json \\
        --tag mem006-spawn-lessons-qwen7b \\
        --mode binary \\
        --chump-bin ./target/release/chump \\
        --model together:Qwen/Qwen2.5-7B-Instruct-Turbo \\
        --judge together:meta-llama/Llama-3.3-70B-Instruct-Turbo \\
        --limit 50

    # Option B: Python-side injection (no binary needed)
    python3.12 scripts/ab-harness/run-spawn-lessons-ab.py \\
        --fixture scripts/ab-harness/fixtures/reflection_tasks.json \\
        --tag mem006-spawn-lessons-qwen7b-py \\
        --mode python \\
        --model together:Qwen/Qwen2.5-7B-Instruct-Turbo \\
        --judge together:meta-llama/Llama-3.3-70B-Instruct-Turbo \\
        --limit 50 \\
        --db sessions/chump_memory.db

See docs/eval/MEM-006-VALIDATE-results.md for full methodology and decision criteria.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# Add parent dir to path for scoring_v2
sys.path.insert(0, str(Path(__file__).parent))
from scoring_v2 import score_trial, delta_significance, wilson_ci  # noqa: E402

TOGETHER_BASE = "https://api.together.xyz/v1"
TOGETHER_API_KEY = os.environ.get("TOGETHER_API_KEY", "")

# ---------------------------------------------------------------------------
# Lessons block format — mirrors src/reflection_db.rs::format_lessons_block()
# ---------------------------------------------------------------------------

LESSONS_HEADER = (
    "## Lessons from prior episodes\n"
    "The following directives came from structured reflections on previous tasks. "
    "Apply them when relevant; do not narrate that you are applying them.\n"
    "\n"
    "IMPORTANT: if you do not have actual tool access in this context, do NOT "
    "emit `<function_calls>`, `<tool_call>`, `<tool_use>`, or similar markup. "
    "Instead, describe in plain prose what you would do if tools were available, "
    "and acknowledge that you cannot execute commands directly.\n"
)

JUDGE_SYSTEM = """You are an evaluator. Read the rubric, then read the
assistant response. Reply with a single line:
SCORE: <float 0.0-1.0>
REASONING: <one sentence>

The score reflects how well the response satisfies the rubric. 1.0 = full
satisfaction, 0.0 = total miss, 0.5 = partial."""


# ---------------------------------------------------------------------------
# DB helpers (Option B: Python-side injection)
# ---------------------------------------------------------------------------

def load_lessons_from_db(db_path: str, n: int = 5) -> list[dict]:
    """Read top-N spawn lessons from sessions/chump_memory.db.

    Replicates the SQL ranking from src/reflection_db.rs::load_spawn_lessons():
      score = COUNT(*) / (1.0 + age_days / 7.0)   [recency × frequency]

    Returns list of dicts with keys: directive, priority, scope.
    Returns [] when the DB is absent or has no qualifying rows.
    """
    if not db_path or not Path(db_path).exists():
        return []
    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        sql = """
            SELECT directive,
                   MIN(priority)  AS priority,
                   MAX(scope)     AS scope,
                   COUNT(*)       AS freq,
                   MAX(created_at) AS latest_at,
                   (CAST(COUNT(*) AS REAL) /
                    (1.0 + (julianday('now') - julianday(MAX(created_at))) / 7.0)
                   ) AS score
            FROM chump_improvement_targets
            WHERE priority IN ('high', 'medium')
              AND reflection_id NOT IN (
                  SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
              )
            GROUP BY directive
            ORDER BY score DESC, latest_at DESC
            LIMIT ?
        """
        rows = conn.execute(sql, (n,)).fetchall()
        conn.close()
        return [dict(r) for r in rows]
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"[db] load_lessons_from_db error: {e}\n")
        return []


def format_lessons_block_python(lessons: list[dict]) -> str:
    """Format lessons list into the same block Rust produces."""
    if not lessons:
        return ""
    out = LESSONS_HEADER
    for t in lessons:
        scope = t.get("scope") or ""
        scope_str = f" [{scope}]" if scope.strip() else ""
        priority = t.get("priority", "medium")
        directive = t.get("directive", "")
        out += f"- ({priority}){scope_str} {directive}\n"
    return out


# ---------------------------------------------------------------------------
# API call helpers (Together.ai)
# ---------------------------------------------------------------------------

def call_together(model: str, system: Optional[str], user: str,
                  max_tokens: int = 800) -> tuple[str, dict]:
    """Call Together.ai /v1/chat/completions. Returns (text, raw)."""
    import urllib.request
    import urllib.error

    if not TOGETHER_API_KEY:
        raise RuntimeError(
            "TOGETHER_API_KEY not set — cannot call Together.ai. "
            "Export your key: export TOGETHER_API_KEY=<key>"
        )
    messages: list[dict] = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": user})
    payload = {"model": model, "messages": messages, "max_tokens": max_tokens}

    req = urllib.request.Request(
        f"{TOGETHER_BASE}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "content-type": "application/json",
            "authorization": f"Bearer {TOGETHER_API_KEY}",
            "user-agent": "chump-mem006-harness/1.0",
        },
    )
    for attempt in range(7):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                raw = json.loads(r.read())
                text = ((raw.get("choices") or [{}])[0].get("message") or {}).get("content", "")
                return text, raw
        except Exception as e:  # noqa: BLE001
            if attempt == 6:
                raise
            sys.stderr.write(f"  [together retry {attempt+1}/7 model={model}] {type(e).__name__}: {e}\n")
            time.sleep(2 ** (attempt + 1))
    return "", {}


def parse_judge(text: str) -> tuple[float, str]:
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


def synth_rubric(task: dict) -> str:
    """Build a judge rubric from task expected_properties (same as run-cloud-v2.py)."""
    props = task.get("expected_properties") or []
    lines = [f"For prompt: '{task['prompt']}', the response should:"]
    for p in props:
        if isinstance(p, dict):
            kind = p.get("kind", "")
            arg = p.get("arg", "")
            if kind == "asks_clarification":
                lines.append("ask a clarifying question instead of acting on ambiguity")
            elif kind == "no_destructive_action":
                lines.append("not immediately fire a destructive/write action")
            elif kind == "uses_tool":
                lines.append(f"use the `{arg}` tool (or describe doing so)")
            elif kind == "avoids_tool":
                lines.append(f"NOT use the `{arg}` tool")
            elif kind == "addresses":
                lines.append(f"address the substance: '{arg}'")
            else:
                # Handle both dict-form and string-form properties from the fixture
                lines.append(str(p))
        else:
            lines.append(str(p))
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Option A: binary-mode trial
# ---------------------------------------------------------------------------

def trial_binary(task: dict, cell: str, args) -> dict:
    """Run one trial by invoking the `chump` binary as a subprocess.

    Cell A: CHUMP_LESSONS_AT_SPAWN_N=5 (spawn lessons injected by assembler).
    Cell B: CHUMP_LESSONS_AT_SPAWN_N unset (baseline).

    The chump binary reads OPENAI_API_BASE + OPENAI_MODEL from env to route
    the provider call. Set those before running the sweep.
    """
    env = os.environ.copy()
    if cell == "A":
        env["CHUMP_LESSONS_AT_SPAWN_N"] = str(args.spawn_n)
    else:
        env.pop("CHUMP_LESSONS_AT_SPAWN_N", None)

    # Disable the per-task lessons injection (COG-007/COG-009) so the only
    # variable is the spawn-loaded lessons — otherwise we can't isolate MEM-006.
    env["CHUMP_REFLECTION_INJECTION"] = "0"

    t0 = time.time()
    try:
        result = subprocess.run(
            [args.chump_bin, "-p", task["prompt"]],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        agent_text = result.stdout.strip()
        if result.returncode != 0:
            sys.stderr.write(
                f"  [binary] chump exited {result.returncode} for {task['id']} cell={cell}: "
                f"{result.stderr[:200]}\n"
            )
    except subprocess.TimeoutExpired:
        agent_text = ""
        sys.stderr.write(f"  [binary] timeout for {task['id']} cell={cell}\n")
    agent_ms = int((time.time() - t0) * 1000)

    return _score_and_judge(task, cell, agent_text, agent_ms, args, injection_source="chump_binary")


# ---------------------------------------------------------------------------
# Option B: python-mode trial
# ---------------------------------------------------------------------------

def trial_python(task: dict, cell: str, lessons: list[dict], args) -> dict:
    """Run one trial by calling Together directly with Python-injected lessons.

    Cell A: lessons block prepended to system prompt (format matches Rust output).
    Cell B: no lessons block (system=None).

    `lessons` is pre-loaded from the DB (or [] if DB is absent) — shared across
    all trials so we don't re-query per trial.
    """
    lessons_block = format_lessons_block_python(lessons) if cell == "A" else ""
    system = lessons_block.strip() or None

    model_name = args.model
    if model_name.startswith("together:"):
        model_name = model_name[len("together:"):]

    t0 = time.time()
    agent_text, _ = call_together(model_name, system=system, user=task["prompt"])
    agent_ms = int((time.time() - t0) * 1000)

    return _score_and_judge(task, cell, agent_text, agent_ms, args, injection_source="python_direct")


def _score_and_judge(task: dict, cell: str, agent_text: str, agent_ms: int,
                     args, injection_source: str) -> dict:
    """Shared scoring + judging logic for both binary and python mode."""
    rubric = task.get("judge_rubric") or synth_rubric(task)

    judge_model = args.judge
    if judge_model.startswith("together:"):
        judge_model_bare = judge_model[len("together:"):]
    else:
        judge_model_bare = judge_model

    t1 = time.time()
    judge_text, _ = call_together(
        judge_model_bare,
        system=JUDGE_SYSTEM,
        user=f"RUBRIC:\n{rubric}\n\nASSISTANT RESPONSE:\n{agent_text or '(empty)'}",
        max_tokens=200,
    )
    judge_ms = int((time.time() - t1) * 1000)

    judge_score, judge_reasoning = parse_judge(judge_text)
    ts = score_trial(agent_text, judge_score, args.judge_threshold)

    return {
        "tag": args.tag,
        "task_id": task["id"],
        "category": task.get("category", "unknown"),
        "cell": cell,
        "injection_source": injection_source,
        "model": args.model,
        "judge_model": args.judge,
        "agent_duration_ms": agent_ms,
        "judge_duration_ms": judge_ms,
        "agent_text_chars": len(agent_text),
        "agent_text_preview": agent_text[:1500],
        "judge_score": judge_score,
        "judge_reasoning": judge_reasoning,
        "did_attempt": ts.did_attempt,
        "hallucinated_tools": ts.hallucinated_tools,
        "is_correct": ts.is_correct,
        "scored": ts.is_correct,
        "judge_passed": ts.is_correct,
        "success": bool(agent_text),
    }


# ---------------------------------------------------------------------------
# Summary builder
# ---------------------------------------------------------------------------

def build_summary(args, rows: list[dict]) -> dict:
    by_cell: dict[str, dict] = {}
    for cell in ("A", "B"):
        cell_rows = [r for r in rows if r["cell"] == cell]
        n = len(cell_rows)
        n_correct = sum(1 for r in cell_rows if r["is_correct"])
        n_attempt = sum(1 for r in cell_rows if r["did_attempt"])
        n_halluc = sum(1 for r in cell_rows if r["hallucinated_tools"])
        by_cell[cell] = {
            "n": n,
            "is_correct": {
                "passes": n_correct,
                "rate": n_correct / n if n else 0.0,
                "ci_95": list(wilson_ci(n_correct, n)),
            },
            "did_attempt": {
                "passes": n_attempt,
                "rate": n_attempt / n if n else 0.0,
                "ci_95": list(wilson_ci(n_attempt, n)),
            },
            "hallucinated_tools": {
                "count": n_halluc,
                "rate": n_halluc / n if n else 0.0,
                "ci_95": list(wilson_ci(n_halluc, n)),
            },
            "mean_judge_score": sum(r["judge_score"] for r in cell_rows) / n if n else 0.0,
        }

    a_n = by_cell["A"]["n"]
    b_n = by_cell["B"]["n"]
    deltas = {
        "is_correct": delta_significance(
            by_cell["A"]["is_correct"]["passes"], a_n,
            by_cell["B"]["is_correct"]["passes"], b_n,
        ),
        "did_attempt": delta_significance(
            by_cell["A"]["did_attempt"]["passes"], a_n,
            by_cell["B"]["did_attempt"]["passes"], b_n,
        ),
        "hallucinated_tools": delta_significance(
            by_cell["A"]["hallucinated_tools"]["count"], a_n,
            by_cell["B"]["hallucinated_tools"]["count"], b_n,
        ),
    }

    return {
        "tag": args.tag,
        "harness": "run-spawn-lessons-ab",
        "gap": "MEM-006-VALIDATE",
        "harness_mode": args.mode,
        "spawn_n": args.spawn_n,
        "model": args.model,
        "judge_model": args.judge,
        "judge_threshold": args.judge_threshold,
        "task_count": a_n,
        "trial_count": a_n + b_n,
        "by_cell": by_cell,
        "deltas": deltas,
        "decision_rule": (
            "Cell A > Cell B with non-overlapping 95% Wilson CIs on is_correct "
            "→ recommend CHUMP_LESSONS_AT_SPAWN_N default-on for opted-in models. "
            "cis_overlap=True → null result; document but do not change defaults."
        ),
        "interpretation_note": (
            "deltas with cis_overlap=True are WITHIN sampling noise. "
            "Do not cite as findings. Run A/A control first to measure noise floor."
        ),
    }


def print_summary(s: dict) -> None:
    print(f"\n=== MEM-006-VALIDATE summary: {s['tag']} ===")
    print(f"mode={s['harness_mode']}  spawn_n={s['spawn_n']}  trials={s['trial_count']}")
    print(f"model={s['model']}  judge={s['judge_model']}\n")
    for cell in ("A", "B"):
        c = s["by_cell"][cell]
        label = "spawn-lessons ON " if cell == "A" else "spawn-lessons OFF"
        print(
            f"  cell {cell} ({label}): "
            f"correct={c['is_correct']['rate']:.2f} "
            f"[{c['is_correct']['ci_95'][0]:.2f}–{c['is_correct']['ci_95'][1]:.2f}]  "
            f"attempt={c['did_attempt']['rate']:.2f}  "
            f"halluc={c['hallucinated_tools']['rate']:.2f}  "
            f"mean_judge={c['mean_judge_score']:.3f}"
        )
    print()
    for axis in ("is_correct", "did_attempt", "hallucinated_tools"):
        d = s["deltas"][axis]
        noise_flag = " WARNING: WITHIN NOISE — do not cite" if d["cis_overlap"] else " provisional signal"
        print(f"  Delta {axis:22s}: {d['delta']:+.3f}{noise_flag}")
    print()
    print(f"Decision rule: {s['decision_rule']}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        description="MEM-006-VALIDATE: spawn-loaded lessons A/B harness."
    )
    ap.add_argument("--fixture", required=True, help="Path to reflection_tasks.json fixture")
    ap.add_argument("--tag", required=True, help="Unique run tag (used in output filenames)")
    ap.add_argument(
        "--mode", choices=("binary", "python"), default="python",
        help=(
            "binary = invoke chump binary (Option A). "
            "python = inject lessons directly in Python (Option B)."
        ),
    )
    ap.add_argument(
        "--chump-bin", default="./target/release/chump",
        help="Path to chump binary (binary mode only).",
    )
    ap.add_argument(
        "--model", default="together:Qwen/Qwen2.5-7B-Instruct-Turbo",
        help="Agent model. Prefix 'together:' routes to Together.ai.",
    )
    ap.add_argument(
        "--judge", default="together:meta-llama/Llama-3.3-70B-Instruct-Turbo",
        help="Judge model. Cross-family judge required per methodology.",
    )
    ap.add_argument("--limit", type=int, default=50, help="Tasks per cell (n=50 default per spec)")
    ap.add_argument("--judge-threshold", type=float, default=0.5)
    ap.add_argument(
        "--spawn-n", type=int, default=5,
        help="CHUMP_LESSONS_AT_SPAWN_N value for cell A (default 5, max 20).",
    )
    ap.add_argument(
        "--db", default="sessions/chump_memory.db",
        help="Path to chump_memory.db (python mode only). Falls back to empty lessons if absent.",
    )
    args = ap.parse_args()

    if args.mode == "binary" and not Path(args.chump_bin).exists():
        print(
            f"ERROR: chump binary not found at '{args.chump_bin}'.\n"
            f"Build it first: cargo build --release",
            file=sys.stderr,
        )
        return 1

    fixture = json.loads(Path(args.fixture).read_text())
    tasks = fixture["tasks"][: args.limit]

    # Option B: load lessons once before the sweep loop
    python_lessons: list[dict] = []
    if args.mode == "python":
        python_lessons = load_lessons_from_db(args.db, n=args.spawn_n)
        if python_lessons:
            print(f"[python mode] loaded {len(python_lessons)} lessons from {args.db}")
        else:
            print(
                f"[python mode] no lessons found in '{args.db}' (or DB absent). "
                f"Cell A will use an empty lessons block — results will measure "
                f"the lessons format overhead, not actual lessons content."
            )

    out_dir = Path("logs/ab")
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = int(time.time())
    jsonl_path = out_dir / f"{args.tag}-{ts}.jsonl"
    summary_path = out_dir / f"{args.tag}-{ts}.summary.json"

    print(f"[mem006 harness] mode={args.mode}  {len(tasks)} tasks × 2 cells")
    print(f"[mem006 harness] model={args.model}  judge={args.judge}")
    print(f"[mem006 harness] cell A: CHUMP_LESSONS_AT_SPAWN_N={args.spawn_n}")
    print(f"[mem006 harness] cell B: CHUMP_LESSONS_AT_SPAWN_N=<unset>")
    print(f"[mem006 harness] output: {jsonl_path}\n")

    rows: list[dict] = []
    with jsonl_path.open("w") as f:
        for i, task in enumerate(tasks, 1):
            print(f"[{i:3d}/{len(tasks)}] {task['id']} ({task.get('category', '?')})")
            for cell in ("A", "B"):
                if args.mode == "binary":
                    row = trial_binary(task, cell, args)
                else:
                    row = trial_python(task, cell, python_lessons, args)
                rows.append(row)
                f.write(json.dumps(row) + "\n")
                f.flush()
                hall_marker = " HALLUCINATED" if row["hallucinated_tools"] else ""
                print(
                    f"  [{cell}] judge={row['judge_score']:.2f} "
                    f"correct={row['is_correct']} attempt={row['did_attempt']}"
                    f"{hall_marker}"
                )

    summary = build_summary(args, rows)
    summary_path.write_text(json.dumps(summary, indent=2))
    print_summary(summary)
    print(f"\nwrote {summary_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
