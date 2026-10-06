#!/usr/bin/env python3
"""state-audit-checks — META-1051 (META-1030 slice).

Two deterministic self-report-vs-ground-truth checks for the state-audit family.
Each compares what the fleet CLAIMS against one cheap piece of GROUND TRUTH and
prints one glanceable line:

    check | self_report | ground_truth | AGREE|DIVERGE|UNKNOWN

  node_last_seen_vs_expected_up
      A node's last-seen time vs its expected-up schedule. DIVERGE = silent while
      expected up (silence longer than max_silence_secs inside an expected-up
      window). Silence OUTSIDE an expected-up window is fine (AGREE).

  auth_status_vs_probe
      The REPORTED auth status vs a real minimal auth probe. DIVERGE = false-ok
      (reported ok, probe says dead) or false-dead (reported dead, probe says alive).

A check that cannot get ground truth reports UNKNOWN — never a false AGREE.

HOST-AGNOSTIC. Nothing about any node or credential is hard-coded: targets come
from a JSON config (--config, or $CHUMP_STATE_AUDIT_CONFIG). See
scripts/coord/state-audit-targets.example.json for the shape:

  {"nodes": [{"id": "node-a",
              "last_seen": {"type": "file"|"ambient"|"command", ...},
              "expected_up": {"always": true}
                          | {"windows": [{"days": ["mon","tue"], "start": "08:00", "end": "18:00"}]},
              "max_silence_secs": 1800}],
   "auth":  [{"id": "oauth-primary",
              "status": {"type": "file"|"command", ...},   # prints/contains the reported status
              "ok_values": ["ok","live"], "dead_values": ["dead","expired"],
              "probe_cmd": "<cmd>", "probe_timeout_secs": 20}]}

  last_seen sources:  file    {"path"}                       -> file mtime
                      ambient {"path","node_field"?,"node_value"?} -> newest event ts for that node
                      command {"cmd"}                        -> prints epoch seconds or ISO-8601
  status sources:     file    {"path"}                       -> file contents
                      command {"cmd"}                        -> stdout
  probe_cmd: exit 0 = auth alive, non-zero = dead, timeout/not-run = UNKNOWN.
  Commands run via `bash -c` from the repo root; they are YOUR config, not user input.

Usage:
  state-audit-checks.py --config FILE [--check nodes|auth|all] [--now ISO|EPOCH] [--json] [--strict]
Exit: 0 (always, unless --strict: 1 when any DIVERGE); 2 on bad usage/config.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path

DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


# ── helpers ──────────────────────────────────────────────────────────────────
def parse_ts(text: str) -> float | None:
    t = text.strip()
    if not t:
        return None
    try:
        return float(t)
    except ValueError:
        pass
    try:
        return dt.datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def run_shell(cmd: str, timeout: int) -> tuple[int, str] | None:
    try:
        r = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.returncode, r.stdout


def verdict_row(check: str, target: str, self_report: str, ground_truth: str, verdict: str, detail: str = "") -> dict:
    return {"check": check, "target": target, "self_report": self_report, "ground_truth": ground_truth,
            "verdict": verdict, "detail": detail}


# ── node_last_seen_vs_expected_up ────────────────────────────────────────────
def expected_up(spec: dict, now: float) -> bool:
    if not spec or spec.get("always"):
        return True
    when = dt.datetime.fromtimestamp(now, dt.timezone.utc)
    for w in spec.get("windows", []):
        days = [d.lower()[:3] for d in w.get("days", DAYS)]
        if DAYS[when.weekday()] not in days:
            continue
        hhmm = when.strftime("%H:%M")
        start, end = w.get("start", "00:00"), w.get("end", "24:00")
        if start <= hhmm < end or (end == "24:00" and hhmm >= start):
            return True
    return False


def last_seen(src: dict, node_id: str) -> float | None:
    kind = (src or {}).get("type")
    if kind == "file":
        try:
            return Path(src["path"]).stat().st_mtime
        except (OSError, KeyError):
            return None
    if kind == "command":
        out = run_shell(src.get("cmd", ""), int(src.get("timeout_secs", 20)))
        return parse_ts(out[1]) if out and out[0] == 0 else None
    if kind == "ambient":
        field = src.get("node_field", "node")
        want = src.get("node_value", node_id)
        newest = None
        try:
            for line in Path(src["path"]).read_text(errors="replace").splitlines():
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if isinstance(ev, dict) and ev.get(field) == want:
                    ts = parse_ts(str(ev.get("ts", "")))
                    if ts is not None and (newest is None or ts > newest):
                        newest = ts
        except (OSError, KeyError):
            return None
        return newest
    return None


def fmt_age(secs: float) -> str:
    s = int(secs)
    return f"{s // 3600}h{(s % 3600) // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"


def check_nodes(cfg: dict, now: float) -> list[dict]:
    rows = []
    for n in cfg.get("nodes", []):
        nid = n["id"]
        max_silence = float(n.get("max_silence_secs", 1800))
        exp = expected_up(n.get("expected_up", {"always": True}), now)
        seen = last_seen(n.get("last_seen", {}), nid)
        if seen is None:
            rows.append(verdict_row("node_last_seen_vs_expected_up", nid,
                                    f"expected-up={'yes' if exp else 'no'}", "last-seen unavailable", "UNKNOWN",
                                    "no ground truth for last-seen; refusing to call this AGREE"))
            continue
        age = max(0.0, now - seen)
        gt = f"last seen {fmt_age(age)} ago"
        if not exp:
            rows.append(verdict_row("node_last_seen_vs_expected_up", nid, "not expected up now", gt, "AGREE",
                                    "outside its expected-up window; silence is expected"))
        elif age <= max_silence:
            rows.append(verdict_row("node_last_seen_vs_expected_up", nid, "expected up", gt, "AGREE",
                                    f"within {fmt_age(max_silence)} silence budget"))
        else:
            rows.append(verdict_row("node_last_seen_vs_expected_up", nid, "expected up", gt, "DIVERGE",
                                    f"silent while expected up: {fmt_age(age)} > {fmt_age(max_silence)} budget"))
    return rows


# ── auth_status_vs_probe ─────────────────────────────────────────────────────
def reported_auth(src: dict) -> str | None:
    kind = (src or {}).get("type")
    if kind == "file":
        try:
            return Path(src["path"]).read_text(errors="replace")
        except (OSError, KeyError):
            return None
    if kind == "command":
        out = run_shell(src.get("cmd", ""), int(src.get("timeout_secs", 20)))
        return out[1] if out else None
    return None


def classify(text: str | None, ok_values: list[str], dead_values: list[str]) -> str:
    if text is None:
        return "unknown"
    t = text.strip().lower()
    if any(v.lower() in t for v in dead_values):
        return "dead"
    if any(v.lower() in t for v in ok_values):
        return "ok"
    return "unknown"


def check_auth(cfg: dict) -> list[dict]:
    rows = []
    for a in cfg.get("auth", []):
        aid = a["id"]
        reported = classify(reported_auth(a.get("status", {})), a.get("ok_values", ["ok"]), a.get("dead_values", ["dead"]))
        probe_cmd = a.get("probe_cmd", "")
        probe = run_shell(probe_cmd, int(a.get("probe_timeout_secs", 20))) if probe_cmd else None
        truth = "unknown" if probe is None else ("alive" if probe[0] == 0 else "dead")
        sr, gt = f"reported {reported}", f"probe says {truth}"
        if reported == "unknown" or truth == "unknown":
            rows.append(verdict_row("auth_status_vs_probe", aid, sr, gt, "UNKNOWN",
                                    "need both a recognisable reported status and a probe result"))
        elif reported == "ok" and truth == "dead":
            rows.append(verdict_row("auth_status_vs_probe", aid, sr, gt, "DIVERGE",
                                    "false-ok: auth is reported healthy but the real probe fails"))
        elif reported == "dead" and truth == "alive":
            rows.append(verdict_row("auth_status_vs_probe", aid, sr, gt, "DIVERGE",
                                    "false-dead: auth is reported dead but the real probe succeeds"))
        else:
            rows.append(verdict_row("auth_status_vs_probe", aid, sr, gt, "AGREE", "report matches the probe"))
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=os.environ.get("CHUMP_STATE_AUDIT_CONFIG", ""))
    ap.add_argument("--check", default="all", choices=["nodes", "auth", "all"])
    ap.add_argument("--now", default="", help="ISO-8601 or epoch seconds (tests); default: now")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--strict", action="store_true", help="exit 1 when any check DIVERGEs")
    a = ap.parse_args()
    if not a.config:
        print("state-audit-checks: no config. Pass --config FILE or set CHUMP_STATE_AUDIT_CONFIG "
              "(see scripts/coord/state-audit-targets.example.json). Targets are never hard-coded.", file=sys.stderr)
        return 2
    try:
        cfg = json.loads(Path(a.config).read_text())
    except (OSError, ValueError) as e:
        print(f"state-audit-checks: cannot read config {a.config}: {e}", file=sys.stderr)
        return 2
    now = (parse_ts(a.now) if a.now else None) or dt.datetime.now(dt.timezone.utc).timestamp()

    rows: list[dict] = []
    if a.check in ("nodes", "all"):
        rows += check_nodes(cfg, now)
    if a.check in ("auth", "all"):
        rows += check_auth(cfg)
    if a.json:
        for r in rows:
            print(json.dumps(r, sort_keys=True))
    else:
        for r in rows:
            print(f"{r['check']}[{r['target']}] | {r['self_report']} | {r['ground_truth']} | {r['verdict']}")
            if r["verdict"] != "AGREE":
                print(f"    {r['detail']}")
    diverged = sum(1 for r in rows if r["verdict"] == "DIVERGE")
    unknown = sum(1 for r in rows if r["verdict"] == "UNKNOWN")
    print(f"state-audit-checks: {len(rows)} check(s): {diverged} DIVERGE, {unknown} UNKNOWN", file=sys.stderr)
    return 1 if (a.strict and diverged) else 0


if __name__ == "__main__":
    sys.exit(main())
