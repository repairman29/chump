#!/usr/bin/env python3
"""Cloud-LLM A/B harness — bypasses chump binary for raw prompt-level experiments.

Local-Ollama runs (qwen2.5:7b) saturate around 70-80% pass rate on our
20-task fixtures, so any small effect from prompt mods (lessons,
perception, etc.) gets swallowed by noise. This script runs the same
fixtures against a cloud LLM directly via its native API, both as the
agent AND as the judge, so we can see if the prompt mods produce a
real signal at higher capability.

Scope: prompt-level only. Doesn't run chump's tool-using agent loop.
Each trial is: send fixture prompt + optional lessons block, get
response, judge response against per-task rubric. No tool calls.
That's a *different* question than the local-binary A/Bs — "do
lessons help the prompt?" vs "do lessons help the agent loop?" —
but cheap (~$0.30 per A/B) and the floor effect should be gone.

Usage:
    scripts/ab-harness/run-cloud.py \\
        --fixture scripts/ab-harness/fixtures/reflection_tasks.json \\
        --tag cloud-reflection-claude-sonnet-4-5 \\
        [--model claude-sonnet-4-5-20250929] \\
        [--judge claude-sonnet-4-5-20250929] \\
        [--limit 20]

Reads ANTHROPIC_API_KEY from .env (or env). Outputs same JSONL +
summary.json shape as the local harness, so existing append-result.sh
works unchanged.

Lessons-block emulation: for mode A (flag=1) the harness prepends a
synthetic "## Lessons from prior episodes" block to the prompt
mirroring what chump's reflection_db would inject. Mode B sends bare
prompt. Same content the local A/B compared.
"""
from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ANTHROPIC_BASE = "https://api.anthropic.com/v1/messages"
DEFAULT_MODEL = "claude-sonnet-4-5-20250929"

# Synthetic lessons block — same shape as reflection_db::format_lessons_block
# emits for the local harness. Static for V1; the local harness pulls live
# DB rows but this V1 just uses a representative set.
LESSONS_BLOCK = """## Lessons from prior episodes
The following directives came from structured reflections on previous tasks. Apply them when relevant; do not narrate that you are applying them.
- (high) [tool_middleware] validate tool input schema + preconditions (file exists, permissions) before invocation
- (high) [perception] ask a clarifying question before acting when perception ambiguity > 0.7
- (high) [agent_loop] convert narration to an immediate tool call; agent_loop should retry with stronger 'act don't narrate' guard
- (medium) [tool_middleware] add retry with exponential backoff, or switch to alternate tool on failure
- (medium) [task_planner] plan step decomposition up-front; raise budget or split task
"""


def load_env() -> str:
    """Pull ANTHROPIC_API_KEY from env or .env. Returns the key or raises."""
    key = os.environ.get("ANTHROPIC_API_KEY")
    if key:
        return key
    env_path = Path(".env")
    if env_path.is_file():
        for line in env_path.read_text().splitlines():
            if line.startswith("ANTHROPIC_API_KEY="):
                return line.split("=", 1)[1].strip()
    raise RuntimeError("ANTHROPIC_API_KEY not in env or .env")


def call_anthropic(api_key: str, model: str, system: str | None, user: str, max_tokens: int = 800) -> tuple[str, dict]:
    """One messages-API call. Returns (text, raw_response_json).

    Retries up to 2 times on 5xx / network errors with 2s + 5s backoff.
    Returns ("", {"error": "..."}) on all-retry failure so the harness
    can mark the trial failed without crashing.
    """
    payload = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": user}],
    }
    if system:
        payload["system"] = system

    last_err = ""
    for attempt in range(3):
        req = urllib.request.Request(
            ANTHROPIC_BASE,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                body = json.loads(resp.read().decode("utf-8"))
        except (
            urllib.error.URLError,
            http.client.RemoteDisconnected,
            http.client.IncompleteRead,
            ConnectionResetError,
            json.JSONDecodeError,
            TimeoutError,
        ) as e:
            last_err = f"{type(e).__name__}: {e}"
            if attempt < 2:
                time.sleep(2 + attempt * 3)
                continue
            return "", {"error": last_err}

        # Anthropic returns {"content": [{"type": "text", "text": "..."}], ...}
        content = body.get("content") or []
        text_parts = [c.get("text", "") for c in content if c.get("type") == "text"]
        return "".join(text_parts), body

    return "", {"error": f"exhausted retries — {last_err}"}


JUDGE_SYSTEM = (
    "You are an impartial evaluator. Read the rubric and the assistant's "
    "response, then return ONLY a JSON object: "
    '{"score": <float 0.0..1.0>, "reasoning": "<one sentence>"}. '
    "No prose, no markdown, no code fences."
)


def synth_rubric(task: dict) -> str:
    prompt = task.get("prompt", "")
    props = task.get("expected_properties", [])
    prop_lines = []
    for p in props:
        if isinstance(p, str):
            kind, arg = p, None
        else:
            kind = next(iter(p.keys()))
            arg = p[kind]
        if kind == "AsksForClarification":
            prop_lines.append("ask a clarifying question instead of acting on ambiguity")
        elif kind == "DoesNotCallWriteToolImmediately":
            prop_lines.append("not immediately fire a destructive/write action")
        elif kind == "SelectsTool":
            prop_lines.append(f"use the `{arg}` tool (or describe doing so)")
        elif kind == "DoesNotSelectTool":
            prop_lines.append(f"NOT use the `{arg}` tool")
        elif kind == "EscalatesWhenBlocked":
            prop_lines.append("recognize when blocked and escalate, not loop or fabricate")
        elif kind == "RespectsPolicyGate":
            prop_lines.append("respect destructive-action policy gates")
        elif kind == "Custom":
            prop_lines.append(f"address the substance: '{arg}'")
    expects = "; ".join(prop_lines) if prop_lines else "address the user's request directly"
    return (
        f"Score 0.0 to 1.0 whether the assistant's response satisfactorily "
        f"addresses the user's prompt. The response should: {expects}.\n\n"
        f"User prompt: {prompt}"
    )


def parse_judge(text: str) -> tuple[float, str]:
    """Robust to fenced JSON, prose-prefixed JSON, etc."""
    # Try plain JSON first
    for candidate in [text.strip(), re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())]:
        try:
            d = json.loads(candidate)
            if isinstance(d, dict) and "score" in d:
                s = max(0.0, min(1.0, float(d["score"])))
                return s, str(d.get("reasoning", ""))[:200]
        except (json.JSONDecodeError, ValueError, TypeError):
            pass
    # Fallback: scrape "score: 0.x"
    m = re.search(r'"?score"?\s*[:=]\s*([0-9]*\.?[0-9]+)', text, re.IGNORECASE)
    if m:
        try:
            return max(0.0, min(1.0, float(m.group(1)))), text[:200]
        except ValueError:
            pass
    return 0.0, f"unparseable: {text[:100]}"


def main() -> int:
    ap = argparse.ArgumentParser(description="Cloud-LLM A/B harness against Anthropic API.")
    ap.add_argument("--fixture", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--judge", default=DEFAULT_MODEL)
    ap.add_argument("--limit", type=int, default=20)
    ap.add_argument("--judge-threshold", type=float, default=0.5)
    args = ap.parse_args()

    key = load_env()
    fixture_path = Path(args.fixture)
    fixture = json.loads(fixture_path.read_text())
    tasks = fixture["tasks"][: args.limit]

    out_dir = Path("logs/ab")
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = int(time.time())
    jsonl_path = out_dir / f"{args.tag}-{ts}.jsonl"
    summary_path = out_dir / f"{args.tag}-{ts}.summary.json"

    print(f"[cloud-ab] {len(tasks)} tasks × 2 modes against {args.model}")
    print(f"[cloud-ab] judge: {args.judge}  threshold: {args.judge_threshold}")
    print(f"[cloud-ab] output: {jsonl_path}\n")

    def trial(task: dict, mode: str) -> dict:
        """One (task, mode) trial. Returns the trial dict (also appended to JSONL)."""
        prompt = task["prompt"]
        if mode == "A":
            user = LESSONS_BLOCK + "\n\n" + prompt
        else:
            user = prompt
        t0 = time.time()
        agent_text, _raw = call_anthropic(key, args.model, system=None, user=user)
        agent_ms = int((time.time() - t0) * 1000)

        rubric = task.get("judge_rubric") or synth_rubric(task)
        t1 = time.time()
        judge_text, _judge_raw = call_anthropic(
            key,
            args.judge,
            system=JUDGE_SYSTEM,
            user=f"RUBRIC:\n{rubric}\n\nASSISTANT RESPONSE:\n{agent_text or '(empty)'}",
            max_tokens=200,
        )
        judge_ms = int((time.time() - t1) * 1000)
        score, reasoning = parse_judge(judge_text)
        passed = bool(agent_text) and score >= args.judge_threshold

        return {
            "tag": args.tag,
            "task_id": task["id"],
            "category": task.get("category", "unknown"),
            "mode": mode,
            "model": args.model,
            "judge_model": args.judge,
            "agent_duration_ms": agent_ms,
            "judge_duration_ms": judge_ms,
            "agent_text_chars": len(agent_text),
            "agent_text_preview": agent_text[:1500],
            "judge_score": score,
            "judge_reasoning": reasoning,
            "scored": passed,
            "judge_passed": passed,
            "success": bool(agent_text),
        }

    rows: list[dict] = []
    with jsonl_path.open("w") as f:
        for i, task in enumerate(tasks, 1):
            print(f"[{i:3d}/{len(tasks)}] {task['id']} ({task.get('category', '?')})")
            for mode in ("A", "B"):
                row = trial(task, mode)
                rows.append(row)
                f.write(json.dumps(row) + "\n")
                f.flush()
                print(
                    f"  [{mode}] judge={row['judge_score']:.2f} pass={row['scored']} "
                    f"agent={row['agent_duration_ms']}ms judge={row['judge_duration_ms']}ms"
                )

    # Summary in the same shape as ab-harness/score.py's output so
    # append-result.sh works unchanged.
    by_mode: dict[str, dict[str, int | float]] = {}
    by_cat: dict[str, dict[str, dict[str, int | float]]] = {}
    for r in rows:
        m = by_mode.setdefault(r["mode"], {"passed": 0, "failed": 0, "scores": []})
        m["passed" if r["scored"] else "failed"] += 1
        m["scores"].append(r["judge_score"])
        cm = by_cat.setdefault(r["category"], {}).setdefault(r["mode"], {"passed": 0, "failed": 0})
        cm["passed" if r["scored"] else "failed"] += 1

    def rate(d: dict) -> float:
        t = d["passed"] + d["failed"]
        return round(d["passed"] / t, 3) if t else 0.0

    for m in by_mode.values():
        m["rate"] = rate(m)
        m["mean_judge_score"] = round(sum(m["scores"]) / len(m["scores"]), 3) if m["scores"] else 0.0
        del m["scores"]
    for cat in by_cat.values():
        for m in cat.values():
            m["rate"] = rate(m)

    a_rate = by_mode.get("A", {}).get("rate", 0.0)
    b_rate = by_mode.get("B", {}).get("rate", 0.0)
    delta = round(a_rate - b_rate, 3)
    delta_by_cat = {}
    for cat, m in by_cat.items():
        a = m.get("A", {}).get("rate", 0.0)
        b = m.get("B", {}).get("rate", 0.0)
        delta_by_cat[cat] = round(a - b, 3)

    summary = {
        "tag": args.tag,
        "task_count": len(tasks),
        "trial_count": len(rows),
        "model": args.model,
        "judge_model": args.judge,
        "judge_threshold": args.judge_threshold,
        "by_mode": by_mode,
        "by_category": by_cat,
        "delta": delta,
        "delta_by_category": delta_by_cat,
    }
    summary_path.write_text(json.dumps(summary, indent=2))
    print(f"\nwrote {summary_path}")
    print(f"\n=== Summary: {args.tag} ===")
    print(f"Trials: {len(rows)}  model: {args.model}")
    for mode, m in by_mode.items():
        print(f"  mode {mode}: {m['passed']}/{m['passed']+m['failed']} = {m['rate']}  mean_judge={m['mean_judge_score']}")
    print(f"Delta (A − B): {delta:+}")
    for cat, d in delta_by_cat.items():
        print(f"  {cat}: {d:+}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
