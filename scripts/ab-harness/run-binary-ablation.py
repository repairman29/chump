#!/usr/bin/env python3
"""
EVAL-049 — Binary-mode ablation harness.

Runs CHUMP_BYPASS_* env-var sweeps through the chump Rust binary so that
belief_state, surprisal EMA, and neuromodulation can be measured in real
binary execution (not via direct API calls).

Motivation: run-ablation-sweep.py and run-cloud-v2.py call the Anthropic API
directly — the chump binary is never invoked, so CHUMP_BYPASS_* flags have no
effect. This script fixes that by invoking `chump --chump "<task>"` in a
subprocess with the relevant env var set for Cell B (bypass active).

Usage:
    python3 scripts/ab-harness/run-binary-ablation.py \\
        --module all \\
        --n-per-cell 5 \\
        --dry-run

    python3 scripts/ab-harness/run-binary-ablation.py \\
        --module belief_state \\
        --n-per-cell 30 \\
        --binary ./target/release/chump

Stdlib only: subprocess, json, math, argparse, datetime, os, sys, time.
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
}


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

def score_trial(returncode: int, stdout: str) -> dict:
    """
    Correctness heuristic per EVAL-049 spec:
      - correct = exit code 0 AND output length > 10 chars
      - hallucination = output contains "I cannot" or "I don't know"
    Returns dict with keys: correct (bool), hallucination (bool).
    """
    correct = (returncode == 0) and (len(stdout.strip()) > 10)
    hallucination = any(
        phrase in stdout for phrase in ["I cannot", "I don't know", "I can't", "I do not know"]
    )
    return {"correct": correct, "hallucination": hallucination}


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
) -> dict:
    """
    Run one trial and return a result dict suitable for JSONL output.
    cell="A" → normal run (bypass flag NOT set)
    cell="B" → ablation run (CHUMP_BYPASS_<MODULE>=1)
    """
    bypass_var = MODULES[module]
    env = os.environ.copy()

    # Cell B: activate the bypass
    if cell == "B":
        env[bypass_var] = "1"
    else:
        # Ensure bypass is explicitly disabled in Cell A in case the parent
        # environment has it set.
        env.pop(bypass_var, None)
        env[bypass_var] = "0"

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
        env_prefix = f"{bypass_var}={'1' if cell == 'B' else '0'}"
        print(f"  [dry-run] {env_prefix} {' '.join(cmd)}")
        return {
            "ts": datetime.datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "module": module,
            "cell": cell,
            "task_id": task["id"],
            "category": task["category"],
            "bypass_var": bypass_var,
            "bypass_active": cell == "B",
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

    scores = score_trial(returncode, stdout)

    return {
        "ts": datetime.datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "module": module,
        "cell": cell,
        "task_id": task["id"],
        "category": task["category"],
        "bypass_var": bypass_var,
        "bypass_active": cell == "B",
        "correct": scores["correct"],
        "hallucination": scores["hallucination"],
        "exit_code": returncode,
        "output_chars": len(stdout.strip()),
        "duration_ms": duration_ms,
        "dry_run": False,
    }


# ---------------------------------------------------------------------------
# Summary table printer
# ---------------------------------------------------------------------------

def print_summary(results: list[dict]) -> None:
    """Print accuracy + Wilson 95% CI + delta per module."""
    modules_seen = sorted(set(r["module"] for r in results if not r.get("dry_run")))
    if not modules_seen:
        print("\n[summary] No live results to summarise (dry-run only).")
        return

    header = f"{'Module':<16} {'n(A)':<6} {'n(B)':<6} {'Acc A':<8} {'Acc B':<8} {'CI_A_lo':<9} {'CI_A_hi':<9} {'CI_B_lo':<9} {'CI_B_hi':<9} {'Delta':<8} {'Verdict'}"
    print("\n" + "=" * len(header))
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
    print("Note: Delta = Acc(B) - Acc(A). Negative delta means bypass *improves* accuracy.")
    print("      Full n=30+ run required for any publishable claim (per RESEARCH_INTEGRITY.md).")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="EVAL-049 binary-mode ablation harness — measures CHUMP_BYPASS_* impact via chump binary.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Dry-run — prints subprocess commands, no binary needed:
  python3 scripts/ab-harness/run-binary-ablation.py --dry-run

  # Quick smoke test (n=5):
  python3 scripts/ab-harness/run-binary-ablation.py --n-per-cell 5

  # Full publishable run (n=30):
  python3 scripts/ab-harness/run-binary-ablation.py --n-per-cell 30

  # Single module:
  python3 scripts/ab-harness/run-binary-ablation.py --module belief_state --n-per-cell 5

Output:
  logs/ab/eval049-binary-<ts>.jsonl   — one JSONL line per trial
  Summary table printed to stdout at completion
""",
    )
    p.add_argument(
        "--module",
        choices=["belief_state", "surprisal", "neuromod", "spawn_lessons", "blackboard", "all"],
        default="all",
        help="Which bypass module to sweep (default: all five)",
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
    out_path = os.path.join(out_dir, f"eval049-binary-{ts}.jsonl")

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
                )
                all_results.append(result)

                if not args.dry_run:
                    status = "OK" if result["correct"] else "FAIL"
                    hallu = " [halluc]" if result["hallucination"] else ""
                    print(
                        f"    [{i+1}/{n}] {task['id']} {status}{hallu} "
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
    print_summary(all_results)

    if args.dry_run:
        print(
            "\n[eval-049] Dry-run complete. To run for real:\n"
            "  cargo build --release --bin chump\n"
            f"  python3 scripts/ab-harness/run-binary-ablation.py --n-per-cell 30"
        )
    else:
        print(
            f"\n[eval-049] Done. Full results: {out_path}\n"
            "  Note: n=30+ per cell required for publishable claims (RESEARCH_INTEGRITY.md).\n"
            f"  Re-run with --n-per-cell 30 for a full sweep."
        )


if __name__ == "__main__":
    main()
