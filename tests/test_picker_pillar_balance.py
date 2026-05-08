#!/usr/bin/env python3
"""Tests for INFRA-720: pillar-aware picker bias (4h rolling window, pillar_imbalance alerts)."""

import json
import os
import sys
import tempfile
import time
from pathlib import Path

# Add scripts/dispatch to path so we can import the picker.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "dispatch"))

from _pick_and_claim_gap import (
    extract_pillar,
    get_pillar_distribution_4h,
    get_under_represented_pillars,
    detect_and_emit_pillar_imbalance,
)


def create_session_end_event(gap_id: str, title: str, offset_seconds: int = 0) -> dict:
    """Create a session_end event with the given gap_id and title.

    offset_seconds: how many seconds ago the event occurred (default: now).
    """
    ts = int(time.time()) - offset_seconds
    ts_str = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))
    return {
        "ts": ts_str,
        "kind": "session_end",
        "outcome": "shipped",
        "gap_id": gap_id,
        "gap_title": title,
    }


def test_extract_pillar():
    """Test pillar extraction from gap titles."""
    assert extract_pillar("EFFECTIVE: foo bar") == "EFFECTIVE"
    assert extract_pillar("CREDIBLE: baz") == "CREDIBLE"
    assert extract_pillar("RESILIENT: qux") == "RESILIENT"
    assert extract_pillar("ZERO-WASTE: fix") == "ZERO-WASTE"
    assert extract_pillar("MISSION: task") == "MISSION"
    assert extract_pillar("something without tag") == ""
    assert extract_pillar("  EFFECTIVE: indented") == "EFFECTIVE"
    print("✓ test_extract_pillar passed")


def test_pillar_distribution_4h():
    """Test reading pillar distribution from ambient.jsonl (4h window)."""
    with tempfile.TemporaryDirectory() as tmpdir:
        ambient_path = os.path.join(tmpdir, "ambient.jsonl")

        # Create ambient.jsonl with mixed pillar events.
        now = int(time.time())
        events = [
            # Within 4h: 3 EFFECTIVE, 2 CREDIBLE, 1 RESILIENT
            create_session_end_event("GAP-1", "EFFECTIVE: foo", 0),
            create_session_end_event("GAP-2", "EFFECTIVE: bar", 600),
            create_session_end_event("GAP-3", "EFFECTIVE: baz", 1200),
            create_session_end_event("GAP-4", "CREDIBLE: qux", 1800),
            create_session_end_event("GAP-5", "CREDIBLE: xyz", 2400),
            create_session_end_event("GAP-6", "RESILIENT: abc", 3000),
            # Outside 4h: should be ignored
            create_session_end_event("GAP-7", "MISSION: old", 4 * 3600 + 100),
        ]

        with open(ambient_path, "w") as f:
            for event in events:
                f.write(json.dumps(event) + "\n")

        counts, percentages = get_pillar_distribution_4h(ambient_path)

        # Should count 6 events within 4h window.
        assert counts["EFFECTIVE"] == 3, f"Expected 3 EFFECTIVE, got {counts['EFFECTIVE']}"
        assert counts["CREDIBLE"] == 2, f"Expected 2 CREDIBLE, got {counts['CREDIBLE']}"
        assert counts["RESILIENT"] == 1, f"Expected 1 RESILIENT, got {counts['RESILIENT']}"
        assert counts["ZERO-WASTE"] == 0
        assert counts["MISSION"] == 0

        # Check percentages (3/6, 2/6, 1/6, 0/6, 0/6).
        assert abs(percentages["EFFECTIVE"] - 50.0) < 0.1
        assert abs(percentages["CREDIBLE"] - 33.3) < 0.1
        assert abs(percentages["RESILIENT"] - 16.7) < 0.1

        print("✓ test_pillar_distribution_4h passed")


def test_under_represented_pillars():
    """Test detection of under-represented pillars."""
    # Case 1: balanced distribution (no pillar under 20%).
    balanced = {
        "EFFECTIVE": 25.0,
        "CREDIBLE": 25.0,
        "RESILIENT": 25.0,
        "ZERO-WASTE": 25.0,
        "MISSION": 0.0,
    }
    under = get_under_represented_pillars(balanced, threshold=20)
    assert "MISSION" in under, "MISSION (0%) should be under-represented"
    assert "EFFECTIVE" not in under

    # Case 2: 100% RESILIENT (AC test case).
    all_resilient = {
        "EFFECTIVE": 0.0,
        "CREDIBLE": 0.0,
        "RESILIENT": 100.0,
        "ZERO-WASTE": 0.0,
        "MISSION": 0.0,
    }
    under = get_under_represented_pillars(all_resilient, threshold=20)
    # EFFECTIVE, CREDIBLE, ZERO-WASTE, MISSION should all be < 20%.
    assert "EFFECTIVE" in under
    assert "CREDIBLE" in under
    assert "ZERO-WASTE" in under
    assert "MISSION" in under
    assert "RESILIENT" not in under

    print("✓ test_under_represented_pillars passed")


def test_pillar_imbalance_alert():
    """Test pillar_imbalance alert detection and emission."""
    with tempfile.TemporaryDirectory() as tmpdir:
        ambient_path = os.path.join(tmpdir, "ambient.jsonl")

        # Create ambient.jsonl with 80% RESILIENT (> 60% threshold).
        now = int(time.time())
        events = [
            create_session_end_event("GAP-1", "RESILIENT: fix1", 0),
            create_session_end_event("GAP-2", "RESILIENT: fix2", 300),
            create_session_end_event("GAP-3", "RESILIENT: fix3", 600),
            create_session_end_event("GAP-4", "RESILIENT: fix4", 900),
            create_session_end_event("GAP-5", "EFFECTIVE: feat", 1200),
        ]

        with open(ambient_path, "w") as f:
            for event in events:
                f.write(json.dumps(event) + "\n")

        # Call detect_and_emit_pillar_imbalance.
        detect_and_emit_pillar_imbalance(ambient_path)

        # Check if pillar_imbalance alert was emitted.
        with open(ambient_path) as f:
            events = [json.loads(line) for line in f]

        # Find the pillar_imbalance alert (it should exist).
        alert = None
        for event in events:
            if event.get("kind") == "pillar_imbalance":
                alert = event
                break

        assert alert is not None, "No pillar_imbalance alert found in ambient.jsonl"
        assert alert["dominant_pillar"] == "RESILIENT"
        assert alert["percentage"] > 60.0

        print("✓ test_pillar_imbalance_alert passed")


def test_100_percent_resilient_prefers_other_pillars():
    """Test AC: synth 100% RESILIENT history, assert next pick prefers EFFECTIVE/CREDIBLE/MISSION."""
    with tempfile.TemporaryDirectory() as tmpdir:
        ambient_path = os.path.join(tmpdir, "ambient.jsonl")

        # Create ambient.jsonl with 100% RESILIENT events (10 shipped gaps, all RESILIENT).
        now = int(time.time())
        events = []
        for i in range(10):
            offset = i * 300
            events.append(
                create_session_end_event(f"GAP-{i}", f"RESILIENT: fix{i}", offset)
            )

        with open(ambient_path, "w") as f:
            for event in events:
                f.write(json.dumps(event) + "\n")

        # Get pillar distribution.
        counts, percentages = get_pillar_distribution_4h(ambient_path)

        # Verify: RESILIENT is 100%, all others are 0%.
        assert counts["RESILIENT"] == 10
        assert counts["EFFECTIVE"] == 0
        assert counts["CREDIBLE"] == 0
        assert counts["ZERO-WASTE"] == 0
        assert counts["MISSION"] == 0

        # Get under-represented pillars (threshold 20%).
        under = get_under_represented_pillars(percentages, threshold=20)

        # All non-RESILIENT pillars should be under-represented.
        assert "EFFECTIVE" in under, "EFFECTIVE should be under-represented"
        assert "CREDIBLE" in under, "CREDIBLE should be under-represented"
        assert "ZERO-WASTE" in under, "ZERO-WASTE should be under-represented"
        assert "MISSION" in under, "MISSION should be under-represented"
        assert "RESILIENT" not in under, "RESILIENT should NOT be under-represented"

        print("✓ test_100_percent_resilient_prefers_other_pillars passed")


if __name__ == "__main__":
    test_extract_pillar()
    test_pillar_distribution_4h()
    test_under_represented_pillars()
    test_pillar_imbalance_alert()
    test_100_percent_resilient_prefers_other_pillars()
    print("\n✅ All INFRA-720 tests passed!")
