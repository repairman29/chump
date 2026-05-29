#!/usr/bin/env python3
"""gen.py — generate realistic fixture data for fleet-scrubber dev/demo.

Emits ~20 segments across 3 sessions over a 2h window.
Run: python3 gen.py
Outputs: segments.json, events.json (in current directory).
"""

import json
import math
import os
import random
import time
from datetime import datetime, timezone, timedelta

random.seed(42)

NOW = datetime.now(timezone.utc)
WINDOW_START = NOW - timedelta(hours=2)

SESSIONS = [
    "opus-shepherd-abc12",
    "sonnet-worker-def34",
    "sonnet-worker-ghi56",
]

ACTIVITIES = ["claim", "edit", "push", "merge", "blocked", "idle"]

# Weights: editing is most common, merge is rare
WEIGHTS = [0.10, 0.40, 0.15, 0.08, 0.07, 0.20]


def rand_ts(base: datetime, max_offset_s: int = 7200) -> datetime:
    offset = random.uniform(0, max_offset_s)
    return base + timedelta(seconds=offset)


def fmt(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


segments = []
events = []

seg_id = 1
evt_id = 1

for session in SESSIONS:
    # Give each session a few gaps to work on
    gap_pool = [
        f"INFRA-{random.randint(2100, 2200)}" for _ in range(random.randint(2, 4))
    ]

    cursor = WINDOW_START + timedelta(seconds=random.uniform(0, 300))
    while cursor < NOW - timedelta(minutes=2):
        activity = random.choices(ACTIVITIES, weights=WEIGHTS, k=1)[0]
        gap_id = random.choice(gap_pool)

        # Duration varies by activity type
        dur_map = {
            "claim": (30, 90),
            "edit": (120, 900),
            "push": (20, 60),
            "merge": (10, 30),
            "blocked": (180, 1200),
            "idle": (60, 600),
        }
        lo, hi = dur_map[activity]
        duration_s = random.randint(lo, hi)

        seg_start = cursor
        seg_end = min(cursor + timedelta(seconds=duration_s), NOW - timedelta(seconds=5))

        seg = {
            "id": f"seg-{seg_id:04d}",
            "session_id": session,
            "activity": activity,
            "gap_id": gap_id if activity != "idle" else None,
            "start": fmt(seg_start),
            "end": fmt(seg_end),
            "duration_s": int((seg_end - seg_start).total_seconds()),
        }
        segments.append(seg)

        # Generate 1-5 events inside this segment
        n_events = random.randint(1, 5)
        for _ in range(n_events):
            evt_ts = seg_start + timedelta(
                seconds=random.uniform(
                    0, max(1, (seg_end - seg_start).total_seconds())
                )
            )
            sample_payloads = {
                "claim": {"action": "claimed", "gap_id": gap_id, "worktree": f"/tmp/chump-{gap_id.lower()}"},
                "edit": {"file": f"src/{random.choice(['main', 'lib', 'fleet', 'gap_store'])}.rs", "lines_changed": random.randint(1, 80)},
                "push": {"branch": f"chump/{gap_id.lower()}-impl", "sha": f"{random.randint(0, 0xffffff):06x}"},
                "merge": {"pr": random.randint(2500, 2700), "result": "merged"},
                "blocked": {"reason": random.choice(["ci_red", "merge_conflict", "rate_limit"]), "since": fmt(seg_start)},
                "idle": {"reason": "awaiting_input"},
            }
            evt = {
                "id": f"evt-{evt_id:05d}",
                "segment_id": seg["id"],
                "session_id": session,
                "ts": fmt(evt_ts),
                "kind": activity,
                "payload": sample_payloads.get(activity, {}),
            }
            events.append(evt)
            evt_id += 1

        seg_id += 1
        # Small gap between segments (0-30s idle between activities)
        cursor = seg_end + timedelta(seconds=random.uniform(0, 30))

# Sort by start time
segments.sort(key=lambda s: s["start"])
events.sort(key=lambda e: e["ts"])

out_dir = os.path.dirname(os.path.abspath(__file__))

with open(os.path.join(out_dir, "segments.json"), "w") as f:
    json.dump(segments, f, indent=2)
print(f"Wrote {len(segments)} segments to segments.json")

with open(os.path.join(out_dir, "events.json"), "w") as f:
    json.dump(events, f, indent=2)
print(f"Wrote {len(events)} events to events.json")
