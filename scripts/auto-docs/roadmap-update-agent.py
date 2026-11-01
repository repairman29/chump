#!/usr/bin/env python3.12
"""
roadmap-update-agent.py — INFRA-1147

Weekly LLM-driven proposal that reads docs/ROADMAP.md + recent ship history
+ shipped gaps, calls Claude (haiku default, sonnet --high-fidelity), and
opens a PR `roadmap/weekly-update-YYYY-WW` with proposed ROADMAP.md updates
for operator review. Never auto-merges.

Cost target: <$0.05/run with haiku-4-5 = ~$2.60/yr at weekly cadence.

Usage:
  python3.12 scripts/auto-docs/roadmap-update-agent.py
  python3.12 scripts/auto-docs/roadmap-update-agent.py --dry-run     # don't open PR
  python3.12 scripts/auto-docs/roadmap-update-agent.py --high-fidelity  # sonnet
  python3.12 scripts/auto-docs/roadmap-update-agent.py --force        # override same-week idempotency
  python3.12 scripts/auto-docs/roadmap-update-agent.py --since-days 7 # window (default 7)

Companion to INFRA-1145 (chump roadmap-status drift detection) and INFRA-1146
(SessionStart inject). 1145 measures drift, 1146 surfaces drift, 1147 closes
drift via operator-reviewed PR.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import subprocess
import sys
from pathlib import Path

# ── Load .env (no python-dotenv dep) ──────────────────────────────────────────
def _load_dotenv() -> None:
    script_dir = Path(__file__).resolve().parent
    p = script_dir
    for _ in range(6):
        env_path = p / ".env"
        if env_path.exists():
            for line in env_path.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip().strip('"').strip("'")
                os.environ.setdefault(k.strip(), v)
            return
        p = p.parent

_load_dotenv()

# ── Repo root resolution ──────────────────────────────────────────────────────
def _repo_root() -> Path:
    try:
        root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], stderr=subprocess.DEVNULL
        ).decode().strip()
        return Path(root)
    except Exception:
        return Path(__file__).resolve().parent.parent.parent

REPO_ROOT = _repo_root()
AMBIENT_LOG = REPO_ROOT / ".chump-locks" / "ambient.jsonl"


def emit(kind: str, **fields) -> None:
    """Emit an ambient event line. Best-effort; never raises."""
    payload = {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "kind": kind,
        "source": "roadmap-update-agent",
        **fields,
    }
    try:
        AMBIENT_LOG.parent.mkdir(parents=True, exist_ok=True)
        with AMBIENT_LOG.open("a") as f:
            f.write(json.dumps(payload) + "\n")
    except Exception:
        pass


def _git(*args: str, check: bool = True) -> str:
    res = subprocess.run(
        ["git", *args], cwd=REPO_ROOT, capture_output=True, text=True, check=False
    )
    if check and res.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {res.stderr}")
    return res.stdout.strip()


def _gh_api(method: str, endpoint: str, fields: dict | None = None) -> dict:
    cmd = ["gh", "api", "-X", method, endpoint]
    for k, v in (fields or {}).items():
        cmd += ["-f", f"{k}={v}"]
    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if res.returncode != 0:
        raise RuntimeError(f"gh api failed: {res.stderr}")
    return json.loads(res.stdout) if res.stdout.strip() else {}


# ── Inputs ────────────────────────────────────────────────────────────────────
def collect_inputs(since_days: int) -> dict:
    roadmap_path = REPO_ROOT / "docs" / "ROADMAP.md"
    if not roadmap_path.exists():
        raise RuntimeError(f"ROADMAP.md not found at {roadmap_path}")

    roadmap_text = roadmap_path.read_text()

    # Shipped commits with gap IDs
    since = f"{since_days} days ago"
    log_text = _git(
        "log", "origin/main", f"--since={since}",
        "--pretty=format:%h %s", "--no-merges",
    )

    # Shipped gaps via chump CLI
    chump = REPO_ROOT / "target" / "release" / "chump"
    chump_bin = str(chump) if chump.exists() else "chump"
    res = subprocess.run(
        [chump_bin, "gap", "list", "--status", "done", "--json"],
        capture_output=True, text=True, check=False,
    )
    shipped_gaps: list[dict] = []
    if res.returncode == 0:
        try:
            all_done = json.loads(res.stdout)
            cutoff = (datetime.date.today() - datetime.timedelta(days=since_days)).isoformat()
            for g in all_done:
                cd = g.get("closed_date") or ""
                if cd >= cutoff:
                    shipped_gaps.append({
                        "id": g.get("id"),
                        "title": g.get("title", "")[:80],
                        "closed_date": cd,
                    })
        except Exception:
            pass

    return {
        "roadmap_text": roadmap_text,
        "ship_log": log_text,
        "shipped_gaps": shipped_gaps,
        "since_days": since_days,
    }


# ── LLM call ──────────────────────────────────────────────────────────────────
def build_prompt(inputs: dict) -> str:
    shipped_lines = "\n".join(
        f"  - {g['id']} ({g['closed_date']}): {g['title']}"
        for g in inputs["shipped_gaps"][:80]
    )
    return f"""You are the Chump roadmap-update agent. Read the current ROADMAP.md
+ recent ship history + shipped gaps from the last {inputs['since_days']} days,
and propose updates to ROADMAP.md.

CURRENT ROADMAP.md:
```markdown
{inputs['roadmap_text']}
```

SHIP HISTORY (git log origin/main --since={inputs['since_days']}d, gap-ID-bearing commits):
```
{inputs['ship_log']}
```

SHIPPED GAPS (chump gap list --status done --since {inputs['since_days']}d, top 80):
{shipped_lines}

YOUR TASK:
1. For each weekly outcome in ROADMAP.md, mark shipped gaps with ✅ (delta only).
2. If a week's outcome is fully achieved, mark the section ✅ SHIPPED.
3. Add a "What changed this week" paragraph at the top summarising the 3-5
   most impactful ships and any pillar drift.
4. Do NOT invent new outcomes or weeks. Only update existing structure.
5. Output a UNIFIED DIFF (git diff -u format) against the current ROADMAP.md.
   Start the diff with `--- a/docs/ROADMAP.md` and `+++ b/docs/ROADMAP.md`.

OUTPUT FORMAT (strict): ONLY the unified diff, nothing else. No preamble,
no explanation, no markdown fence around the diff. Plain text starting
with `--- a/docs/ROADMAP.md`.

If the roadmap genuinely needs no update (no shipped gaps trace to any
outcome), output exactly the string `NO_CHANGE` and nothing else."""


def call_llm(prompt: str, model: str) -> tuple[str, dict]:
    """Call Anthropic; return (response_text, cost_info)."""
    try:
        import anthropic  # type: ignore
    except ImportError:
        raise RuntimeError("anthropic package not installed; pip install anthropic")

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise RuntimeError("ANTHROPIC_API_KEY not set in env or .env")

    client = anthropic.Anthropic(api_key=api_key)
    resp = client.messages.create(
        model=model,
        max_tokens=4096,
        messages=[{"role": "user", "content": prompt}],
    )
    text = "".join(b.text for b in resp.content if hasattr(b, "text"))

    # Per-model approximate pricing (USD per 1M tokens, 2026-Q1 rates).
    pricing = {
        "claude-haiku-4-5-20251001": (1.0, 5.0),
        "claude-haiku-4-5": (1.0, 5.0),
        "claude-sonnet-4-6": (3.0, 15.0),
        "claude-opus-4-7": (15.0, 75.0),
    }
    in_rate, out_rate = pricing.get(model, (3.0, 15.0))
    input_tok = resp.usage.input_tokens
    output_tok = resp.usage.output_tokens
    usd = (input_tok * in_rate + output_tok * out_rate) / 1_000_000

    return text, {
        "model": model,
        "input_tokens": input_tok,
        "output_tokens": output_tok,
        "usd": round(usd, 4),
    }


# ── PR creation ───────────────────────────────────────────────────────────────
def current_iso_week() -> str:
    today = datetime.date.today()
    y, w, _ = today.isocalendar()
    return f"{y}-W{w:02d}"


def open_pr(branch: str, diff_text: str, cost_info: dict, since_days: int) -> str:
    """Apply diff, commit, push, open PR. Returns PR URL or raises."""
    # Apply diff
    res = subprocess.run(
        ["git", "apply", "--whitespace=nowarn"],
        input=diff_text, cwd=REPO_ROOT, capture_output=True, text=True,
    )
    if res.returncode != 0:
        raise RuntimeError(f"git apply failed: {res.stderr[:500]}")

    # Create branch
    _git("checkout", "-b", branch)
    _git("add", "docs/ROADMAP.md")

    msg = (
        f"docs(INFRA-1147): weekly roadmap update — {since_days}d window\n"
        f"\n"
        f"Auto-proposed by scripts/auto-docs/roadmap-update-agent.py.\n"
        f"Model: {cost_info['model']}  "
        f"Tokens: in={cost_info['input_tokens']} out={cost_info['output_tokens']}  "
        f"Cost: ${cost_info['usd']}\n"
        f"\n"
        f"Operator: review the diff, edit if needed, merge when ready.\n"
        f"Never auto-merged.\n"
    )
    env = os.environ.copy()
    # INFRA-2425: CHUMP_OBS_BUDGET_BYPASS deleted; guard is warn-only by default.
    subprocess.run(
        ["git", "commit", "-m", msg], cwd=REPO_ROOT, env=env, check=True
    )

    # Push (force-with-lease in case the branch already exists; --force was filtered)
    push_env = os.environ.copy()
    push_env["CHUMP_BYPASS_BOT_MERGE"] = "1"
    push_env["CHUMP_GAP_CHECK"] = "0"
    subprocess.run(
        ["git", "push", "-u", "origin", branch],
        cwd=REPO_ROOT, env=push_env, check=True,
    )

    # Open PR via REST (avoid GraphQL — INFRA-1080 background priority)
    repo = "repairman29/chump"
    pr = _gh_api("POST", f"repos/{repo}/pulls", fields={
        "title": f"docs(INFRA-1147): weekly ROADMAP.md update ({current_iso_week()})",
        "head": branch,
        "base": "main",
        "body": (
            f"Auto-proposed by `scripts/auto-docs/roadmap-update-agent.py`.\n\n"
            f"- Window: last {since_days} days\n"
            f"- Model: `{cost_info['model']}`\n"
            f"- Tokens: in={cost_info['input_tokens']} out={cost_info['output_tokens']}\n"
            f"- Cost: ${cost_info['usd']}\n\n"
            f"**Operator action**: review the diff, edit if needed, merge when ready. "
            f"This PR is **never auto-merged**.\n\n"
            f"INFRA-1147 / closes the silo-thrust roadmap loop "
            f"(measure→1145, surface→1146, close→1147)."
        ),
    })
    return pr.get("html_url", "")


# ── Main ──────────────────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="don't apply diff or open PR")
    ap.add_argument("--high-fidelity", action="store_true", help="use sonnet instead of haiku")
    ap.add_argument("--force", action="store_true", help="override same-week idempotency")
    ap.add_argument("--since-days", type=int, default=7, help="ship-window in days")
    ap.add_argument("--fixture-roadmap", help="path to fixture ROADMAP.md (test mode)")
    ap.add_argument("--fixture-log", help="path to fixture git log output (test mode)")
    ap.add_argument("--fixture-gaps", help="path to fixture shipped-gaps JSON (test mode)")
    ap.add_argument("--prompt-only", action="store_true",
                    help="print the prompt and exit; no LLM call")
    args = ap.parse_args()

    iso_week = current_iso_week()
    branch = f"roadmap/weekly-update-{iso_week}"

    # Idempotency: same-week branch already exists?
    if not args.force:
        existing = _git("ls-remote", "--heads", "origin", branch, check=False)
        if existing.strip():
            print(f"[roadmap-update-agent] branch {branch} already exists — use --force to re-propose")
            emit("roadmap_update_proposal_skipped", reason="branch_exists", branch=branch)
            return 0

    # Inputs (fixtures override for tests)
    if args.fixture_roadmap or args.fixture_log or args.fixture_gaps:
        inputs = {
            "roadmap_text": Path(args.fixture_roadmap).read_text() if args.fixture_roadmap else "",
            "ship_log": Path(args.fixture_log).read_text() if args.fixture_log else "",
            "shipped_gaps": json.loads(Path(args.fixture_gaps).read_text()) if args.fixture_gaps else [],
            "since_days": args.since_days,
        }
    else:
        try:
            inputs = collect_inputs(args.since_days)
        except Exception as e:
            emit("roadmap_update_proposal_failed", reason=f"collect_inputs: {e}")
            print(f"[roadmap-update-agent] FAIL: {e}", file=sys.stderr)
            return 2

    prompt = build_prompt(inputs)

    if args.prompt_only:
        print(prompt)
        return 0

    model = "claude-sonnet-4-6" if args.high_fidelity else "claude-haiku-4-5-20251001"

    try:
        diff_text, cost_info = call_llm(prompt, model)
    except Exception as e:
        emit("roadmap_update_proposal_failed", reason=f"llm: {e}", model=model)
        print(f"[roadmap-update-agent] LLM FAIL: {e}", file=sys.stderr)
        return 3

    emit("roadmap_update_proposal_cost", **cost_info)

    if diff_text.strip() == "NO_CHANGE":
        print(f"[roadmap-update-agent] NO_CHANGE — nothing to propose this week")
        emit("roadmap_update_proposal_skipped", reason="no_change", model=model)
        return 0

    # Validate diff shape (must start with --- a/docs/ROADMAP.md)
    if not diff_text.strip().startswith("--- a/docs/ROADMAP.md"):
        emit("roadmap_update_proposal_failed", reason="bad_diff_format",
             diff_preview=diff_text[:200])
        print(f"[roadmap-update-agent] FAIL: LLM did not produce a unified diff. "
              f"First 200 chars: {diff_text[:200]}", file=sys.stderr)
        return 4

    if args.dry_run:
        print(diff_text)
        print(f"\n[roadmap-update-agent] dry-run — would open PR on branch {branch}")
        print(f"[roadmap-update-agent] cost: ${cost_info['usd']}")
        return 0

    try:
        url = open_pr(branch, diff_text, cost_info, args.since_days)
        emit("roadmap_update_proposal_opened", branch=branch, url=url, **cost_info)
        print(f"[roadmap-update-agent] PR opened: {url}")
        return 0
    except Exception as e:
        emit("roadmap_update_proposal_failed", reason=f"open_pr: {e}")
        print(f"[roadmap-update-agent] PR open FAIL: {e}", file=sys.stderr)
        return 5


if __name__ == "__main__":
    sys.exit(main())
