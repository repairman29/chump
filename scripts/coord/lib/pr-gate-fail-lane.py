#!/usr/bin/env python3
"""RESILIENT-1560: gate-fail fix-or-close lane for pr-shepherd-daemon.

stdin: `gh pr list --json` array (needs number,title,headRefOid,statusCheckRollup).
argv[1]: state file path. Env: CHUMP_GATE_FAIL_HOURS (2), CHUMP_GATE_FAIL_BLOCK_CYCLES (6),
CHUMP_GATE_FAIL_ALARM_THRESHOLD (3), CHUMP_GATE_FAIL_NOW (epoch override, tests).
stdout: one JSON action per line: {action: rerun|route_fix|block_gap|alarm, ...}.
"""
import json, os, re, sys, time

FLAKE_CONCLUSIONS = {"TIMED_OUT", "CANCELLED", "STARTUP_FAILURE"}
GAP_RE = re.compile(r"(?:INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|FLEET|DOC|MEM|VOA|SCALE|MISSION|ZERO-WASTE)-\d+")


def classify(failed):
    """failed: list of (name, conclusion). Deterministic unless every failure is infra-class."""
    if failed and all(c in FLAKE_CONCLUSIONS for _, c in failed):
        return "flake"
    return "deterministic"


def main():
    state_path = sys.argv[1]
    hours = float(os.environ.get("CHUMP_GATE_FAIL_HOURS", "2"))
    block_cycles = int(os.environ.get("CHUMP_GATE_FAIL_BLOCK_CYCLES", "6"))
    threshold = int(os.environ.get("CHUMP_GATE_FAIL_ALARM_THRESHOLD", "3"))
    now = float(os.environ.get("CHUMP_GATE_FAIL_NOW") or time.time())
    try:
        prs = json.load(sys.stdin)
    except Exception:
        prs = []
    try:
        state = json.load(open(state_path))
    except Exception:
        state = {}
    new_state = {}
    stuck = []
    for p in prs:
        checks = p.get("statusCheckRollup") or []
        failed = [((c.get("name") or c.get("context") or "?"), (c.get("conclusion") or "").upper())
                  for c in checks if (c.get("conclusion") or "").upper() in ({"FAILURE"} | FLAKE_CONCLUSIONS)]
        verified_failed = [f for f in failed if f[0].lower() == "verified"]
        if not verified_failed:
            continue
        key = "%s:%s" % (p["number"], p.get("headRefOid", ""))
        prev = state.get(key, {})
        ent = {"first_seen": prev.get("first_seen", now), "cycles": prev.get("cycles", 0),
               "reran": prev.get("reran", False), "routed": prev.get("routed", False),
               "blocked": prev.get("blocked", False)}
        new_state[key] = ent
        age_h = (now - ent["first_seen"]) / 3600.0
        if age_h < hours:
            continue
        kind = classify(failed)
        m = GAP_RE.search(p.get("title", ""))
        gap = m.group(0) if m else ""
        names = ",".join(n for n, _ in failed)
        stuck.append(p["number"])
        base = {"pr": p["number"], "gap_id": gap, "classification": kind,
                "age_hours": int(age_h), "failed_checks": names}
        if kind == "flake":
            if not ent["reran"]:
                ent["reran"] = True
                print(json.dumps(dict(base, action="rerun")))
            continue
        ent["cycles"] += 1
        if ent["cycles"] >= block_cycles and not ent["blocked"] and gap:
            ent["blocked"] = True
            print(json.dumps(dict(base, action="block_gap", cycles=ent["cycles"])))
        elif not ent["routed"] and gap:
            ent["routed"] = True
            print(json.dumps(dict(base, action="route_fix", cycles=ent["cycles"])))
    if len(stuck) > threshold:
        last = state.get("_alarm_ts", 0)
        if now - last >= 3600:
            new_state["_alarm_ts"] = now
            print(json.dumps({"action": "alarm", "count": len(stuck), "threshold": threshold, "prs": stuck}))
        else:
            new_state["_alarm_ts"] = last
    elif "_alarm_ts" in state:
        new_state["_alarm_ts"] = state["_alarm_ts"]
    tmp = state_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(new_state, f)
    os.replace(tmp, state_path)


if __name__ == "__main__":
    main()
