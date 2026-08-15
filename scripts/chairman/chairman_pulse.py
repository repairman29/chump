#!/usr/bin/env python3
"""chairman_pulse.py — RESILIENT-331 aggregation engine for chairman-pulse.sh.

Reads .chump-locks/ambient.jsonl, sums each organ's structured per-cycle
outcome events into a power-output view, flags organs that ran but produced
zero power over N consecutive cycles ("zombie-alive"), and measures core-loop
throughput (gap claimed -> gap shipped) directly by pairing gap_id across
gap_claimed / gap_shipped events.

Exit codes: 0 normal, 2 when at least one organ was flagged zombie-alive this
run (chairman-pulse.sh's --fail-on-zombie translates this to exit 1).

# scanner-anchor: "kind":"chairman_pulse_tick"
# scanner-anchor: "kind":"organ_zombie_alive"
"""
import argparse
import datetime
import json
import sys


def parse_ts(ts):
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except Exception:
        return None


def numeric_power(obj, exclude_substr="skip"):
    """Sum numeric leaf values in a dict, skipping keys that look like a
    'skipped' counter (skipping isn't power output — it's an explicit no-op)."""
    total = 0
    if not isinstance(obj, dict):
        return 0
    for k, v in obj.items():
        if exclude_substr in k.lower():
            continue
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            total += v
        elif isinstance(v, dict):
            total += numeric_power(v, exclude_substr)
    return total


# organ extraction: kind -> (organ_name_fn(event), power_fn(event))
def organ_for(ev):
    kind = ev.get("kind", "")
    if kind == "reaper_run":
        return ev.get("reaper") or "unknown-reaper"
    if kind == "pr_lander_beat":
        return "pr-lander"
    if kind == "organ_watchdog_tick":
        return "organ-watchdog"
    if kind == "farmer_heartbeat":
        return "farmer"
    return None


def power_for(ev):
    kind = ev.get("kind", "")
    if kind == "reaper_run":
        return numeric_power(ev.get("counts", {}))
    if kind == "pr_lander_beat":
        return int(ev.get("armed", 0) or 0)
    if kind == "organ_watchdog_tick":
        return int(ev.get("healed", 0) or 0)
    if kind == "farmer_heartbeat":
        counts = ev.get("counts", {})
        return numeric_power(counts) if counts else 0
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ambient", required=True)
    ap.add_argument("--window-hours", type=float, default=24)
    ap.add_argument("--zombie-min-cycles", type=int, default=3)
    ap.add_argument("--json-out", type=int, default=0)
    ap.add_argument("--repo-root", default=".")
    args = ap.parse_args()

    now = datetime.datetime.now(datetime.timezone.utc)
    cutoff = now - datetime.timedelta(hours=args.window_hours)

    organs = {}  # name -> {"cycles": int, "power": int, "last_ts": str}
    claims = {}  # gap_id -> claimed_ts (first seen in window)
    ship_lat = []  # list of seconds (claim -> ship) for gaps with both events

    try:
        with open(args.ambient, "r", errors="replace") as f:
            lines = f.readlines()
    except OSError as e:
        print(f"[chairman-pulse] cannot read ambient log: {e}", file=sys.stderr)
        sys.exit(0)

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue

        ts = parse_ts(ev.get("ts", ""))
        if ts is None or ts < cutoff:
            continue

        organ = organ_for(ev)
        if organ is not None:
            rec = organs.setdefault(organ, {"cycles": 0, "power": 0, "last_ts": ""})
            rec["cycles"] += 1
            rec["power"] += power_for(ev)
            rec["last_ts"] = ev.get("ts", rec["last_ts"])

        kind = ev.get("kind", "")
        gap_id = ev.get("gap_id")
        if kind == "gap_claimed" and gap_id:
            claims[gap_id] = ts
        elif kind == "gap_shipped" and gap_id and gap_id in claims:
            delta = (ts - claims[gap_id]).total_seconds()
            if delta >= 0:
                ship_lat.append(delta)

    zombies = []
    report_rows = []
    for name, rec in sorted(organs.items()):
        cycles = rec["cycles"]
        power = rec["power"]
        is_zombie = cycles >= args.zombie_min_cycles and power == 0
        if is_zombie:
            zombies.append(name)
        report_rows.append(
            {
                "organ": name,
                "cycles": cycles,
                "power": power,
                "last_ts": rec["last_ts"],
                "zombie_alive": is_zombie,
            }
        )

    claimed_n = len(claims)
    shipped_n = len(ship_lat)
    median_s = None
    if ship_lat:
        s = sorted(ship_lat)
        mid = len(s) // 2
        median_s = s[mid] if len(s) % 2 else (s[mid - 1] + s[mid]) / 2

    result = {
        "window_hours": args.window_hours,
        "organs": report_rows,
        "core_loop": {
            "claimed": claimed_n,
            "shipped_and_matched": shipped_n,
            "median_claim_to_ship_seconds": median_s,
        },
        "zombie_alive": zombies,
    }

    if args.json_out:
        print(json.dumps(result, indent=2))
    else:
        print(f"=== chairman-pulse (window={args.window_hours}h) ===")
        print(f"{'ORGAN':<20}{'CYCLES':>8}{'POWER':>8}  LAST_TS")
        for row in report_rows:
            flag = "  <-- ZOMBIE-ALIVE (ran, 0 power)" if row["zombie_alive"] else ""
            print(
                f"{row['organ']:<20}{row['cycles']:>8}{row['power']:>8}  {row['last_ts']}{flag}"
            )
        print("--- core-loop throughput (direct, not proxied) ---")
        med = f"{median_s:.0f}s" if median_s is not None else "n/a"
        print(f"claimed={claimed_n} shipped_and_matched={shipped_n} median_claim_to_ship={med}")
        if zombies:
            print(f"ZOMBIE-ALIVE organs this window: {', '.join(zombies)}")
        else:
            print("no zombie-alive organs this window")

    # Emit ambient events so this readout is itself observable + queryable.
    ambient_path = args.ambient
    ts_now = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        with open(ambient_path, "a") as f:
            tick = {
                "ts": ts_now,
                "kind": "chairman_pulse_tick",
                "window_hours": args.window_hours,
                "organs_seen": len(report_rows),
                "zombie_count": len(zombies),
                "claimed": claimed_n,
                "shipped_and_matched": shipped_n,
            }
            f.write(json.dumps(tick, separators=(",", ":")) + "\n")
            for name in zombies:
                rec = organs[name]
                f.write(
                    json.dumps(
                        {
                            "ts": ts_now,
                            "kind": "organ_zombie_alive",
                            "organ": name,
                            "cycles": rec["cycles"],
                            "power": rec["power"],
                            "window_hours": args.window_hours,
                        },
                        separators=(",", ":"),
                    )
                    + "\n"
                )
    except OSError:
        pass

    sys.exit(2 if zombies else 0)


if __name__ == "__main__":
    main()
