#!/usr/bin/env python3.12
"""reproduce-sweep.py — inspect a summary.json harness_checkpoint and
either print the exact call that would reproduce the sweep, or exit 1 with
a drift report if the current repo state has diverged.

Usage:
    python3 scripts/ab-harness/reproduce-sweep.py logs/ab/my-tag-1234567890.summary.json

Exit codes:
    0 — checkpoint matches current repo state; reproducing call printed to stdout.
    1 — drift detected; diff report printed to stderr.
    2 — summary.json has no harness_checkpoint (pre-INFRA-EXPERIMENT-CHECKPOINT sweep).
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


# ── helpers ──────────────────────────────────────────────────────────────────

def _sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def _current_git_sha() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
            cwd=Path(__file__).parent,
        ).decode().strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


# Lessons blocks embedded in run-cloud-v2.py — must stay in sync.
LESSONS_BLOCK_V1 = """## Lessons from prior episodes

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

LESSONS_BLOCK_COG016 = """## Lessons from prior episodes
The following directives came from structured reflections on previous tasks. Apply them when relevant; do not narrate that you are applying them.

IMPORTANT: if you do not have actual tool access in this context, do NOT emit `<function_calls>`, `<tool_call>`, `<tool_use>`, or similar markup. Instead, describe in plain prose what you would do if tools were available, and acknowledge that you cannot execute commands directly.
- (P1) [tool_middleware] Validate inputs and preconditions (file existence, permissions, schema) before calling tools; do not assume success.
- (P1) [perception] If the user prompt is ambiguous (e.g. lacks a target path, file, or scope), ask one clarifying question rather than guessing.
- (P1) [reflection] After any failed tool call, do not retry the identical call without diagnostic information about why it failed.
- (P1) [policy] Refuse destructive operations (rm -rf, force-push, drop table, etc.) on shared resources without explicit user confirmation."""

_LESSONS_BY_VERSION: dict[str, str] = {
    "v1": LESSONS_BLOCK_V1,
    "cog016": LESSONS_BLOCK_COG016,
    "cog016+sake": LESSONS_BLOCK_COG016,
}

# Dispatch table and retry config must match run-cloud-v2.py exactly.
_CURRENT_DISPATCH_TABLE = {
    "together:": "call_together",
    "ollama:": "call_ollama",
    "(bare)": "call_anthropic",
}
_CURRENT_RETRY_CONFIG = {
    "anthropic_max_attempts": 6,
    "together_max_attempts": 7,
    "ollama_max_attempts": 3,
    "together_backoff_formula": "2**(attempt+1)",
    "anthropic_backoff_formula": "2**(attempt+1)",
}


# ── drift detection ───────────────────────────────────────────────────────────

def check_drift(cp: dict) -> list[str]:
    """Return a list of drift messages (empty = no drift)."""
    drifts: list[str] = []

    # 1. git SHA
    current_sha = _current_git_sha()
    if current_sha and cp.get("git_sha") and current_sha != cp["git_sha"]:
        drifts.append(
            f"git_sha mismatch:\n"
            f"  checkpoint : {cp['git_sha']}\n"
            f"  current    : {current_sha}"
        )

    # 2. lessons block hash
    lessons_version = cp.get("lessons_version", "v1")
    current_lessons = _LESSONS_BY_VERSION.get(lessons_version, "")
    current_lb_hash = _sha256(current_lessons) if current_lessons else ""
    if current_lb_hash and cp.get("lessons_block_hash") and current_lb_hash != cp["lessons_block_hash"]:
        drifts.append(
            f"lessons_block_hash mismatch (lessons_version={lessons_version!r}):\n"
            f"  checkpoint : {cp['lessons_block_hash']}\n"
            f"  current    : {current_lb_hash}\n"
            f"  The lessons block embedded in run-cloud-v2.py has changed since "
            f"this sweep ran. Results are not reproducible under the same prompt conditions."
        )

    # 3. judge panel hash
    current_judges_hash = _sha256(json.dumps(sorted(cp.get("judge_panel", []))))
    if cp.get("judge_panel_hash") and current_judges_hash != cp["judge_panel_hash"]:
        drifts.append(
            f"judge_panel_hash mismatch:\n"
            f"  checkpoint panel : {cp.get('judge_panel')}\n"
            f"  To reproduce, pass --judges {','.join(cp.get('judge_panel', []))!r}"
        )

    # 4. retry config hash
    current_retry_hash = _sha256(json.dumps(_CURRENT_RETRY_CONFIG, sort_keys=True))
    if cp.get("retry_config_hash") and current_retry_hash != cp["retry_config_hash"]:
        drifts.append(
            f"retry_config_hash mismatch:\n"
            f"  checkpoint : {cp['retry_config_hash']}\n"
            f"  current    : {current_retry_hash}\n"
            f"  Retry budget has changed. Transient-failure rates may differ."
        )

    # 5. dispatch table hash
    current_dispatch_hash = _sha256(json.dumps(_CURRENT_DISPATCH_TABLE, sort_keys=True))
    if cp.get("dispatch_table_hash") and current_dispatch_hash != cp["dispatch_table_hash"]:
        drifts.append(
            f"dispatch_table_hash mismatch:\n"
            f"  checkpoint : {cp['dispatch_table_hash']}\n"
            f"  current    : {current_dispatch_hash}\n"
            f"  Model dispatch routing has changed."
        )

    return drifts


# ── reproduce call builder ────────────────────────────────────────────────────

def build_reproduce_call(summary: dict, cp: dict) -> str:
    """Reconstruct the run-cloud-v2.py invocation from the summary dict."""
    lines: list[str] = ["python3 scripts/ab-harness/run-cloud-v2.py \\"]

    fixture = summary.get("fixture") or "<fixture path — not recorded; check original command>"
    lines.append(f"    --fixture {fixture} \\")
    lines.append(f"    --tag {summary['tag']}-reproduce \\")
    lines.append(f"    --model {summary['model']} \\")

    judges = cp.get("judge_panel") or (
        [summary["judge_model"]] if summary.get("judge_model") else []
    )
    if judges:
        lines.append(f"    --judges {','.join(judges)} \\")

    lines.append(f"    --judge-threshold {summary.get('judge_threshold', 0.5)} \\")
    lines.append(f"    --mode {summary.get('harness_mode', 'ab')} \\")
    lines.append(f"    --lessons-version {summary.get('lessons_version', 'v1')} \\")
    lines.append(f"    --limit {summary.get('task_count', 20)}")

    distractor = summary.get("distractor", "")
    if distractor:
        lines[-1] += " \\"
        lines.append(f"    --distractor {json.dumps(distractor)}")

    # Env var hints
    env_fp = cp.get("env_fingerprint", {})
    env_hints: list[str] = []
    for k, v in sorted(env_fp.items()):
        if v:
            env_hints.append(f"  {k}={v!r}")

    result = "\n".join(lines)
    if env_hints:
        result += (
            "\n\n# Env vars recorded at sweep time (secrets redacted to 8 chars):\n"
            + "\n".join(env_hints)
        )
    result += f"\n\n# Original git SHA: {cp.get('git_sha', '(unknown)')}"
    return result


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    summary_path = Path(sys.argv[1])
    if not summary_path.exists():
        sys.stderr.write(f"error: {summary_path} does not exist\n")
        return 1

    summary = json.loads(summary_path.read_text())

    cp = summary.get("harness_checkpoint")
    if cp is None:
        sys.stderr.write(
            f"error: {summary_path.name} has no 'harness_checkpoint' key.\n"
            "This summary was produced before INFRA-EXPERIMENT-CHECKPOINT landed.\n"
            "Reproducibility metadata is unavailable for this sweep.\n"
        )
        return 2

    drifts = check_drift(cp)
    if drifts:
        sys.stderr.write(
            f"DRIFT DETECTED — current harness has diverged from checkpoint in "
            f"{len(drifts)} dimension(s):\n\n"
        )
        for i, d in enumerate(drifts, 1):
            sys.stderr.write(f"[{i}] {d}\n\n")
        sys.stderr.write(
            "Reproducing this sweep with the current harness will NOT match the "
            "original conditions. Checkout the checkpoint git SHA to reproduce exactly:\n"
            f"  git checkout {cp.get('git_sha', '(unknown)')}\n"
        )
        return 1

    print("# Harness checkpoint matches current repo state.")
    print("# Run the following command to reproduce this sweep:\n")
    print(build_reproduce_call(summary, cp))
    return 0


if __name__ == "__main__":
    sys.exit(main())
