#!/usr/bin/env python3
"""roadmap-drift.py — INFRA-1286 (META-065 layer 3).

Parses docs/ROADMAP.md milestone tables and cross-references them against
open P0/P1 gaps to detect strategic drift:
  - unanchored: an open P0/P1 gap ID that doesn't appear in any milestone's
    owning-gap list.
  - starving: a milestone whose owning-gap list has zero open P0/P1 gaps.

Usage:
    python3 roadmap-drift.py --roadmap docs/ROADMAP.md --gaps-json <(chump gap list --status open --json)

Reads gap JSON from --gaps-json (a path, or "-" for stdin). Prints a single
JSON object to stdout:
    {
      "milestones": [{"name":..., "status":..., "target_date":..., "owning_gap_ids":[...]}],
      "unanchored_gap_ids": [...],
      "starving_milestones": [...],
      "unanchored_count": N,
      "starving_milestone_count": N
    }

No side effects (no ambient emit, no gap filing) — that logic lives in the
bash caller (scripts/coord/opus-curator.sh) so dedup/rate-limiting stays in
one place.
"""
import argparse
import json
import re
import sys

GAP_ID_RE = re.compile(r"\b[A-Z][A-Z-]*-[0-9]+\b")


def _split_row(line):
    # Strip leading/trailing pipe, split on unescaped pipes.
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [c.strip() for c in line.split("|")]


def _is_separator_row(cells):
    # e.g. ["---", ":---:", "---"]
    return all(re.fullmatch(r":?-+:?", c) for c in cells if c != "")


def parse_roadmap(text):
    """Parse markdown tables whose header row names a milestone/phase column
    and a column that plausibly carries gap IDs (Umbrella/Owning/Gap)."""
    lines = text.splitlines()
    milestones = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip().startswith("|") and line.strip().endswith("|"):
            header_cells = _split_row(line)
            # Next line must be a separator row for this to be a real table.
            if i + 1 < len(lines) and lines[i + 1].strip().startswith("|"):
                sep_cells = _split_row(lines[i + 1])
                if _is_separator_row(sep_cells) and len(sep_cells) == len(header_cells):
                    name_idx = None
                    gap_idx = None
                    status_idx = None
                    date_idx = None
                    for idx, h in enumerate(header_cells):
                        hl = h.lower()
                        if name_idx is None and re.search(r"milestone|phase", hl):
                            name_idx = idx
                        if gap_idx is None and re.search(r"umbrella|owning|gap", hl):
                            gap_idx = idx
                        if status_idx is None and re.search(r"status|done|scoreboard", hl):
                            status_idx = idx
                        if date_idx is None and re.search(r"target|date", hl):
                            date_idx = idx
                    if name_idx is not None and gap_idx is not None:
                        j = i + 2
                        while j < len(lines) and lines[j].strip().startswith("|") and lines[j].strip().endswith("|"):
                            row_cells = _split_row(lines[j])
                            if len(row_cells) == len(header_cells) and not _is_separator_row(row_cells):
                                name = row_cells[name_idx].strip()
                                # Strip markdown bold/emphasis wrapping for readability.
                                name = re.sub(r"^\*+|\*+$", "", name).strip()
                                gap_ids = GAP_ID_RE.findall(row_cells[gap_idx])
                                status = row_cells[status_idx].strip() if status_idx is not None else ""
                                target_date = row_cells[date_idx].strip() if date_idx is not None else ""
                                if name and name.lower() not in ("", "---"):
                                    milestones.append({
                                        "name": name,
                                        "status": status,
                                        "target_date": target_date,
                                        "owning_gap_ids": gap_ids,
                                    })
                            j += 1
                        i = j
                        continue
        i += 1
    return milestones


def compute_drift(milestones, gaps):
    all_owned = set()
    for m in milestones:
        all_owned.update(m["owning_gap_ids"])

    p0_p1 = [g for g in gaps if g.get("priority") in ("P0", "P1") and g.get("id")]
    unanchored = sorted({g["id"] for g in p0_p1 if g["id"] not in all_owned})

    starving = []
    for m in milestones:
        if not m["owning_gap_ids"]:
            continue  # not an anchored milestone; not a "starving" claim
        has_progress = any(
            g["id"] in m["owning_gap_ids"] for g in p0_p1
        )
        if not has_progress:
            starving.append(m["name"])

    return {
        "milestones": milestones,
        "unanchored_gap_ids": unanchored,
        "starving_milestones": starving,
        "unanchored_count": len(unanchored),
        "starving_milestone_count": len(starving),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--roadmap", required=True)
    ap.add_argument("--gaps-json", required=True, help="path to gap-list JSON, or '-' for stdin")
    args = ap.parse_args()

    with open(args.roadmap, "r", encoding="utf-8") as f:
        roadmap_text = f.read()

    if args.gaps_json == "-":
        gaps_raw = sys.stdin.read()
    else:
        with open(args.gaps_json, "r", encoding="utf-8") as f:
            gaps_raw = f.read()

    try:
        gaps = json.loads(gaps_raw) if gaps_raw.strip() else []
    except json.JSONDecodeError:
        gaps = []

    milestones = parse_roadmap(roadmap_text)
    result = compute_drift(milestones, gaps)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
