#!/usr/bin/env python3
"""ceo-loop.py — ChumpOS CEO strategy-layer driver, v0 shadow shim (INFRA-3584).

SHADOW / DRY-RUN ONLY: this version NEVER executes the commands the CEO
routes. Each tick it (1) assembles live fleet state, (2) asks the model for
one decision object per docs/prompts/CEO_LOOP_PROMPT.md, (3) validates the
output against the contract + command policy, and (4) appends the full record
to the shadow decision log — the input to the AC-3 shadow-vs-ATC diff report.

Prompt is delivered to `claude -p` via STDIN, never argv — a prompt beginning
with `-` is parsed as CLI flags on the argv path (RESILIENT-314).

Rust port is planned per the INFRA-3584 description; this shim exists so the
3-day shadow clock starts before the port lands.

Env (registered in scripts/ci/env-vars-internal.txt):
  CHUMP_CEO_MODEL       model for the tick (default: sonnet)
  CHUMP_CEO_PROMPT      prompt path override (default: docs/prompts/CEO_LOOP_PROMPT.md)
  CHUMP_CEO_SHADOW_DIR  decision-log dir (default: ~/.chump/ceo-shadow)

Exit codes: 0 valid decision logged · 2 invalid decision logged · 3 model call failed.
"""
import argparse
import concurrent.futures
import json
import os
import pathlib
import re
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[2]
PROMPT_PATH = pathlib.Path(
    os.environ.get("CHUMP_CEO_PROMPT", REPO / "docs/prompts/CEO_LOOP_PROMPT.md")
)
SHADOW_DIR = pathlib.Path(
    os.environ.get("CHUMP_CEO_SHADOW_DIR", pathlib.Path.home() / ".chump/ceo-shadow")
)
MODEL = os.environ.get("CHUMP_CEO_MODEL", "sonnet")

TARGETS = {"ALMANAC", "GAP_REGISTRY", "DISPATCH", "CONSENSUS", "CONSULTANT", "OPERATOR"}
ACTIONS = {"query", "file_gap", "rate_gap", "decompose", "dispatch", "unstick",
           "propose", "vote", "request_inference", "board_update", "page"}
# Mirrors the CEO prompt's COMMAND PALETTE. A cmd matching no prefix is
# refused (logged, never run — moot in v0, load-bearing once execution lands).
ALLOW_PREFIXES = [
    "chump gap reserve", "chump gap set", "chump gap rate", "chump gap decompose",
    "chump gap show", "chump gap list", "chump gap preflight",
    "chump dispatch", "chump vote", "chump consensus", "chump outcome",
    "chump health",
    "scripts/coord/broadcast.sh", "scripts/coord/chump-inbox.sh",
    "scripts/dev/reality-check.sh", "scripts/coord/auth-status.sh",
    "scripts/dispatch/fleet-brief.sh",
    "git log", "git status", "git fetch", "tail",
    "almanac",
]
HARD_DENY = [
    (r"\brm\s", "rm"), (r"sed\s+-i", "sed -i"), (r"git\s+commit", "git commit"),
    (r"git\s+push", "git push"), (r"gh\s+pr\s+merge", "gh pr merge"),
    (r"gh\s+pr\s+create", "gh pr create"), (r"chump\s+fleet\s+stop", "fleet stop"),
    (r"chump\s+claim", "chump claim"), (r"launchctl", "launchctl"),
    (r"chmod", "chmod"), (r">>", "append-redirect"), (r"\s>\s", "redirect"),
    (r"--status\s+done", "status-done"), (r"\bcurl\b", "curl"), (r"\bwget\b", "wget"),
    (r"\btee\s", "tee"),
]
GAP_RE = re.compile(r"\b[A-Z]{2,}-\d{2,}\b")


def sh(cmd, timeout=20, cwd=None):
    """Run a read-only command; never raise — state assembly degrades gracefully."""
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                           timeout=timeout, cwd=str(cwd or REPO))
        out = (p.stdout or "").strip()
        return out if out else f"(empty, exit={p.returncode})"
    except Exception as e:  # noqa: BLE001 — any failure becomes visible state
        return f"(unavailable: {type(e).__name__})"


def assemble_state():
    sections = {
        "Ships (git log origin/main --since=3h)":
            "git log origin/main --since=3h --oneline | head -15",
        "Ambient tail (last 40 kinds, counted)":
            "tail -40 .chump-locks/ambient.jsonl | "
            "python3 -c 'import sys,json,collections\n"
            "c=collections.Counter()\n"
            "for l in sys.stdin:\n"
            " try: c[json.loads(l).get(\"kind\",\"?\")]+=1\n"
            " except Exception: pass\n"
            "print(\", \".join(f\"{k} x{v}\" for k,v in c.most_common(15)))'",
        "Open P0/P1 gaps":
            "sqlite3 -readonly .chump/state.db \"SELECT priority || ' ' || id || ' — ' || substr(title,1,90) "
            "FROM gaps WHERE status='open' AND priority IN ('P0','P1') "
            "ORDER BY priority, id LIMIT 15\"",
        "Outcomes": "chump outcome list 2>/dev/null | head -20",
        "Auth": "bash scripts/coord/auth-status.sh 2>&1 | head -2",
        "Inbox (unread, not advanced)":
            "bash scripts/coord/chump-inbox.sh read --no-advance 2>/dev/null | head -20",
    }
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        futs = {name: ex.submit(sh, cmd) for name, cmd in sections.items()}
        parts = [f"## {name}\n{futs[name].result()}" for name in sections]
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    return f"# LOOP STATE — {ts} (assembled by ceo-loop v0 shadow)\n\n" + "\n\n".join(parts)


def call_model(full_prompt):
    env = dict(os.environ)
    if not env.get("CLAUDE_CODE_OAUTH_TOKEN"):
        tok_file = pathlib.Path.home() / ".chump/oauth-token.json"
        try:
            env["CLAUDE_CODE_OAUTH_TOKEN"] = json.loads(tok_file.read_text())["token"]
        except Exception:  # noqa: BLE001 — fall through to claude's own auth
            pass
    try:
        # cwd = shadow dir: keeps repo SessionStart hooks out of the tick.
        p = subprocess.run(["claude", "-p", "--model", MODEL], input=full_prompt,
                           capture_output=True, text=True, timeout=420,
                           cwd=str(SHADOW_DIR), env=env)
        if p.returncode != 0:
            return None, f"claude exited {p.returncode}: {(p.stderr or p.stdout)[:400]}"
        return p.stdout.strip(), None
    except subprocess.TimeoutExpired:
        return None, "claude timed out (420s)"


def extract_json(text):
    for candidate in (text,):
        try:
            return json.loads(candidate)
        except Exception:  # noqa: BLE001
            pass
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    if m:
        try:
            return json.loads(m.group(1))
        except Exception:  # noqa: BLE001
            pass
    i, j = text.find("{"), text.rfind("}")
    if i >= 0 and j > i:
        try:
            return json.loads(text[i:j + 1])
        except Exception:  # noqa: BLE001
            pass
    return None


def known_gap_ids():
    try:
        return {p.stem for p in (REPO / "docs/gaps").glob("*.yaml")}
    except Exception:  # noqa: BLE001
        return set()


def validate(obj, state_text):
    checks = {"M1_parses": obj is not None}
    if obj is None:
        return checks
    ec = obj.get("executive_cognition", {}) or {}
    fr = ec.get("factory_report", {}) or {}
    sv = ec.get("strategic_vector", {}) or {}
    routing = obj.get("system_routing", [])
    checks["M2_schema"] = (
        obj.get("schema_version") == 1
        and all(k in fr for k in ("outcome_moved", "spine_stage", "honesty", "did_not_move"))
        and "synthesis" in ec and all(k in sv for k in ("outcome", "why_now"))
        and isinstance(routing, list) and len(routing) > 0
        and all(isinstance(r, dict) and "target" in r and "action" in r and "verify" in r
                for r in routing)
    )
    if not checks["M2_schema"]:
        return checks
    checks["M3_enums"] = all(
        r.get("target") in TARGETS and r.get("action") in ACTIONS for r in routing
    )
    pages = [r for r in routing if r.get("target") == "OPERATOR" and r.get("action") == "page"]
    checks["M4_page_gated"] = all(
        re.match(r"^T[1-4]", str(r.get("escalation_trigger", ""))) for r in pages
    )
    checks["page_count"] = len(pages)
    denies, unlisted = [], []
    for r in routing:
        cmd = str((r.get("payload") or {}).get("cmd", "")).strip()
        if not cmd or r.get("action") == "board_update":
            continue
        for pat, name in HARD_DENY:
            if re.search(pat, cmd):
                denies.append(f"{name}: {cmd[:90]}")
        bare = re.sub(r"^bash\s+", "", cmd)
        if not any(bare.startswith(p) for p in ALLOW_PREFIXES):
            unlisted.append(cmd[:90])
    checks["M5_denies"] = denies
    checks["M6_unlisted"] = unlisted
    cited = set(GAP_RE.findall(json.dumps(obj)))
    ok_ids = known_gap_ids() | set(GAP_RE.findall(state_text)) | set(GAP_RE.findall(PROMPT_PATH.read_text()))
    checks["M7_unknown_ids"] = sorted(cited - ok_ids)
    checks["valid"] = bool(
        checks["M1_parses"] and checks["M2_schema"] and checks["M3_enums"]
        and checks["M4_page_gated"] and not denies
    )
    return checks


def main():
    ap = argparse.ArgumentParser(description="CEO loop v0 — one shadow tick")
    ap.add_argument("--fixture", help="use a state-fixture file instead of live state")
    ap.add_argument("--state-only", action="store_true", help="print assembled state, no model call")
    ap.add_argument("--validate-only", help="validate a decision-JSON file, no model call (CI path)")
    args = ap.parse_args()

    SHADOW_DIR.mkdir(parents=True, exist_ok=True)

    if args.validate_only:
        obj = extract_json(pathlib.Path(args.validate_only).read_text())
        checks = validate(obj, "")
        print(json.dumps(checks, indent=2))
        return 0 if checks.get("valid") else 2

    state = pathlib.Path(args.fixture).read_text() if args.fixture else assemble_state()
    if args.state_only:
        print(state)
        return 0

    full = (PROMPT_PATH.read_text() + "\n\n---\n\n" + state +
            "\n\n---\nThis is one tick of your loop. Respond with ONLY the JSON object "
            "per your OUTPUT CONTRACT — no prose before or after.")
    out, err = call_model(full)
    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mode": "shadow-dry-run",
        "model": MODEL,
        "fixture": args.fixture or None,
        "prompt_sha256_file": str(PROMPT_PATH),
    }
    if out is None:
        record.update({"error": err, "valid": False})
        code = 3
    else:
        obj = extract_json(out)
        checks = validate(obj, state)
        record.update({"decision": obj if obj else out[:2000], "checks": checks,
                       "valid": bool(checks.get("valid"))})
        code = 0 if checks.get("valid") else 2
    with open(SHADOW_DIR / "decisions.jsonl", "a") as f:
        f.write(json.dumps(record) + "\n")
    summary = {k: record.get(k) for k in ("ts", "valid", "error") if k in record}
    if "checks" in record:
        summary["pages"] = record["checks"].get("page_count")
        summary["denies"] = record["checks"].get("M5_denies")
        summary["unlisted"] = record["checks"].get("M6_unlisted")
    print(json.dumps(summary))
    return code


if __name__ == "__main__":
    sys.exit(main())
