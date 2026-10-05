#!/usr/bin/env python3
"""EFFECTIVE-441: persistent per-gap unverified_ship attempt counter + escalation.

The per-worker cooldown files written by worker.sh on `kind=unverified_ship`
(FLEET-051 pattern, one file per ${AGENT_ID}-${GAP_ID}) only ever backed off
the NEXT pick for one worker — they carry no memory of how many times, in
total, the gap has been claimed + worked + returned rc=0 with no ship
evidence. That let RESILIENT-354-class loops recur: agent-2 re-picked the
same unverified_ship gap at cycle 130 AND 135, five cycles apart, with no
ship in between, burning inference indefinitely.

This module tracks a single monotonic counter per gap_id (independent of
which worker attempted it) and turns it into a three-way decision:

    none      count < escalate_n           — first attempts, just cool down
    escalate  escalate_n <= count < park_m — bump model tier + cluster cooldown
    park      count >= park_m              — take the gap out of the open pool

`park` is intentionally terminal via caller action (the caller flips the
gap's status away from "open"), which stops the counter from growing further
because the picker never selects a non-open gap again.
"""
import argparse
import os
import sys


def counter_path(cooldown_dir: str, gap_id: str) -> str:
    return os.path.join(cooldown_dir, f"unverified-count-{gap_id}.txt")


def read_count(cooldown_dir: str, gap_id: str) -> int:
    path = counter_path(cooldown_dir, gap_id)
    try:
        with open(path, "r") as f:
            return int(f.read().strip() or "0")
    except (FileNotFoundError, ValueError):
        return 0


def record_attempt(cooldown_dir: str, gap_id: str) -> int:
    """Increment and persist the counter, returning the new value."""
    os.makedirs(cooldown_dir, exist_ok=True)
    count = read_count(cooldown_dir, gap_id) + 1
    path = counter_path(cooldown_dir, gap_id)
    tmp_path = path + ".tmp"
    with open(tmp_path, "w") as f:
        f.write(str(count))
    os.replace(tmp_path, path)
    return count


def clear_count(cooldown_dir: str, gap_id: str) -> None:
    try:
        os.remove(counter_path(cooldown_dir, gap_id))
    except FileNotFoundError:
        pass


def decide_action(count: int, escalate_n: int, park_m: int) -> str:
    if count >= park_m:
        return "park"
    if count >= escalate_n:
        return "escalate"
    return "none"


def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    rec = sub.add_parser("record", help="increment the counter and print '<count> <action>'")
    rec.add_argument("cooldown_dir")
    rec.add_argument("gap_id")
    rec.add_argument("--escalate-n", type=int, default=3)
    rec.add_argument("--park-m", type=int, default=6)

    show = sub.add_parser("show", help="print the current count without incrementing")
    show.add_argument("cooldown_dir")
    show.add_argument("gap_id")

    clr = sub.add_parser("clear", help="reset the counter (e.g. on a verified ship)")
    clr.add_argument("cooldown_dir")
    clr.add_argument("gap_id")

    args = p.parse_args(argv)

    if args.cmd == "record":
        count = record_attempt(args.cooldown_dir, args.gap_id)
        action = decide_action(count, args.escalate_n, args.park_m)
        print(f"{count} {action}")
        return 0
    if args.cmd == "show":
        print(read_count(args.cooldown_dir, args.gap_id))
        return 0
    if args.cmd == "clear":
        clear_count(args.cooldown_dir, args.gap_id)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
