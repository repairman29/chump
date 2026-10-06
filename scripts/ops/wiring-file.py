#!/usr/bin/env python3
"""wiring-file — ZERO-WASTE-129 (ZERO-WASTE-036 slice).

Files ONE gap-with-receipt per real wiring finding, and makes a standing condition
update-not-refile.

Pipeline (each stage is its own tool):
  wiring-detectors.py  ->  wiring-triage.py  ->  wiring-file.py (this)

Input is wiring-triage output: JSONL findings carrying a `triage` decision. Only
ACTIONABLE ones are filed (WIRE / ARCHIVE-DEAD); ALLOWLIST-DORMANT items are never
filed (triage suppresses them; this refuses them too).

THE FILING PATH. Gaps are filed through the standard universal filer, `chump gap
file <finding.json>` (src/gap_file.rs) — the portable path that speaks the same
finding.json schema as the holler/file-finding convention (project, repo, title,
body, acceptance, priority) and spools + retries when the endpoint is down. Point
CHUMP_WIRING_FILER (or --filer-cmd) at a different filer (e.g. a holler wrapper)
to route elsewhere; it is called as `<filer> <finding.json>` and should print the
gap id on stdout.

STABLE DEDUPE HASH. Every filed finding carries `dedupe_hash`:
  wiring:<first 12 hex of sha256("detector|artifact|decision")>
It is derived ONLY from what identifies the standing condition — not from volatile
evidence (counts, ages, line numbers) — so the same condition hashes the same on
every cycle. The hash is also written into the gap body and a `[wiring:...]` tag in
the title. A local ledger (.chump-locks/wiring-filed.jsonl) maps hash -> gap, so a
re-detected condition UPDATES the ledger entry (last_seen, seen_count) instead of
filing again. A filer failure records nothing, so the next cycle retries.

Usage:
  wiring-triage.py | wiring-file.py [--ledger FILE] [--filer-cmd CMD] [--max-new N] [--dry-run]
  wiring-file.py --findings triaged.jsonl [...]
Exit: 0 ok; 2 bad usage.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

ACTIONABLE = {"WIRE", "ARCHIVE-DEAD"}
DEFAULT_LEDGER = ".chump-locks/wiring-filed.jsonl"
GAP_ID = re.compile(r"\b([A-Z][A-Z0-9-]*-\d+)\b")


def dedupe_hash(finding: dict) -> str:
    """Stable identity of the standing condition (detector + artifact + decision)."""
    key = "|".join([finding["detector"], finding["artifact"], finding["triage"]["decision"]])
    return "wiring:" + hashlib.sha256(key.encode()).hexdigest()[:12]


def priority(finding: dict) -> str:
    # Strong-detector WIRE is real work; everything else (weak detectors, dead-code cleanup) is P3.
    strong = finding["detector"] in ("D1", "D2", "D4")
    return "P2" if (strong and finding["triage"]["decision"] == "WIRE") else "P3"


def build_finding(f: dict, h: str) -> dict:
    t = f["triage"]
    decision = t["decision"]
    ev = json.dumps(f.get("evidence", {}), sort_keys=True)
    body = "\n".join([
        f"Wiring detector {f['detector']} ({f['name']}) flagged `{f['artifact']}`.",
        "",
        f"What was found: {f['detail']}.",
        f"Triage decision: **{decision}** — {t['why']}.",
        "",
        "Evidence receipt:",
        f"- detector: {f['detector']} / {f['name']} (severity {f.get('severity', '?')})",
        f"- artifact: {f['artifact']}",
        f"- evidence: {ev}",
        f"- triage: {json.dumps({k: v for k, v in t.items() if k not in ('decided_by', 'reason', 'decided_at')}, sort_keys=True)}",
        *( [f"- false-positive floor: {f['fp_floor']}"] if f.get("fp_floor") else [] ),
        "",
        f"Re-run: `scripts/ops/wiring-detectors.py --detector {f['detector']}` then `scripts/ops/wiring-triage.py`.",
        f"dedupe_hash: {h}",
    ])
    if decision == "WIRE":
        acceptance = [
            f"`{f['artifact']}` is connected to a scheduler, caller or consumer (or its intent comment is corrected), "
            f"and the {f['detector']} detector no longer flags it",
            f"or the decision is recorded with `scripts/ops/wiring-triage.py allow --artifact {f['artifact']} --detector {f['detector']} --by <who> --reason <why>`",
        ]
    else:
        acceptance = [
            f"`{f['artifact']}` is archived or removed, and the {f['detector']} detector no longer flags it",
            f"or the decision is recorded with `scripts/ops/wiring-triage.py allow --artifact {f['artifact']} --detector {f['detector']} --by <who> --reason <why>`",
        ]
    return {
        "project": "chump",
        "repo": "repairman29/chump",
        "title": f"Wiring: {f['name']} — {f['artifact']} [{h}]",
        "body": body,
        "acceptance": acceptance,
        "priority": priority(f),
        "dedupe_hash": h,
    }


def load_ledger(path: Path) -> dict[str, dict]:
    entries: dict[str, dict] = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            try:
                e = json.loads(line)
                entries[e["dedupe_hash"]] = e
            except (ValueError, KeyError):
                continue
    return entries


def save_ledger(path: Path, entries: dict[str, dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".jsonl.tmp")
    tmp.write_text("".join(json.dumps(entries[h], sort_keys=True) + "\n" for h in sorted(entries)))
    tmp.replace(path)


def run_filer(cmd: str, finding: dict) -> tuple[bool, str]:
    """Returns (filed_ok, gap_id_or_marker)."""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(finding, fh)
        path = fh.name
    try:
        r = subprocess.run([*shlex.split(cmd), path], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f"filer error: {e}"
    finally:
        os.unlink(path)
    if r.returncode != 0:
        return False, (r.stderr.strip() or f"filer exited {r.returncode}")[:200]
    m = GAP_ID.search(r.stdout)
    return True, (m.group(1) if m else "spooled")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--findings", default="-", help="triaged findings JSONL ('-' = stdin)")
    ap.add_argument("--ledger", default=DEFAULT_LEDGER)
    ap.add_argument("--filer-cmd", default=os.environ.get("CHUMP_WIRING_FILER", "chump gap file"))
    ap.add_argument("--max-new", type=int, default=10, help="cap on NEW gaps filed per run (flood guard)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--today", default="", help="YYYY-MM-DD (tests); default: today")
    a = ap.parse_args()

    text = sys.stdin.read() if a.findings == "-" else Path(a.findings).read_text()
    findings = [json.loads(l) for l in text.splitlines() if l.strip()]
    today = a.today or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    ledger_path = Path(a.ledger)
    ledger = load_ledger(ledger_path)

    filed = updated = skipped = failed = deferred = 0
    for f in findings:
        decision = (f.get("triage") or {}).get("decision")
        if decision not in ACTIONABLE:
            skipped += 1  # ALLOWLIST-DORMANT (or untriaged): never filed
            continue
        h = dedupe_hash(f)
        if h in ledger:  # standing condition: update, do not refile
            e = ledger[h]
            e["last_seen"] = today
            e["seen_count"] = int(e.get("seen_count", 1)) + 1
            updated += 1
            continue
        if filed >= a.max_new:
            deferred += 1
            continue
        finding = build_finding(f, h)
        if a.dry_run:
            print(f"[dry-run] would file {h} {finding['priority']} {finding['title']}")
            filed += 1
            continue
        ok, gap = run_filer(a.filer_cmd, finding)
        if not ok:
            failed += 1  # record nothing: the next cycle retries
            print(f"wiring-file: filing {h} failed: {gap}", file=sys.stderr)
            continue
        ledger[h] = {"dedupe_hash": h, "gap_id": gap, "detector": f["detector"], "artifact": f["artifact"],
                     "decision": decision, "first_seen": today, "last_seen": today, "seen_count": 1}
        filed += 1
        print(f"filed {h} -> {gap}  {f['artifact']}")
    if not a.dry_run:
        save_ledger(ledger_path, ledger)
    print(f"wiring-file: filed={filed} updated={updated} skipped(allowlisted/untriaged)={skipped} "
          f"failed={failed} deferred(max-new)={deferred}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
