"""cost_ledger.py — single source of truth for cloud LLM spend.

Every cloud A/B harness call should `record(...)` to this ledger. Aggregate
spend is then queryable via `total()` or by reading `logs/cost-ledger.jsonl`
directly. Prevents the "spent ~$13 (eyeballed from log files)" failure mode
that triggered this module.

Usage:
    from cost_ledger import record, total, summary
    record("claude-haiku-4-5", input_tokens=500, output_tokens=400, purpose="A/B trial")
    print(total())   # → {"all": 12.34, "by_model": {...}, "calls": 247}

Pricing table is per 1M tokens. Update when Anthropic changes prices.
Conservative — slightly overestimates so we don't undershoot the wallet.
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any


# USD per 1M tokens. Updated 2026-04-18.
# Source: https://www.anthropic.com/pricing
PRICING_USD_PER_M_TOKENS: dict[str, dict[str, float]] = {
    # Anthropic
    "claude-haiku-4-5":      {"input": 1.0, "output": 5.0},
    "claude-haiku-4-5-20251001": {"input": 1.0, "output": 5.0},
    "claude-sonnet-4-5":     {"input": 3.0, "output": 15.0},
    "claude-sonnet-4-5-20250929": {"input": 3.0, "output": 15.0},
    "claude-sonnet-4-6":     {"input": 3.0, "output": 15.0},  # observed in study; same family pricing
    "claude-opus-4-5":       {"input": 15.0, "output": 75.0},
    "claude-opus-4-5-20251101": {"input": 15.0, "output": 75.0},
    "claude-3-5-sonnet-20241022": {"input": 3.0, "output": 15.0},
    "claude-3-5-haiku-20241022":  {"input": 1.0, "output": 5.0},
    "claude-3-haiku-20240307":    {"input": 0.25, "output": 1.25},
    # OpenAI (when wired)
    "gpt-4o":                {"input": 2.5, "output": 10.0},
    "gpt-4o-mini":           {"input": 0.15, "output": 0.6},
    # Google (when wired)
    "gemini-1.5-pro":        {"input": 1.25, "output": 5.0},
    "gemini-1.5-flash":      {"input": 0.075, "output": 0.3},
}


def _ledger_path() -> Path:
    """Always write to repo-root logs/, even if cwd is a subdirectory."""
    # Walk up to find a directory containing .git (worktree or main).
    cur = Path.cwd().resolve()
    for parent in [cur] + list(cur.parents):
        if (parent / ".git").exists():
            p = parent / "logs" / "cost-ledger.jsonl"
            p.parent.mkdir(parents=True, exist_ok=True)
            return p
    # Fallback: cwd
    p = Path("logs") / "cost-ledger.jsonl"
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def estimate_cost_usd(model: str, input_tokens: int, output_tokens: int) -> float:
    """Returns estimated USD cost for one call. Returns 0.0 for unknown models
    (logs a single-line warning to stderr — doesn't fail)."""
    pricing = PRICING_USD_PER_M_TOKENS.get(model)
    if pricing is None:
        # Try matching by prefix (handle date-suffixed model IDs)
        for known, p in PRICING_USD_PER_M_TOKENS.items():
            if model.startswith(known):
                pricing = p
                break
    if pricing is None:
        import sys
        print(f"[cost_ledger] WARN: no pricing for {model}; charging $0", file=sys.stderr)
        return 0.0
    return (input_tokens / 1_000_000) * pricing["input"] + \
           (output_tokens / 1_000_000) * pricing["output"]


def record(model: str, input_tokens: int, output_tokens: int,
           purpose: str = "", session: str = "", extra: dict | None = None) -> float:
    """Append one row to the ledger. Returns the estimated cost in USD.

    Best-effort: never raises on disk errors (we don't want to fail an A/B
    run because the ledger file is missing)."""
    try:
        cost = estimate_cost_usd(model, input_tokens, output_tokens)
        row: dict[str, Any] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "model": model,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "estimated_cost_usd": round(cost, 6),
            "purpose": purpose,
            "session": session or os.environ.get("CHUMP_SESSION_ID", "")
                                or os.environ.get("CLAUDE_SESSION_ID", ""),
        }
        if extra:
            row.update(extra)
        with _ledger_path().open("a") as f:
            f.write(json.dumps(row) + "\n")
        return cost
    except Exception:
        return 0.0


def total(session: str | None = None, since_iso: str | None = None) -> dict:
    """Aggregate spend across the ledger.

    Args:
        session: filter to only this session_id. None = all sessions.
        since_iso: filter to only rows on/after this ISO timestamp. None = all time.

    Returns: {"all": float, "by_model": {model: float}, "by_purpose": {...}, "calls": int}
    """
    p = _ledger_path()
    if not p.exists():
        return {"all": 0.0, "by_model": {}, "by_purpose": {}, "calls": 0}
    by_model: dict[str, float] = {}
    by_purpose: dict[str, float] = {}
    total_usd = 0.0
    calls = 0
    for line in p.open():
        try:
            r = json.loads(line)
        except Exception:
            continue
        if session is not None and r.get("session") != session:
            continue
        if since_iso is not None and r.get("ts", "") < since_iso:
            continue
        cost = float(r.get("estimated_cost_usd", 0.0))
        total_usd += cost
        calls += 1
        m = r.get("model", "?")
        by_model[m] = by_model.get(m, 0.0) + cost
        pur = r.get("purpose", "?")
        by_purpose[pur] = by_purpose.get(pur, 0.0) + cost
    return {
        "all": round(total_usd, 4),
        "by_model": {k: round(v, 4) for k, v in by_model.items()},
        "by_purpose": {k: round(v, 4) for k, v in by_purpose.items()},
        "calls": calls,
    }


def summary() -> str:
    """Human-readable one-paragraph summary."""
    t = total()
    if t["calls"] == 0:
        return "No spend recorded yet."
    lines = [f"Total: ${t['all']:.2f} across {t['calls']} calls."]
    if t["by_model"]:
        top = sorted(t["by_model"].items(), key=lambda kv: -kv[1])[:5]
        lines.append("Top models: " + ", ".join(f"{k} ${v:.2f}" for k, v in top))
    return "\n".join(lines)


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "--summary":
        print(summary())
    else:
        print(json.dumps(total(), indent=2))
