#!/usr/bin/env python3.12
"""Together.ai free-tier model registry for the ab-harness.

Verified snapshot: 2026-04-21.
Together rotates the free-tier list periodically — re-verify before a sweep
by running: python3.12 scripts/ab-harness/together_free_models.py --check

Usage:
    from together_free_models import TOGETHER_FREE_MODELS, recommend_model
"""

import argparse
import json
import sys
import urllib.request
import urllib.error

LAST_VERIFIED = "2026-04-21"

TOGETHER_FREE_MODELS: dict[str, dict] = {
    "meta-llama/Llama-3.3-70B-Instruct-Turbo": {
        "size": "70B",
        "tier": "large",
        "free": True,
        "rate_limit_rpm": 60,
        "roles": ["agent", "judge"],
        "notes": "Primary free-tier judge in EVAL-042/068. Stable free-tier slot.",
    },
    "meta-llama/Llama-3.3-8B-Instruct": {
        "size": "8B",
        "tier": "small",
        "free": True,
        "rate_limit_rpm": 60,
        "roles": ["agent"],
        "notes": "Small-tier agent for cost-optimization sweeps.",
    },
    "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8": {
        "size": "480B MoE (35B active)",
        "tier": "large",
        "free": True,
        "rate_limit_rpm": 60,
        "roles": ["agent", "judge"],
        "notes": "Large-tier agent. Free-tier as of 2026-04-20 snapshot; verify before use.",
    },
    "Qwen/Qwen2.5-7B-Instruct": {
        "size": "7B",
        "tier": "small",
        "free": True,
        "rate_limit_rpm": 60,
        "roles": ["agent"],
        "notes": "Small-tier agent.",
    },
    "Qwen/Qwen2.5-72B-Instruct-Turbo": {
        "size": "72B",
        "tier": "large",
        "free": True,
        "rate_limit_rpm": 60,
        "roles": ["agent", "judge"],
        "notes": "Large-tier agent/judge. Paid tier fallback at ~$0.60/M tokens.",
    },
    "deepseek-ai/DeepSeek-V3": {
        "size": "671B MoE (37B active)",
        "tier": "large",
        "free": None,
        "rate_limit_rpm": 60,
        "roles": ["agent"],
        "notes": "Partial free-tier; may require paid slot depending on day. "
                 "Budget ~$0.60/M if unavailable free.",
    },
}

TOGETHER_PAID_FALLBACK_RATE = 0.60  # $/M tokens (input+output), typical paid serverless tier


def recommend_model(role: str = "agent", tier: str = "large") -> str | None:
    """Return the best free-tier model for a given role and tier.

    role: 'agent' or 'judge'
    tier: 'large' or 'small'
    Returns the Together model name (without 'together:' prefix), or None.
    """
    candidates = [
        (name, meta) for name, meta in TOGETHER_FREE_MODELS.items()
        if meta.get("free") is True
        and role in meta.get("roles", [])
        and meta.get("tier") == tier
    ]
    if not candidates:
        return None
    return candidates[0][0]


def _check_together_availability(api_key: str) -> None:
    """Quick ping to Together /models to confirm connectivity."""
    req = urllib.request.Request(
        "https://api.together.xyz/v1/models",
        headers={"authorization": f"Bearer {api_key}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            models = json.loads(r.read())
        free_ids = {m["id"] for m in models if m.get("pricing", {}).get("base", 1) == 0}
        print(f"Together API reachable. {len(free_ids)} free-tier models found.")
        for name in TOGETHER_FREE_MODELS:
            status = "FREE" if name in free_ids else "PAID/UNAVAILABLE"
            print(f"  {status:20s} {name}")
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:  # noqa: BLE001
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


def main() -> None:
    ap = argparse.ArgumentParser(description="Together free-tier model registry.")
    ap.add_argument("--check", action="store_true",
                    help="Ping Together API and verify which models are still free-tier.")
    ap.add_argument("--list", action="store_true", help="Print all known free-tier models.")
    ap.add_argument("--recommend", choices=("agent", "judge"), default=None,
                    help="Recommend the best free-tier model for a role.")
    args = ap.parse_args()

    if args.list or not any([args.check, args.recommend]):
        print(f"Together free-tier model registry (last verified: {LAST_VERIFIED})")
        print()
        for name, meta in TOGETHER_FREE_MODELS.items():
            free_str = "free" if meta.get("free") is True else ("partial" if meta.get("free") is None else "paid")
            roles = ",".join(meta.get("roles", []))
            print(f"  [{free_str:7s}] {name}")
            print(f"           tier={meta['tier']}  roles={roles}  rpm={meta['rate_limit_rpm']}")
        return

    if args.recommend:
        model = recommend_model(args.recommend)
        if model:
            print(f"together:{model}")
        else:
            print(f"No free-tier {args.recommend} model found.", file=sys.stderr)
            sys.exit(1)
        return

    if args.check:
        import os
        api_key = os.environ.get("TOGETHER_API_KEY", "")
        if not api_key:
            print("TOGETHER_API_KEY not set — cannot verify.", file=sys.stderr)
            sys.exit(1)
        _check_together_availability(api_key)


if __name__ == "__main__":
    main()
