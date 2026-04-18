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


def report(group_by: str = "day", since_iso: str | None = None) -> str:
    """Multi-line breakdown of recent spend, grouped by day / session / purpose / model.

    Output is human-readable lines aligned in columns. Suitable for stdout
    or pasting into a daily-status comment. The grouping key is one of:
      - 'day' (UTC date prefix, default)
      - 'session' (session_id from CHUMP_SESSION_ID / CLAUDE_SESSION_ID)
      - 'purpose' (the call's purpose tag, e.g. 'v2-agent:reflection-...')
      - 'model' (the agent or judge model id)
    """
    p = _ledger_path()
    if not p.exists():
        return "No spend recorded yet."
    rows: list[dict] = []
    for line in p.open():
        try:
            r = json.loads(line)
        except Exception:
            continue
        if since_iso is not None and r.get("ts", "") < since_iso:
            continue
        rows.append(r)
    if not rows:
        return "No matching rows."

    def key_for(r: dict) -> str:
        if group_by == "day":
            return r.get("ts", "")[:10] or "?"
        if group_by == "session":
            return (r.get("session") or "(no-session)")[:40]
        if group_by == "purpose":
            return (r.get("purpose") or "?")[:60]
        if group_by == "model":
            return r.get("model", "?")
        return r.get("ts", "")[:10]

    by_key: dict[str, dict] = {}
    for r in rows:
        k = key_for(r)
        s = by_key.setdefault(k, {"cost": 0.0, "calls": 0,
                                   "input_tokens": 0, "output_tokens": 0})
        s["cost"] += float(r.get("estimated_cost_usd", 0.0))
        s["calls"] += 1
        s["input_tokens"] += int(r.get("input_tokens", 0))
        s["output_tokens"] += int(r.get("output_tokens", 0))

    sorted_keys = sorted(by_key.keys(),
                         key=lambda k: -by_key[k]["cost"])
    total_cost = sum(s["cost"] for s in by_key.values())
    total_calls = sum(s["calls"] for s in by_key.values())

    lines = [
        f"=== Cost Ledger Report (group_by={group_by}) ===",
        f"  Total: ${total_cost:.2f} across {total_calls} calls",
        f"  Top {min(15, len(sorted_keys))} {group_by}s by spend:",
        f"",
        f"  {'KEY':<48} {'COST':>10} {'CALLS':>8} {'IN_TOK':>10} {'OUT_TOK':>10}",
    ]
    for k in sorted_keys[:15]:
        s = by_key[k]
        lines.append(
            f"  {k[:48]:<48} {'$%.4f' % s['cost']:>10} "
            f"{s['calls']:>8} {s['input_tokens']:>10} {s['output_tokens']:>10}"
        )
    if len(sorted_keys) > 15:
        rest = sum(by_key[k]["cost"] for k in sorted_keys[15:])
        lines.append(f"  ({len(sorted_keys) - 15} more, ${rest:.4f} total)")
    return "\n".join(lines)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Cost ledger inspection.")
    ap.add_argument("--summary", action="store_true",
                    help="Short one-line summary (default if no flag).")
    ap.add_argument("--report", action="store_true",
                    help="Multi-line breakdown by --group-by key.")
    ap.add_argument("--group-by", default="day",
                    choices=("day", "session", "purpose", "model"),
                    help="Grouping for --report (default: day)")
    ap.add_argument("--since", default=None,
                    help="ISO timestamp; only count rows on/after (e.g. 2026-04-18)")
    ap.add_argument("--json", action="store_true",
                    help="Raw JSON dump of total()")
    args = ap.parse_args()

    if args.json:
        print(json.dumps(total(since_iso=args.since), indent=2))
    elif args.report:
        print(report(group_by=args.group_by, since_iso=args.since))
    else:
        # Default + --summary both produce summary
        print(summary())
