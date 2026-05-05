#!/usr/bin/env python3
"""META-040: lesson-effectiveness audit.

Reads COG-043 telemetry events from ambient.jsonl (+ rotated archives)
and grades each directive by:

    adoption_rate = lesson_applied / (lesson_applied + lesson_not_applied)

Where the same directive appears in N >= 10 lessons_shown events but the
adoption rate is < 0.05, flag it as a "candidate for prune" — the agent
keeps being shown this lesson but rarely acts on it. The lesson is either
(a) genuinely irrelevant to recent gap classes, or (b) phrased in a way
the keyword-match grader can't detect adoption from.

Output:
  - stderr: human-readable scoreboard
  - ambient.jsonl: one summary event `kind=lessons_audit_run` plus one
    event per pruned directive `kind=lessons_pruned`
  - docs/eval/lesson-effectiveness-<date>.md: persistent report

Decision rule (locked):
  - n_shown >= 10 AND adoption_rate < 0.05  =>  prune candidate
  - n_shown >= 10 AND 0.05 <= adoption_rate < 0.20  =>  watch
  - n_shown >= 10 AND adoption_rate >= 0.20  =>  keep (effective)
  - n_shown < 10                              =>  insufficient_data

Run: scripts/eval/lesson-effectiveness-audit.py
Cron-friendly: idempotent, writes one report per (date, repo).

META-040 itself is just the audit. Acting on the prune candidates
(actually deleting low-adoption rows from chump_improvement_targets)
is a follow-up gap — the audit only EMITS the recommendation.
"""

from __future__ import annotations

import datetime
import gzip
import json
import os
import pathlib
import sys
from collections import defaultdict


def load_events(repo_root: pathlib.Path) -> list[dict]:
    """Yield all events from ambient.jsonl + rotated .gz archives."""
    out: list[dict] = []
    lock_dir = repo_root / ".chump-locks"
    live = lock_dir / "ambient.jsonl"
    if live.exists():
        for line in live.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except Exception:
                continue
    for archive in sorted(lock_dir.glob("ambient.jsonl.*.gz")):
        try:
            with gzip.open(archive, "rt", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        out.append(json.loads(line))
                    except Exception:
                        continue
        except Exception:
            continue
    return out


def audit(events: list[dict]) -> dict:
    """Compute per-directive scoreboard.

    Pairing model:
      - Each `lessons_shown` event lists 0..5 directives.
      - Each `lesson_applied` / `lesson_not_applied` event names ONE
        directive (the one being graded).
      - We count an "appearance" for a directive each time it's in a
        `lessons_shown` event. We count an "applied" each time a
        matching `lesson_applied` event names it.
      - Match is by exact directive string.
    """
    appearances: dict[str, int] = defaultdict(int)
    applied: dict[str, int] = defaultdict(int)
    not_applied: dict[str, int] = defaultdict(int)

    for ev in events:
        kind = ev.get("kind") or ev.get("event") or ""
        if kind == "lessons_shown":
            for d in ev.get("directives") or []:
                appearances[d] += 1
        elif kind == "lesson_applied":
            d = ev.get("directive") or ""
            if d:
                applied[d] += 1
        elif kind == "lesson_not_applied":
            d = ev.get("directive") or ""
            if d:
                not_applied[d] += 1

    rows = []
    for d, n_shown in appearances.items():
        a = applied.get(d, 0)
        na = not_applied.get(d, 0)
        graded = a + na
        adoption = (a / graded) if graded > 0 else None
        rows.append({
            "directive": d,
            "n_shown": n_shown,
            "n_applied": a,
            "n_not_applied": na,
            "n_graded": graded,
            "adoption_rate": adoption,
        })

    rows.sort(key=lambda r: (r["adoption_rate"] if r["adoption_rate"] is not None else 1.0, -r["n_shown"]))

    classified = {"prune": [], "watch": [], "keep": [], "insufficient_data": []}
    for r in rows:
        n = r["n_shown"]
        ar = r["adoption_rate"]
        if n < 10:
            classified["insufficient_data"].append(r)
        elif ar is None:
            # Shown but never graded — same as insufficient_data for now.
            classified["insufficient_data"].append(r)
        elif ar < 0.05:
            classified["prune"].append(r)
        elif ar < 0.20:
            classified["watch"].append(r)
        else:
            classified["keep"].append(r)
    return classified


def emit_summary(repo_root: pathlib.Path, classified: dict) -> None:
    """Append `lessons_audit_run` + per-prune `lessons_pruned` events."""
    ambient = repo_root / ".chump-locks" / "ambient.jsonl"
    ambient.parent.mkdir(parents=True, exist_ok=True)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    summary = {
        "event": "lessons_audit_run",
        "kind": "lessons_audit_run",
        "ts": ts,
        "n_keep": len(classified["keep"]),
        "n_watch": len(classified["watch"]),
        "n_prune_candidates": len(classified["prune"]),
        "n_insufficient_data": len(classified["insufficient_data"]),
    }
    with ambient.open("a") as f:
        f.write(json.dumps(summary) + "\n")
        for r in classified["prune"]:
            evt = {
                "event": "ALERT",
                "kind": "lessons_pruned",
                "ts": ts,
                "directive": r["directive"][:200],
                "n_shown": r["n_shown"],
                "adoption_rate": round(r["adoption_rate"] or 0.0, 3),
                "recommendation": "review_for_prune",
            }
            f.write(json.dumps(evt) + "\n")


def write_report(repo_root: pathlib.Path, classified: dict, out_path: pathlib.Path | None = None) -> pathlib.Path:
    if out_path is None:
        date = datetime.date.today().isoformat()
        out_path = repo_root / "docs" / "eval" / f"lesson-effectiveness-{date}.md"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    def fmt_row(r: dict) -> str:
        ar = r["adoption_rate"]
        ar_str = f"{ar*100:.1f}%" if ar is not None else "—"
        return f"| {ar_str} | {r['n_shown']} | {r['n_applied']} | {r['n_not_applied']} | {r['directive'][:120]} |"

    lines = [
        "# META-040: lesson-effectiveness audit",
        "",
        f"Generated: {datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')}Z",
        "",
        "Decision rule (locked):",
        "- n_shown ≥ 10 AND adoption_rate < 0.05  →  **prune candidate**",
        "- n_shown ≥ 10 AND 0.05 ≤ adoption < 0.20  →  watch",
        "- n_shown ≥ 10 AND adoption ≥ 0.20  →  keep",
        "- n_shown < 10  →  insufficient_data",
        "",
        f"## Counts: keep={len(classified['keep'])} watch={len(classified['watch'])} prune={len(classified['prune'])} insufficient={len(classified['insufficient_data'])}",
        "",
    ]

    for bucket in ("prune", "watch", "keep"):
        title = {"prune": "Prune candidates", "watch": "Watch list", "keep": "Effective lessons"}[bucket]
        rows = classified[bucket]
        lines.append(f"## {title} ({len(rows)})")
        lines.append("")
        if not rows:
            lines.append("_(none)_")
            lines.append("")
            continue
        lines.append("| Adoption | n_shown | n_applied | n_not_applied | Directive |")
        lines.append("|---------:|--------:|----------:|--------------:|-----------|")
        for r in rows[:50]:
            lines.append(fmt_row(r))
        if len(rows) > 50:
            lines.append(f"| … | … | … | … | _({len(rows)-50} more)_ |")
        lines.append("")

    insuf = classified["insufficient_data"]
    lines.append(f"## Insufficient data ({len(insuf)})")
    lines.append("")
    lines.append(f"_{len(insuf)} directives appeared in <10 lessons_shown events. Re-run after more usage accumulates._")
    lines.append("")

    out_path.write_text("\n".join(lines))
    return out_path


def main() -> int:
    repo_root = pathlib.Path(os.environ.get("CHUMP_REPO", "."))
    if not repo_root.is_absolute():
        try:
            import subprocess
            repo_root = pathlib.Path(
                subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
            )
        except Exception:
            pass

    events = load_events(repo_root)
    classified = audit(events)
    out_path = write_report(repo_root, classified)
    emit_summary(repo_root, classified)

    print(f"wrote {out_path}", file=sys.stderr)
    print(
        f"keep={len(classified['keep'])} watch={len(classified['watch'])} "
        f"prune_candidates={len(classified['prune'])} insufficient_data={len(classified['insufficient_data'])}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
