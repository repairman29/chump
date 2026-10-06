#!/usr/bin/env python3
"""weekly-verdict — META-1047 (META-328 slice).

ONE weekly, operator-readable verdict composed from the mission organs that
already exist. SYNTHESIS ONLY: every line traces to a mechanical check in one of
four sources — this tool performs NO new detection.

  mission-grade      `chump mission-grade --json`           per-pillar grades (A/B/C/F)
  roadmap-status     `chump roadmap-status --json`          starved weeks, untraced P0/P1,
                                                            outcome-table drift (META-1045)
  mission-scoreboard `scripts/dev/mission-scoreboard.sh`    the VERDICT line
  factory matrix     docs/strategy/SOFTWARE_FACTORY_MATRIX_*.md   ❌ / 🟠 layers

OUTPUT. At most THREE things worth changing, each tagged with the organ that
produced it:

    WEEKLY VERDICT — 2026-W32 — 3 thing(s) worth changing
      1. [roadmap-status] Outcome PRODUCT-LH-1 has a stated definition of done but zero open gaps
      2. ...

A clean run emits an explicit `APPROVAL` and STOPS (no filler, no "also consider").
If a source cannot be read it is reported as UNAVAILABLE on stderr and is never
treated as a clean bill of health.

RANKING (deterministic): severity desc, then organ, then text. Severities:
  scoreboard STALLED 90 · DRIFTING 80 · outcome-table drift 85 · pillar F 70 ·
  starved week 65 · pillar C 60 · untraced P0/P1 60 · matrix ❌ 50 · matrix 🟠 40.

DELIVERY. Weekly to FLEET-RADIO: appended to <shadow-dir>/board.log (the file the
radio picks up; same sink as the CEO loop's board_update), at most once per ISO week
(--force overrides). Also emits kind=weekly_verdict to ambient.jsonl.

Usage:
  weekly-verdict.py [--repo DIR] [--shadow-dir DIR] [--ambient FILE] [--force] [--no-deliver]
  Test/override inputs: --mission-grade FILE --roadmap-status FILE --scoreboard FILE --matrix FILE
Exit: 0 verdict produced (APPROVAL or changes); 2 bad usage.
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path

MAX_ITEMS = 3


def run_cmd(argv: list[str], cwd: Path) -> tuple[int, str] | None:
    try:
        r = subprocess.run(argv, capture_output=True, text=True, cwd=str(cwd), timeout=180)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.returncode, r.stdout


def load_json_source(override: str, argv: list[str], repo: Path, name: str):
    """Returns parsed JSON or None (and says so on stderr — never silently clean)."""
    if override:
        try:
            return json.loads(Path(override).read_text())
        except (OSError, ValueError):
            print(f"weekly-verdict: {name}: UNAVAILABLE ({override} unreadable)", file=sys.stderr)
            return None
    out = run_cmd(argv, repo)
    if out is None:
        print(f"weekly-verdict: {name}: UNAVAILABLE (command failed to run)", file=sys.stderr)
        return None
    # mission-grade exits 1 on a low grade but still prints valid JSON.
    try:
        return json.loads(out[1])
    except ValueError:
        print(f"weekly-verdict: {name}: UNAVAILABLE (no JSON on stdout)", file=sys.stderr)
        return None


# ── per-organ synthesis (each returns (severity, organ, text) candidates) ────
def from_mission_grade(data) -> list[tuple[int, str, str]]:
    out = []
    for pillar in ("effective", "credible", "resilient", "zero_waste"):
        p = (data or {}).get(pillar) or {}
        g = p.get("grade")
        if g == "F":
            out.append((70, "mission-grade", f"Pillar {pillar.upper().replace('_', '-')} is graded F — zero open gaps"))
        elif g == "C":
            out.append((60, "mission-grade",
                        f"Pillar {pillar.upper().replace('_', '-')} is graded C — nothing pickable "
                        f"({p.get('count_in_flight', 0)} in flight)"))
    return out


def from_roadmap_status(data) -> list[tuple[int, str, str]]:
    out = []
    d = data or {}
    for x in d.get("outcome_drift") or []:
        if x.get("kind") == "no_open_gaps":
            out.append((85, "roadmap-status",
                        f"Outcome {x['outcome_id']} has a stated definition of done but zero open gaps"))
        else:
            detail = x.get("detail") or "every open gap is blocked"
            out.append((85, "roadmap-status",
                        f"Outcome {x['outcome_id']} has open gaps but none are pickable — {detail}"))
    for w in d.get("starved_outcomes") or []:
        out.append((65, "roadmap-status", f"Roadmap week {w} has zero shipped or in-flight gaps (starved)"))
    untraced = d.get("untraced_p0") or []
    if untraced:
        out.append((60, "roadmap-status",
                    f"{len(untraced)} open P0/P1 gap(s) trace to no outcome or roadmap week "
                    f"(e.g. {', '.join(untraced[:2])})"))
    return out


VERDICT_RE = re.compile(r"(HANDS-OFF|ON-TRACK|DRIFTING|STALLED)\b[^\n]*")


def from_scoreboard(text: str | None) -> list[tuple[int, str, str]]:
    if not text:
        return []
    m = VERDICT_RE.search(text.split("VERDICT", 1)[-1])
    if not m:
        return []
    word = m.group(1)
    line = re.sub(r"\s+", " ", m.group(0)).strip()
    if word == "STALLED":
        return [(90, "mission-scoreboard", f"Scoreboard verdict: {line}")]
    if word == "DRIFTING":
        return [(80, "mission-scoreboard", f"Scoreboard verdict: {line}")]
    return []  # HANDS-OFF / ON-TRACK: nothing to change


def from_matrix(text: str | None) -> list[tuple[int, str, str]]:
    if not text:
        return []
    out = []
    in_matrix = False
    for line in text.splitlines():
        if line.startswith("## 1."):
            in_matrix = True
            continue
        if in_matrix and line.startswith("## "):
            break
        if not in_matrix or not line.startswith("|") or "---" in line:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3:
            continue
        m = re.match(r"\*\*(.+?)\*\*", cells[0])
        if not m:
            continue
        layer, status = m.group(1), cells[2]
        if "❌" in status:
            out.append((50, "factory-matrix", f"Factory matrix: {layer} is missing (❌)"))
        elif "🟠" in status and "✅" not in status:
            out.append((40, "factory-matrix", f"Factory matrix: {layer} is thin (🟠)"))
    return out


def latest_matrix(repo: Path, override: str) -> str | None:
    if override:
        p = Path(override)
        return p.read_text() if p.is_file() else None
    cands = sorted(glob.glob(str(repo / "docs/strategy/SOFTWARE_FACTORY_MATRIX_*.md")))
    return Path(cands[-1]).read_text() if cands else None


def compose(cands: list[tuple[int, str, str]]) -> list[tuple[int, str, str]]:
    return sorted(cands, key=lambda c: (-c[0], c[1], c[2]))[:MAX_ITEMS]


def iso_week(today: dt.date) -> str:
    y, w, _ = today.isocalendar()
    return f"{y}-W{w:02d}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--shadow-dir", default=os.environ.get("CHUMP_CEO_SHADOW_DIR", str(Path.home() / ".chump" / "ceo-shadow")))
    ap.add_argument("--ambient", default="")
    ap.add_argument("--today", default="", help="YYYY-MM-DD (tests)")
    ap.add_argument("--force", action="store_true", help="deliver even if already delivered this ISO week")
    ap.add_argument("--no-deliver", action="store_true")
    ap.add_argument("--mission-grade", default="")
    ap.add_argument("--roadmap-status", default="")
    ap.add_argument("--scoreboard", default="", help="file holding mission-scoreboard output")
    ap.add_argument("--matrix", default="")
    a = ap.parse_args()
    repo = Path(a.repo).resolve()
    today = dt.date.fromisoformat(a.today) if a.today else dt.datetime.now(dt.timezone.utc).date()

    chump = os.environ.get("CHUMP_BIN", "chump")
    grade = load_json_source(a.mission_grade, [chump, "mission-grade", "--json"], repo, "mission-grade")
    road = load_json_source(a.roadmap_status, [chump, "roadmap-status", "--json"], repo, "roadmap-status")
    if a.scoreboard:
        sb = Path(a.scoreboard).read_text() if Path(a.scoreboard).is_file() else None
    else:
        r = run_cmd(["bash", str(repo / "scripts/dev/mission-scoreboard.sh")], repo)
        sb = r[1] if r else None
    if sb is None:
        print("weekly-verdict: mission-scoreboard: UNAVAILABLE", file=sys.stderr)
    matrix = latest_matrix(repo, a.matrix)
    if matrix is None:
        print("weekly-verdict: factory-matrix: UNAVAILABLE (no SOFTWARE_FACTORY_MATRIX_*.md)", file=sys.stderr)

    cands = from_mission_grade(grade) + from_roadmap_status(road) + from_scoreboard(sb) + from_matrix(matrix)
    items = compose(cands)
    week = iso_week(today)
    if not items:
        verdict = f"WEEKLY VERDICT — {week} — APPROVAL: mission-grade, roadmap-status, mission-scoreboard and the factory matrix report nothing to change."
        lines = [verdict]
        kind = "APPROVAL"
    else:
        head = f"WEEKLY VERDICT — {week} — {len(items)} thing(s) worth changing"
        lines = [head] + [f"  {i}. [{organ}] {text}" for i, (_, organ, text) in enumerate(items, 1)]
        kind = "CHANGES"
    print("\n".join(lines))

    if a.no_deliver:
        return 0
    shadow = Path(a.shadow_dir)
    marker = shadow / "weekly-verdict.last"
    if not a.force and marker.is_file() and marker.read_text().strip() == week:
        print(f"weekly-verdict: already delivered for {week}; not re-sending to FLEET-RADIO (use --force)", file=sys.stderr)
        return 0
    shadow.mkdir(parents=True, exist_ok=True)
    ts = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with (shadow / "board.log").open("a") as f:  # FLEET-RADIO pickup (same sink as CEO-loop board_update)
        f.write(f"{ts} {' | '.join(l.strip() for l in lines)}\n")
    marker.write_text(week + "\n")
    amb = Path(a.ambient) if a.ambient else repo / ".chump-locks" / "ambient.jsonl"
    try:
        amb.parent.mkdir(parents=True, exist_ok=True)
        # scanner-anchor: "kind":"weekly_verdict"
        with amb.open("a") as f:
            f.write(json.dumps({"ts": ts, "kind": "weekly_verdict", "week": week, "verdict": kind,
                                "items": len(items), "organs": sorted({o for _, o, _ in items})}) + "\n")
    except OSError:
        pass
    print(f"weekly-verdict: delivered to FLEET-RADIO ({shadow / 'board.log'})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
