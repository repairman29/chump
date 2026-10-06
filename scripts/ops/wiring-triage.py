#!/usr/bin/env python3
"""wiring-triage — ZERO-WASTE-128 (ZERO-WASTE-036 slice).

Turns a wiring-detector finding (scripts/ops/wiring-detectors.py) into exactly ONE
decision, and remembers deliberate "leave it alone" calls so a re-scan stays quiet:

  WIRE               alive and wanted — it declares intent (or is referenced / was
                     touched recently) but nothing connects it. Action: wire it.
  ALLOWLIST-DORMANT  deliberately dormant. Recorded in the reasoned allowlist with
                     WHO decided and WHY; later scans do not re-flag it.
  ARCHIVE-DEAD       no live reference anywhere AND untouched for DEAD_DAYS. Action:
                     archive/delete it.

Decision order (first match wins, so a finding gets exactly one decision):
  1. an allowlist entry matches (artifact + detector)   -> ALLOWLIST-DORMANT
  2. zero references outside itself AND last commit older
     than --dead-days (default 90)                       -> ARCHIVE-DEAD
  3. otherwise                                           -> WIRE

The allowlist is JSONL (docs/process/wiring-allowlist.jsonl), one entry per line:
  {"artifact","detector","decided_by","reason","decided_at"}
`decided_by` and `reason` are REQUIRED — an allowlist entry with no owner or no
reason is exactly the silent-dormancy this exists to prevent.

Usage:
  wiring-triage.py [--repo DIR] [--findings FILE|-] [--allowlist FILE]
                   [--dead-days N] [--now EPOCH] [--show-allowlisted] [--out FILE]
      Triage findings (default: run wiring-detectors on --repo). Prints JSONL
      {finding..., "triage": {...}} for the ACTIONABLE ones (WIRE / ARCHIVE-DEAD);
      ALLOWLIST-DORMANT items are suppressed (counted on stderr) unless
      --show-allowlisted.
  wiring-triage.py allow --artifact A --detector D1 --by WHO --reason TEXT [...]
      Append a reasoned allowlist entry.
Exit: 0 ok; 2 bad usage / invalid allowlist entry.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

DECISIONS = ("WIRE", "ALLOWLIST-DORMANT", "ARCHIVE-DEAD")
DEFAULT_ALLOWLIST = "docs/process/wiring-allowlist.jsonl"
SKIP_DIRS = {".git", "target", "node_modules", "vendor", "dist", "build", "__pycache__", ".chump-locks"}


def load_allowlist(path: Path) -> list[dict]:
    entries = []
    if not path.is_file():
        return entries
    for n, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            e = json.loads(line)
        except ValueError:
            print(f"wiring-triage: {path}:{n}: not valid JSON — ignored", file=sys.stderr)
            continue
        if not (str(e.get("decided_by", "")).strip() and str(e.get("reason", "")).strip() and e.get("artifact")):
            # An entry without an owner or a reason is not a decision; do NOT honor it.
            print(f"wiring-triage: {path}:{n}: allowlist entry needs artifact, decided_by and reason — ignored", file=sys.stderr)
            continue
        entries.append(e)
    return entries


def allowlist_match(entries: list[dict], finding: dict) -> dict | None:
    for e in entries:
        if e["artifact"] == finding.get("artifact") and e.get("detector") in (None, "", finding.get("detector")):
            return e
    return None


def file_part(artifact: str) -> str:
    """`path::Symbol` / `path::Struct.field` -> `path`."""
    return artifact.split("::", 1)[0]


def count_references(repo: Path, artifact: str) -> int:
    """Lines OUTSIDE the artifact's own file that mention its basename (or, for a
    symbol artifact, the symbol)."""
    f = file_part(artifact)
    needle = Path(f).name
    if "::" in artifact:
        needle = re.split(r"[.]", artifact.split("::", 1)[1])[0]
    own = (repo / f).resolve()
    n = 0
    for dirpath, dirnames, filenames in os.walk(repo):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            p = Path(dirpath) / fn
            try:
                if p.resolve() == own or p.name == "wiring-allowlist.jsonl" or p.stat().st_size > 1_000_000:
                    continue  # the allowlist naming an artifact is not a use of it
                text = p.read_text(errors="ignore")
            except OSError:
                continue
            if needle in text:
                n += text.count(needle)
    return n


def last_commit_age_days(repo: Path, artifact: str, now: int) -> float | None:
    out = subprocess.run(
        ["git", "-C", str(repo), "log", "-1", "--format=%ct", "--", file_part(artifact)],
        capture_output=True, text=True,
    )
    ts = out.stdout.strip()
    if out.returncode != 0 or not ts.isdigit():
        return None  # untracked / no history: unknown, never "dead"
    return max(0.0, (now - int(ts)) / 86400)


def triage_one(finding: dict, repo: Path, allow: list[dict], dead_days: int, now: int) -> dict:
    hit = allowlist_match(allow, finding)
    if hit:
        return {"decision": "ALLOWLIST-DORMANT",
                "why": "deliberately dormant — recorded in the reasoned allowlist",
                "decided_by": hit["decided_by"], "reason": hit["reason"],
                "decided_at": hit.get("decided_at")}
    refs = count_references(repo, finding["artifact"])
    age = last_commit_age_days(repo, finding["artifact"], now)
    if refs == 0 and age is not None and age >= dead_days:
        return {"decision": "ARCHIVE-DEAD",
                "why": f"no references outside itself and untouched for {int(age)} days (>= {dead_days})",
                "references": refs, "last_commit_age_days": round(age, 1)}
    return {"decision": "WIRE",
            "why": "alive (referenced or recently touched) but not connected" if (refs or (age is not None and age < dead_days))
                   else "age unknown; defaulting to wire rather than deleting on missing evidence",
            "references": refs, "last_commit_age_days": None if age is None else round(age, 1)}


def cmd_allow(a) -> int:
    for field in ("artifact", "by", "reason"):
        if not str(getattr(a, field) or "").strip():
            print(f"wiring-triage allow: --{field.replace('by', 'by')} is required and must be non-empty", file=sys.stderr)
            return 2
    path = Path(a.repo) / (a.allowlist or DEFAULT_ALLOWLIST)
    existing = load_allowlist(path)
    if any(e["artifact"] == a.artifact and e.get("detector") in (None, "", a.detector or None) for e in existing):
        print(f"wiring-triage allow: {a.artifact} is already allowlisted", file=sys.stderr)
        return 2
    path.parent.mkdir(parents=True, exist_ok=True)
    entry = {"artifact": a.artifact, "detector": a.detector or "", "decided_by": a.by.strip(),
             "reason": a.reason.strip(), "decided_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")}
    with path.open("a") as f:
        f.write(json.dumps(entry, sort_keys=True) + "\n")
    print(f"allowlisted {a.artifact} (by {entry['decided_by']}): {entry['reason']}")
    return 0


def read_findings(a) -> list[dict]:
    if a.findings:
        text = sys.stdin.read() if a.findings == "-" else Path(a.findings).read_text()
    else:
        det = Path(__file__).with_name("wiring-detectors.py")
        r = subprocess.run([sys.executable, str(det), "--repo", a.repo], capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            raise SystemExit(2)
        text = r.stdout
    return [json.loads(l) for l in text.splitlines() if l.strip()]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    al = sub.add_parser("allow", help="append a reasoned allowlist entry")
    al.add_argument("--repo", default=".")
    al.add_argument("--allowlist", default="")
    al.add_argument("--artifact", default="")
    al.add_argument("--detector", default="")
    al.add_argument("--by", default="")
    al.add_argument("--reason", default="")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--findings", default="", help="findings JSONL ('-' = stdin); default: run wiring-detectors")
    ap.add_argument("--allowlist", default="")
    ap.add_argument("--dead-days", type=int, default=90)
    ap.add_argument("--now", type=int, default=0, help="epoch seconds (tests); default: now")
    ap.add_argument("--show-allowlisted", action="store_true")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    if a.cmd == "allow":
        return cmd_allow(a)

    repo = Path(a.repo).resolve()
    now = a.now or int(dt.datetime.now(dt.timezone.utc).timestamp())
    allow = load_allowlist(repo / (a.allowlist or DEFAULT_ALLOWLIST))
    findings = read_findings(a)
    counts = {d: 0 for d in DECISIONS}
    out_rows = []
    for f in findings:
        t = triage_one(f, repo, allow, a.dead_days, now)
        assert t["decision"] in DECISIONS  # exactly one of the three, by construction
        counts[t["decision"]] += 1
        if t["decision"] == "ALLOWLIST-DORMANT" and not a.show_allowlisted:
            continue
        out_rows.append({**f, "triage": t})
    lines = "\n".join(json.dumps(r, sort_keys=True) for r in out_rows)
    if a.out:
        Path(a.out).write_text(lines + ("\n" if lines else ""))
    elif lines:
        print(lines)
    print("wiring-triage: " + "  ".join(f"{d}={counts[d]}" for d in DECISIONS)
          + f"  (of {len(findings)} findings; allowlisted ones are suppressed from output)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
