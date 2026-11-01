#!/usr/bin/env python3.12
"""cross-agent-adapter.py — AgentRunner interface + per-agent adapters.

Provides a uniform interface so Chump's run-cloud-v2.py scoring stack can
evaluate any agent on the same task fixtures.  Each runner:

  1. Accepts a task prompt and an optional system prompt.
  2. Returns the agent's raw text response (str).
  3. Falls back to ``NOT_INSTALLED:<runner>`` if the CLI is not present.

The ``NOT_INSTALLED`` sentinel is safe to pass through scoring_v2 — it
scores as did_attempt=False, hallucinated_tools=False, is_correct=False,
which is the correct signal for "agent not available on this machine."

Usage (standalone harness):
    python3.12 scripts/ab-harness/cross-agent-adapter.py \\
        --fixture scripts/ab-harness/fixtures/reflection_tasks.json \\
        --agents chump goose aider claude-code \\
        --model claude-haiku-4-5 \\
        --judge claude-sonnet-4-5 \\
        --limit 50 \\
        --tag cross-agent-2026Q3

Usage (from cross-agent-runner.py):
    from cross_agent_adapter import build_runner

See docs/CROSS_AGENT_BENCHMARK_2026Q3.md for full methodology.
"""
from __future__ import annotations

import abc
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Optional

# Add scoring_v2 to path
sys.path.insert(0, str(Path(__file__).parent))
from scoring_v2 import score_trial, delta_significance, wilson_ci  # noqa: E402

# Lazy import — available only when cross-agent-adapter runs as harness driver.
# The adapter module itself is importable without run-cloud-v2's heavyweight deps.
try:
    from run_cloud_v2 import (  # type: ignore[import]
        call_anthropic,
        call_ollama,
        call_together,
        call_judge,
        parse_judge,
        synth_rubric,
        load_env,
        JUDGE_SYSTEM,
    )
    _HARNESS_AVAILABLE = True
except ImportError:
    _HARNESS_AVAILABLE = False


# ---------------------------------------------------------------------------
# Hallucination-stripping helper
# ---------------------------------------------------------------------------

# Tags that look like tool-execution markup when present in agent stdout.
# We strip them so the harness doesn't double-penalise a model for markup that
# was present in a shell-wrapper's stdout rather than a true hallucination.
_STRIP_PREFIXES = (
    "<function_calls>",
    "</function_calls>",
    "<tool_call>",
    "</tool_call>",
    "<tool_use>",
    "</tool_use>",
    "<invoke ",
    "</invoke>",
)


def strip_tool_markup(text: str) -> str:
    """Remove tool-call XML from CLI-agent stdout.

    Some agents (goose, Aider) emit progress/status lines that include XML
    from their own tool-use — those lines are execution traces, not the final
    answer.  Strip them so scoring_v2 measures the *answer* quality, not the
    trace verbosity.

    Strategy: remove lines that start with a known tool-markup prefix.  This
    is intentionally conservative — we only drop lines that *open* a tag, not
    paragraphs that reference a tag name in prose.
    """
    clean_lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if any(stripped.startswith(p) for p in _STRIP_PREFIXES):
            continue
        clean_lines.append(line)
    return "\n".join(clean_lines)


# ---------------------------------------------------------------------------
# Abstract base
# ---------------------------------------------------------------------------

class AgentRunner(abc.ABC):
    """Abstract interface for a single agent backend.

    Subclasses implement ``run_task``.  The harness driver calls ``run_task``
    for every (task, cell) pair and passes the result to ``scoring_v2``.
    """

    @property
    @abc.abstractmethod
    def name(self) -> str:
        """Short human-readable name, e.g. 'chump', 'goose', 'aider'."""

    @abc.abstractmethod
    def run_task(self, prompt: str, system: Optional[str] = None) -> str:
        """Run the agent on *prompt* (with optional *system* context).

        Returns the agent's text response.  Returns
        ``NOT_INSTALLED:<name>`` if the CLI is not available.
        """

    def is_available(self) -> bool:
        """Return True if this runner can actually execute tasks."""
        result = self.run_task("ping", system=None)
        return not result.startswith("NOT_INSTALLED:")


# ---------------------------------------------------------------------------
# Chump runner — calls the provider directly, same as run-cloud-v2.py
# ---------------------------------------------------------------------------

class ChumpRunner(AgentRunner):
    """Calls the LLM provider directly (Anthropic / Together / Ollama).

    This is the reference implementation — identical to how run-cloud-v2.py
    calls the model.  The system prompt is the lessons block when lessons are
    enabled (cell A) or None (cell B).

    Args:
        model: Full model spec, e.g. ``claude-haiku-4-5``,
               ``together:meta-llama/Llama-3.3-70B-Instruct-Turbo``,
               or ``ollama:qwen2.5:7b``.
        api_key: Anthropic API key.  Ignored for together/ollama models.
    """

    def __init__(self, model: str, api_key: str = "") -> None:
        self._model = model
        self._api_key = api_key

    @property
    def name(self) -> str:
        return "chump"

    def run_task(self, prompt: str, system: Optional[str] = None) -> str:
        if not _HARNESS_AVAILABLE:
            return "NOT_INSTALLED:chump-harness-deps"
        try:
            if self._model.startswith("together:"):
                text, _ = call_together(
                    self._model[len("together:"):],
                    system=system,
                    user=prompt,
                    ledger_purpose="cross-agent:chump",
                )
            elif self._model.startswith("ollama:"):
                text, _ = call_ollama(
                    self._model[len("ollama:"):],
                    system=system,
                    user=prompt,
                    ledger_purpose="cross-agent:chump",
                )
            else:
                text, _ = call_anthropic(
                    self._api_key,
                    self._model,
                    system=system,
                    user=prompt,
                    ledger_purpose="cross-agent:chump",
                )
            return text
        except Exception as exc:  # noqa: BLE001
            return f"ERROR:chump:{exc}"


# ---------------------------------------------------------------------------
# Goose runner — shells out to `goose run --text <prompt>`
# ---------------------------------------------------------------------------

class GooseRunner(AgentRunner):
    """Runs Block's goose agent CLI.

    Invocation:
        goose run --text "<prompt>"

    Notes:
    - goose does not accept a ``--system`` flag directly; this runner
      prepends the system prompt to the user prompt as a role-prefixed block
      when system is non-empty.
    - Goose may emit ANSI colour codes and spinner lines on stderr; we capture
      stdout only.
    - ``--no-session`` prevents goose from persisting session history across
      runs, which would bleed context between tasks.
    - Timeout: 120 s per task (same as the Anthropic call timeout).

    Installation:
        pip install goose-ai          # or: brew install block-goose
        goose configure               # set provider + model
    """

    CLI = "goose"

    @property
    def name(self) -> str:
        return "goose"

    def _cli_available(self) -> bool:
        return shutil.which(self.CLI) is not None

    def run_task(self, prompt: str, system: Optional[str] = None) -> str:
        if not self._cli_available():
            return f"NOT_INSTALLED:{self.name}"

        full_prompt = prompt
        if system:
            full_prompt = f"[System context]\n{system}\n\n[Task]\n{prompt}"

        cmd = [self.CLI, "run", "--text", full_prompt]
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=120,
            )
            output = result.stdout.strip()
            return strip_tool_markup(output) if output else result.stderr.strip()
        except subprocess.TimeoutExpired:
            return "TIMEOUT:goose"
        except FileNotFoundError:
            return f"NOT_INSTALLED:{self.name}"
        except Exception as exc:  # noqa: BLE001
            return f"ERROR:goose:{exc}"


# ---------------------------------------------------------------------------
# Aider runner — shells out to `aider --message <prompt> --no-git`
# ---------------------------------------------------------------------------

class AiderRunner(AgentRunner):
    """Runs Paul Gauthier's Aider code-editor agent.

    Invocation (non-interactive, read-only, no git ops):
        aider --message "<prompt>" --no-git --no-auto-commits --yes-always

    Notes:
    - ``--no-git`` prevents aider from committing or dirtying the repo.
    - ``--yes-always`` suppresses interactive confirmation prompts.
    - ``--model <model>`` is passed through if set on this runner.
    - We run aider in a temp working directory pointing at the repo root so
      it can read files, but ``--no-git`` + ``--no-auto-commits`` prevents
      writes.
    - Aider outputs its conversation to stdout; the last assistant turn is
      what we extract.  We look for the final "assistant>" block.
    - Timeout: 120 s per task.

    Installation:
        pip install aider-chat
        aider --version
    """

    CLI = "aider"

    def __init__(self, model: Optional[str] = None) -> None:
        self._model = model  # e.g. "claude-haiku-4-5" — passed as --model

    @property
    def name(self) -> str:
        return "aider"

    def _cli_available(self) -> bool:
        return shutil.which(self.CLI) is not None

    def run_task(self, prompt: str, system: Optional[str] = None) -> str:
        if not self._cli_available():
            return f"NOT_INSTALLED:{self.name}"

        full_prompt = prompt
        if system:
            full_prompt = f"{system}\n\n{prompt}"

        cmd = [
            self.CLI,
            "--message", full_prompt,
            "--no-git",
            "--no-auto-commits",
            "--yes-always",
        ]
        if self._model:
            cmd += ["--model", self._model]

        # Run in a temp dir to avoid dirtying the working tree.
        with tempfile.TemporaryDirectory() as tmpdir:
            try:
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=120,
                    cwd=tmpdir,
                )
                raw = result.stdout.strip()
                # Aider prefixes its output with "aider>" and "assistant>" markers.
                # Extract the last assistant block.
                last_block = _extract_last_aider_block(raw)
                return strip_tool_markup(last_block) if last_block else raw
            except subprocess.TimeoutExpired:
                return "TIMEOUT:aider"
            except FileNotFoundError:
                return f"NOT_INSTALLED:{self.name}"
            except Exception as exc:  # noqa: BLE001
                return f"ERROR:aider:{exc}"


def _extract_last_aider_block(text: str) -> str:
    """Extract the last assistant response from aider's stdout."""
    # Aider outputs lines like "assistant> <text>" or just the response text.
    # Look for lines after the last "aider>" prompt marker.
    lines = text.splitlines()
    # Find the last occurrence of a line starting with "aider>" or an arrow marker.
    last_marker = -1
    for i, line in enumerate(lines):
        if line.strip().startswith("aider>") or line.strip().startswith(">"):
            last_marker = i
    if last_marker == -1:
        return text
    response_lines = lines[last_marker + 1:]
    # Strip any trailing prompt artifacts.
    return "\n".join(
        line for line in response_lines
        if not line.strip().startswith("aider>")
    ).strip()


# ---------------------------------------------------------------------------
# Claude Code runner — shells out to `claude -p <prompt>`
# ---------------------------------------------------------------------------

class ClaudeCodeRunner(AgentRunner):
    """Runs Anthropic's Claude Code CLI.

    Invocation:
        claude -p "<prompt>"

    Notes:
    - ``-p`` is the print/non-interactive mode added in Claude Code v1.
    - ``--dangerously-skip-permissions`` is NOT used here — the runner should
      only measure the model's *reasoning*, not filesystem writes.
    - System prompt is prepended to the user prompt as a context block because
      ``claude -p`` does not expose a ``--system`` flag.
    - If Claude Code is not installed, returns ``NOT_INSTALLED:claude-code``.
    - Timeout: 120 s per task.

    Installation:
        npm install -g @anthropic-ai/claude-code
        claude --version
    """

    CLI = "claude"

    @property
    def name(self) -> str:
        return "claude-code"

    def _cli_available(self) -> bool:
        return shutil.which(self.CLI) is not None

    def run_task(self, prompt: str, system: Optional[str] = None) -> str:
        if not self._cli_available():
            return f"NOT_INSTALLED:{self.name}"

        full_prompt = prompt
        if system:
            full_prompt = f"[Context]\n{system}\n\n[Task]\n{prompt}"

        cmd = [self.CLI, "-p", full_prompt]
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=120,
            )
            output = result.stdout.strip()
            return strip_tool_markup(output) if output else result.stderr.strip()
        except subprocess.TimeoutExpired:
            return "TIMEOUT:claude-code"
        except FileNotFoundError:
            return f"NOT_INSTALLED:{self.name}"
        except Exception as exc:  # noqa: BLE001
            return f"ERROR:claude-code:{exc}"


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

AGENT_REGISTRY: dict[str, type[AgentRunner]] = {
    "chump": ChumpRunner,
    "goose": GooseRunner,
    "aider": AiderRunner,
    "claude-code": ClaudeCodeRunner,
}


def build_runner(
    agent: str,
    model: str = "claude-haiku-4-5",
    api_key: str = "",
) -> AgentRunner:
    """Instantiate the correct runner for *agent*.

    Args:
        agent: One of ``chump``, ``goose``, ``aider``, ``claude-code``.
        model: Model spec for runners that accept one (``chump``, ``aider``).
        api_key: Anthropic API key (for ``chump`` with bare model names).

    Raises:
        ValueError: If *agent* is not in AGENT_REGISTRY.
    """
    if agent not in AGENT_REGISTRY:
        raise ValueError(
            f"Unknown agent '{agent}'. Valid choices: {sorted(AGENT_REGISTRY)}"
        )
    cls = AGENT_REGISTRY[agent]
    if agent == "chump":
        return cls(model=model, api_key=api_key)  # type: ignore[call-arg]
    if agent == "aider":
        return cls(model=model)  # type: ignore[call-arg]
    return cls()  # type: ignore[call-arg]


# ---------------------------------------------------------------------------
# Standalone harness driver
# ---------------------------------------------------------------------------

def _load_env() -> str:
    if _HARNESS_AVAILABLE:
        return load_env()
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not key:
        raise RuntimeError("ANTHROPIC_API_KEY not set")
    return key


def main() -> int:  # noqa: PLR0912, PLR0915
    ap = argparse.ArgumentParser(
        description="Cross-agent benchmark harness — runs Chump fixtures against multiple agents.",
    )
    ap.add_argument(
        "--fixture", required=True,
        help="Path to a fixture JSON (e.g. scripts/ab-harness/fixtures/reflection_tasks.json)",
    )
    ap.add_argument(
        "--agents", nargs="+",
        default=["chump", "goose", "aider", "claude-code"],
        help="Agents to benchmark.  Choices: chump goose aider claude-code",
    )
    ap.add_argument("--model", default="claude-haiku-4-5", help="Model for chump/aider runners")
    ap.add_argument("--judge", default="claude-sonnet-4-5", help="Judge model")
    ap.add_argument("--limit", type=int, default=50, help="Max tasks per fixture")
    ap.add_argument("--judge-threshold", type=float, default=0.5)
    ap.add_argument("--tag", default="cross-agent", help="Run tag (used in output filename)")
    ap.add_argument(
        "--lessons", default=None,
        help="System prompt / lessons block to inject.  Use 'cog016' for Chump's COG-016 block, "
             "or a file path, or empty for no injection.",
    )
    args = ap.parse_args()

    try:
        api_key = _load_env()
    except RuntimeError as e:
        sys.stderr.write(f"[cross-agent] {e}\n")
        return 1

    if not _HARNESS_AVAILABLE:
        sys.stderr.write(
            "[cross-agent] WARNING: run_cloud_v2 not importable — "
            "ChumpRunner will return NOT_INSTALLED:chump-harness-deps\n"
        )

    # Resolve system / lessons block
    system_prompt: Optional[str] = None
    if args.lessons == "cog016":
        # Import the production lessons block from run-cloud-v2.
        if _HARNESS_AVAILABLE:
            from run_cloud_v2 import LESSONS_BLOCK_COG016  # type: ignore[import]
            system_prompt = LESSONS_BLOCK_COG016
        else:
            sys.stderr.write("[cross-agent] WARNING: cog016 requested but run_cloud_v2 not importable\n")
    elif args.lessons and Path(args.lessons).is_file():
        system_prompt = Path(args.lessons).read_text()
    elif args.lessons and args.lessons not in ("", "none"):
        system_prompt = args.lessons  # treat as literal string

    fixture = json.loads(Path(args.fixture).read_text())
    tasks = fixture["tasks"][: args.limit]

    judges = [j.strip() for j in args.judge.split(",") if j.strip()]

    # Build runners
    runners: list[AgentRunner] = []
    for agent_name in args.agents:
        try:
            runner = build_runner(agent_name, model=args.model, api_key=api_key)
            runners.append(runner)
        except ValueError as e:
            sys.stderr.write(f"[cross-agent] {e}\n")
            return 1

    out_dir = Path("logs/cross-agent")
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = int(time.time())
    jsonl_path = out_dir / f"{args.tag}-{ts}.jsonl"
    summary_path = out_dir / f"{args.tag}-{ts}.summary.json"

    print(f"[cross-agent] {len(tasks)} tasks × {len(runners)} agents")
    print(f"[cross-agent] agents: {[r.name for r in runners]}")
    print(f"[cross-agent] judge:  {judges}  threshold: {args.judge_threshold}")
    print(f"[cross-agent] output: {jsonl_path}\n")

    rows: list[dict] = []

    with jsonl_path.open("w") as f:
        for i, task in enumerate(tasks, 1):
            print(f"[{i:3d}/{len(tasks)}] {task['id']} ({task.get('category', '?')})")
            for runner in runners:
                t0 = time.time()
                agent_text = runner.run_task(task["prompt"], system=system_prompt)
                agent_ms = int((time.time() - t0) * 1000)

                is_not_installed = agent_text.startswith("NOT_INSTALLED:")

                # Judge the response (skip judging NOT_INSTALLED sentinels)
                judge_score = 0.0
                judge_reasoning = ""
                if not is_not_installed and _HARNESS_AVAILABLE:
                    rubric = task.get("judge_rubric") or synth_rubric(task)
                    per_judge_scores: dict[str, float] = {}
                    for judge_model in judges:
                        judge_text, _ = call_judge(
                            api_key,
                            judge_model,
                            system=JUDGE_SYSTEM,
                            user=(
                                f"RUBRIC:\n{rubric}\n\n"
                                f"ASSISTANT RESPONSE:\n{agent_text or '(empty)'}"
                            ),
                            max_tokens=200,
                            ledger_purpose=f"cross-agent-judge:{args.tag}",
                        )
                        jscore, jreasoning = parse_judge(judge_text)
                        per_judge_scores[judge_model] = jscore
                        judge_reasoning = jreasoning
                    scores_sorted = sorted(per_judge_scores.values())
                    n = len(scores_sorted)
                    judge_score = (
                        scores_sorted[n // 2] if n % 2 == 1
                        else (scores_sorted[n // 2 - 1] + scores_sorted[n // 2]) / 2
                    )

                ts_ = score_trial(agent_text, judge_score, args.judge_threshold)
                row = {
                    "tag": args.tag,
                    "task_id": task["id"],
                    "category": task.get("category", "unknown"),
                    "agent": runner.name,
                    "model": args.model,
                    "judge_model": ",".join(judges),
                    "agent_duration_ms": agent_ms,
                    "agent_text_chars": len(agent_text),
                    "agent_text_preview": agent_text[:1500],
                    "judge_score": judge_score,
                    "judge_reasoning": judge_reasoning,
                    "did_attempt": ts_.did_attempt,
                    "hallucinated_tools": ts_.hallucinated_tools,
                    "is_correct": ts_.is_correct,
                    "not_installed": is_not_installed,
                }
                rows.append(row)
                f.write(json.dumps(row) + "\n")
                f.flush()

                status = "NOT_INSTALLED" if is_not_installed else (
                    f"judge={judge_score:.2f} correct={ts_.is_correct} "
                    f"halluc={ts_.hallucinated_tools}"
                )
                print(f"  [{runner.name:12s}] {status}")

    # Build per-agent summary
    summary = _build_cross_agent_summary(args, rows, judges)
    summary_path.write_text(json.dumps(summary, indent=2))
    _print_cross_agent_summary(summary)
    print(f"\nwrote {summary_path}")
    return 0


def _build_cross_agent_summary(args, rows: list[dict], judges: list[str]) -> dict:
    agent_names = sorted({r["agent"] for r in rows})
    by_agent: dict[str, dict] = {}
    for agent in agent_names:
        agent_rows = [r for r in rows if r["agent"] == agent]
        n = len(agent_rows)
        installed_rows = [r for r in agent_rows if not r.get("not_installed")]
        ni = len(installed_rows)
        n_correct = sum(1 for r in installed_rows if r["is_correct"])
        n_attempt = sum(1 for r in installed_rows if r["did_attempt"])
        n_halluc = sum(1 for r in installed_rows if r["hallucinated_tools"])
        by_agent[agent] = {
            "n_total": n,
            "n_installed": ni,
            "is_correct": {
                "passes": n_correct,
                "rate": n_correct / ni if ni else 0.0,
                "ci_95": list(wilson_ci(n_correct, ni)),
            },
            "did_attempt": {
                "passes": n_attempt,
                "rate": n_attempt / ni if ni else 0.0,
                "ci_95": list(wilson_ci(n_attempt, ni)),
            },
            "hallucinated_tools": {
                "count": n_halluc,
                "rate": n_halluc / ni if ni else 0.0,
                "ci_95": list(wilson_ci(n_halluc, ni)),
            },
            "mean_judge_score": (
                sum(r["judge_score"] for r in installed_rows) / ni if ni else 0.0
            ),
        }

    # Pairwise Chump-vs-X deltas
    pairwise: dict[str, dict] = {}
    if "chump" in by_agent:
        chump_rows = [r for r in rows if r["agent"] == "chump" and not r.get("not_installed")]
        cn = len(chump_rows)
        for other in agent_names:
            if other == "chump":
                continue
            other_rows = [r for r in rows if r["agent"] == other and not r.get("not_installed")]
            on = len(other_rows)
            pairwise[f"chump_vs_{other}"] = {
                "is_correct": delta_significance(
                    sum(1 for r in chump_rows if r["is_correct"]), cn,
                    sum(1 for r in other_rows if r["is_correct"]), on,
                ),
                "hallucinated_tools": delta_significance(
                    sum(1 for r in chump_rows if r["hallucinated_tools"]), cn,
                    sum(1 for r in other_rows if r["hallucinated_tools"]), on,
                ),
            }

    return {
        "tag": args.tag,
        "fixture": args.fixture,
        "harness_version": "cross-agent-1",
        "model": args.model,
        "judge_model": ",".join(judges),
        "judge_threshold": args.judge_threshold,
        "lessons": args.lessons,
        "agents": agent_names,
        "by_agent": by_agent,
        "pairwise_chump_vs": pairwise,
        "interpretation_note": (
            "Pairwise deltas with cis_overlap=True are within sampling noise. "
            "Do not cite as findings. Run A/A baselines per agent before citing results. "
            "All results are PRELIMINARY until n>=50 per cell with non-Anthropic judge validation."
        ),
    }


def _print_cross_agent_summary(s: dict) -> None:
    print(f"\n=== Cross-Agent Summary: {s['tag']} ===")
    print(f"fixture: {s['fixture']}  model: {s['model']}  judge: {s['judge_model']}")
    print()
    header = f"{'Agent':14s}  {'n':>4s}  {'correct':>8s}  {'attempt':>8s}  {'halluc':>8s}  {'judge':>6s}"
    print(header)
    print("-" * len(header))
    for agent, c in s["by_agent"].items():
        ni = c["n_installed"]
        if ni == 0:
            print(f"  {agent:12s}  {'n/a':>4s}  (not installed)")
            continue
        lo, hi = c["is_correct"]["ci_95"]
        print(
            f"  {agent:12s}  {ni:4d}  "
            f"{c['is_correct']['rate']:.2f} [{lo:.2f}-{hi:.2f}]  "
            f"{c['did_attempt']['rate']:.2f}        "
            f"{c['hallucinated_tools']['rate']:.2f}     "
            f"{c['mean_judge_score']:.3f}"
        )
    if s.get("pairwise_chump_vs"):
        print()
        print("Pairwise deltas (Chump vs X, is_correct):")
        for key, val in s["pairwise_chump_vs"].items():
            d = val["is_correct"]
            marker = " [within noise]" if d["cis_overlap"] else " [provisional signal]"
            print(f"  {key}: Δ={d['delta']:+.3f}{marker}")


if __name__ == "__main__":
    sys.exit(main())
