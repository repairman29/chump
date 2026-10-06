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

  cycle_kind_vs_pr_merged   (META-1049)
      The REPORTED cycle kind (e.g. "ship") vs whether the PR actually merged.
      DIVERGE = false-shipped (cycle claims a ship, PR is not merged) or
      false-unshipped (cycle claims no ship, PR merged).

  gap_done_vs_running_hash  (META-1049)
      A gap reported done vs whether its fix hash is actually RUNNING.
      DIVERGE = done-but-not-running (merged != running). A gap not reported done
      is not a lie, so it AGREEs.

  organ_active_vs_emitted_work  (META-1050)
      An organ's is-active status vs whether it actually EMITTED WORK in the
      window. DIVERGE = active-but-silent. A not-active organ is not claiming
      liveness, so it AGREEs.

  picker_offered_vs_preflight   (META-1050)
      Gaps the picker OFFERS vs a real preflight on each. DIVERGE = an offered
      gap that then fails preflight (the picker is advertising work no worker can
      start). One row per offered gap.

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
              "probe_cmd": "<cmd>", "probe_timeout_secs": 20}],
   "cycles": [{"id": "cycle-1",
               "kind": {"type": "file"|"command", ...},        # reported cycle kind
               "shipped_kinds": ["ship", "shipped", "merged"],  # kinds that claim a merge
               "pr_merged": {"type": "file"|"command", ...},    # ground truth, see below
               "merged_values": ["merged"], "not_merged_values": ["open", "closed"]}],
   "gaps":   [{"id": "GAP-1",
               "status": {"type": "file"|"command", ...},       # reported gap status
               "done_values": ["done", "closed", "shipped"],
               "fix_hash": {"type": "file"|"command", ...},     # the fix commit
               "running_hash": {"type": "file"|"command", ...}, # what is actually running
               "contains_cmd": "<cmd with {fix} {running}>"}],  # optional: exit 0 = running has fix
   "organs": [{"id": "organ-1",
               "active": {"type": "file"|"command", ...},       # prints e.g. "active"
               "active_values": ["active", "running"],
               "work": {"type": "ambient", "path": "...", "match": {"kind": "x"}, "window_secs": 3600}
                     | {"type": "command", "cmd": "<prints a count>"}}],
   "pickers": [{"id": "picker-1",
                "offered": {"type": "file"|"command", ...},     # gap ids, whitespace/newline or JSON list
                "preflight_cmd": "<cmd with {gap}>",            # exit 0 = preflight passes
                "preflight_timeout_secs": 60}]}

  organs.work (ambient): counts events whose fields equal every key in "match"
                    and whose ts is within window_secs of now; 0 events = silent.
  pickers: preflight_cmd exit 0 = pass; non-zero = fail; timeout/not-run = UNKNOWN.
  cycles.pr_merged: the source's text is matched against merged_values /
                    not_merged_values (default merged vs open/closed); anything else
                    is UNKNOWN.
  gaps running check: running_hash/fix_hash agree when one is a prefix of the other
                    (short vs full SHA), or when contains_cmd exits 0 (e.g. a
                    `git merge-base --is-ancestor {fix} {running}` wrapper).

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


# ── cycle_kind_vs_pr_merged / gap_done_vs_running_hash (META-1049) ───────────
def read_source(src: dict) -> str | None:
    """Text of a file/command source, or None when unavailable."""
    return reported_auth(src)


def check_cycles(cfg: dict) -> list[dict]:
    rows = []
    for c in cfg.get("cycles", []):
        cid = c["id"]
        kind_text = read_source(c.get("kind", {}))
        shipped_kinds = [k.lower() for k in c.get("shipped_kinds", ["ship", "shipped", "merged"])]
        merged_state = classify_merged(read_source(c.get("pr_merged", {})),
                                       c.get("merged_values", ["merged"]),
                                       c.get("not_merged_values", ["open", "closed"]))
        if kind_text is None or not kind_text.strip() or merged_state == "unknown":
            rows.append(verdict_row("cycle_kind_vs_pr_merged", cid,
                                    f"cycle kind {kind_text.strip() if kind_text and kind_text.strip() else 'unavailable'}",
                                    f"PR merge state {merged_state}", "UNKNOWN",
                                    "need both a cycle kind and a recognisable PR merge state"))
            continue
        kind = kind_text.strip().lower()
        claims_ship = kind in shipped_kinds
        sr, gt = f"cycle kind {kind}", f"PR {merged_state}"
        if claims_ship and merged_state == "not-merged":
            rows.append(verdict_row("cycle_kind_vs_pr_merged", cid, sr, gt, "DIVERGE",
                                    "false-shipped: the cycle reports a ship but the PR did not merge"))
        elif not claims_ship and merged_state == "merged":
            rows.append(verdict_row("cycle_kind_vs_pr_merged", cid, sr, gt, "DIVERGE",
                                    "false-unshipped: the PR merged but the cycle does not report a ship"))
        else:
            rows.append(verdict_row("cycle_kind_vs_pr_merged", cid, sr, gt, "AGREE",
                                    "cycle kind matches the PR outcome"))
    return rows


def classify_merged(text: str | None, merged_values: list[str], not_merged_values: list[str]) -> str:
    if text is None:
        return "unknown"
    t = text.strip().lower()
    if any(v.lower() in t for v in not_merged_values):
        return "not-merged"
    if any(v.lower() in t for v in merged_values):
        return "merged"
    return "unknown"


def hash_running(fix: str, running: str, contains_cmd: str) -> bool | None:
    """True/False when the fix is/isn't in what is running; None when unanswerable."""
    if contains_cmd:
        out = run_shell(contains_cmd.replace("{fix}", fix).replace("{running}", running), 20)
        return None if out is None else out[0] == 0
    return fix.startswith(running) or running.startswith(fix)


def check_gaps(cfg: dict) -> list[dict]:
    rows = []
    for g in cfg.get("gaps", []):
        gid = g["id"]
        status = (read_source(g.get("status", {})) or "").strip().lower()
        done_values = [v.lower() for v in g.get("done_values", ["done", "closed", "shipped"])]
        if not status:
            rows.append(verdict_row("gap_done_vs_running_hash", gid, "status unavailable", "-", "UNKNOWN",
                                    "no reported gap status"))
            continue
        if status not in done_values:
            rows.append(verdict_row("gap_done_vs_running_hash", gid, f"status {status}", "n/a (not reported done)",
                                    "AGREE", "not claimed done, so there is nothing to contradict"))
            continue
        fix = (read_source(g.get("fix_hash", {})) or "").strip()
        running = (read_source(g.get("running_hash", {})) or "").strip()
        if not fix or not running:
            rows.append(verdict_row("gap_done_vs_running_hash", gid, "status done",
                                    f"fix {fix[:12] or 'unavailable'}, running {running[:12] or 'unavailable'}", "UNKNOWN",
                                    "need both the fix hash and the running hash"))
            continue
        is_running = hash_running(fix, running, g.get("contains_cmd", ""))
        gt = f"fix {fix[:12]}, running {running[:12]}"
        if is_running is None:
            rows.append(verdict_row("gap_done_vs_running_hash", gid, "status done", gt, "UNKNOWN",
                                    "could not determine whether the running build contains the fix"))
        elif is_running:
            rows.append(verdict_row("gap_done_vs_running_hash", gid, "status done", gt, "AGREE",
                                    "the fix is what is running"))
        else:
            rows.append(verdict_row("gap_done_vs_running_hash", gid, "status done", gt, "DIVERGE",
                                    "done-but-not-running: merged != running"))
    return rows


# ── organ_active_vs_emitted_work / picker_offered_vs_preflight (META-1050) ───
def work_count(src: dict, now: float) -> int | None:
    kind = (src or {}).get("type")
    if kind == "command":
        out = run_shell(src.get("cmd", ""), int(src.get("timeout_secs", 20)))
        if not out or out[0] != 0:
            return None
        try:
            return int(out[1].strip())
        except ValueError:
            return None
    if kind == "ambient":
        match = src.get("match", {})
        window = float(src.get("window_secs", 3600))
        n = 0
        try:
            lines = Path(src["path"]).read_text(errors="replace").splitlines()
        except (OSError, KeyError):
            return None
        for line in lines:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if not isinstance(ev, dict) or any(ev.get(k) != v for k, v in match.items()):
                continue
            ts = parse_ts(str(ev.get("ts", "")))
            if ts is not None and now - window <= ts <= now:
                n += 1
        return n
    return None


def check_organs(cfg: dict, now: float) -> list[dict]:
    rows = []
    for o in cfg.get("organs", []):
        oid = o["id"]
        text = read_source(o.get("active", {}))
        active_values = [v.lower() for v in o.get("active_values", ["active"])]
        n = work_count(o.get("work", {}), now)
        window = int((o.get("work") or {}).get("window_secs", 3600))
        if text is None or not text.strip() or n is None:
            rows.append(verdict_row("organ_active_vs_emitted_work", oid,
                                    f"status {text.strip() if text and text.strip() else 'unavailable'}",
                                    "emitted work unavailable" if n is None else f"{n} work event(s)", "UNKNOWN",
                                    "need both the organ's is-active status and a work count"))
            continue
        active = text.strip().lower() in active_values
        sr, gt = ("active" if active else f"not active ({text.strip().lower()})"), f"{n} work event(s) in {fmt_age(window)}"
        if active and n == 0:
            rows.append(verdict_row("organ_active_vs_emitted_work", oid, sr, gt, "DIVERGE",
                                    "active-but-silent: reported active yet emitted no work in the window"))
        elif active:
            rows.append(verdict_row("organ_active_vs_emitted_work", oid, sr, gt, "AGREE",
                                    "active and emitting work"))
        else:
            rows.append(verdict_row("organ_active_vs_emitted_work", oid, sr, gt, "AGREE",
                                    "not claimed active, so silence is expected"))
    return rows


def offered_gaps(src: dict) -> list[str] | None:
    text = read_source(src)
    if text is None:
        return None
    t = text.strip()
    if t.startswith("["):
        try:
            return [str(x) for x in json.loads(t)]
        except ValueError:
            return None
    return t.split()


def check_pickers(cfg: dict) -> list[dict]:
    rows = []
    for p in cfg.get("pickers", []):
        pid = p["id"]
        offered = offered_gaps(p.get("offered", {}))
        cmd = p.get("preflight_cmd", "")
        if offered is None or not cmd:
            rows.append(verdict_row("picker_offered_vs_preflight", pid, "offered list unavailable" if offered is None else "offered",
                                    "no preflight command" if not cmd else "-", "UNKNOWN",
                                    "need both the offered gaps and a preflight command"))
            continue
        for gap in offered:
            res = run_shell(cmd.replace("{gap}", gap), int(p.get("preflight_timeout_secs", 60)))
            target = f"{pid}:{gap}"
            if res is None:
                rows.append(verdict_row("picker_offered_vs_preflight", target, "offered by picker",
                                        "preflight did not run", "UNKNOWN", "preflight timed out or could not start"))
            elif res[0] == 0:
                rows.append(verdict_row("picker_offered_vs_preflight", target, "offered by picker",
                                        "preflight passes", "AGREE", "offered gap is startable"))
            else:
                rows.append(verdict_row("picker_offered_vs_preflight", target, "offered by picker",
                                        f"preflight fails (exit {res[0]})", "DIVERGE",
                                        "offered gap fails preflight: the picker advertises work no worker can start"))
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=os.environ.get("CHUMP_STATE_AUDIT_CONFIG", ""))
    ap.add_argument("--check", default="all", choices=["nodes", "auth", "cycles", "gaps", "organs", "pickers", "all"])
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
    if a.check in ("cycles", "all"):
        rows += check_cycles(cfg)
    if a.check in ("gaps", "all"):
        rows += check_gaps(cfg)
    if a.check in ("organs", "all"):
        rows += check_organs(cfg, now)
    if a.check in ("pickers", "all"):
        rows += check_pickers(cfg)
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
