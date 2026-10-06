#!/usr/bin/env python3
"""wiring-detectors — ZERO-WASTE-126 (ZERO-WASTE-036 slice).

The three STRONG "built but not wired" detectors — intent-without-invocation:
a thing declares that it should run, and nothing makes it run.

  D1 no-scheduler
     A script whose header declares PERIODIC intent ("every 10 min", "hourly",
     "runs from a timer", "cron"...) but that NO scheduler artifact references:
     not a launchd .plist, systemd .timer/.service, a crontab/organ-manifest
     entry, a scheduled workflow, nor (transitively) a script that is itself
     scheduled. Self-looping daemons (`while true`) are excluded — they are
     launched, not scheduled.

  D2 never-invoked-on-documented-input
     A script whose own usage text documents a flag/input (`--drain`,
     `--apply` ...) that appears in NO invocation anywhere else in the repo
     (scripts, workflows, tests). The tool is run, but never against the input
     its --help advertises. Only INVOCATION corpora count (scripts, CI, source);
     prose docs that merely describe the flag do not.

  D4 no-execution-telemetry
     A REQUIRED checklist (a markdown task list or table under a heading that says
     required / mandatory / must pass, or an item marked REQUIRED/MANDATORY) whose
     runner script (named in the item, or in the doc's "Run with:" preamble) emits
     no ambient telemetry and never appears in the ambient log — the checklist
     says "do this", and nothing can ever show that it was done.

Each finding is one machine-readable JSON record (JSONL):
  {"detector","name","severity","artifact","detail","evidence":{...}}

These are SUSPECT detectors, not verdicts: every finding names its evidence so a
human can confirm in two minutes. Purely static, no network, deterministic.

Usage:
  scripts/ops/wiring-detectors.py [--repo DIR] [--detector D1,D2,D4]
                                  [--ambient FILE] [--out FILE] [--summary]
Exit: 0 always (findings are data); 2 on bad usage.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

SKIP_DIRS = {".git", "target", "node_modules", "vendor", "dist", "build", "__pycache__", ".chump-locks"}
SCRIPT_EXTS = {".sh", ".bash", ".py"}
SKIP_CORPUS_EXTS = {".sql", ".json", ".lock", ".db", ".csv", ".jsonl", ".svg", ".png", ".gz"}
# Files that SCHEDULE things (D1's "is it wired to a scheduler" corpus).
SCHEDULER_EXTS = {".plist", ".timer", ".service"}
SCHEDULER_WORDS = re.compile(r"crontab|StartInterval|StartCalendarInterval|OnCalendar|OnUnitActiveSec|OnBootSec|schedule:\s*$|cron:", re.M)

PERIODIC = re.compile(
    r"(every\s+(~?\d+\s*)(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)\b"
    r"|\b(hourly|nightly|periodic(ally)?)\b"
    r"|\b(runs?|run|fires?|invoked|called)\s+(on|via|from|by|as)\s+(a\s+|the\s+)?(timer|cron|schedule|launchd|systemd)"
    r"|\b(cron|launchd|systemd)[ -](job|timer|entry|beat|schedule)"
    r"|recommended cron)",
    re.I,
)


def walk(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for fn in sorted(filenames):
            yield Path(dirpath) / fn


def read(p: Path) -> str:
    try:
        return p.read_text(errors="replace")
    except OSError:
        return ""


def rel(root: Path, p: Path) -> str:
    return str(p.relative_to(root))


def header_comment(text: str, max_lines: int = 70) -> str:
    """Leading comment block of a script (skipping the shebang)."""
    out = []
    for line in text.splitlines()[:max_lines]:
        s = line.strip()
        if s.startswith("#!") and not out:
            continue
        if s.startswith("#"):
            out.append(s.lstrip("#").strip())
        elif s == "" and not out:
            continue
        elif s.startswith('"""') or s.startswith("'''"):
            out.append(s.strip("\"'"))
        elif out:
            break
    return "\n".join(out)


def is_test_or_archived(root: Path, p: Path) -> bool:
    """Tests describe OTHER things' schedules/flags; archived scripts are retired on purpose."""
    r = rel(root, p)
    return p.name.startswith("test-") or "/archived/" in r or "/tests/" in r


def finding(detector, name, severity, artifact, detail, evidence):
    return {"detector": detector, "name": name, "severity": severity,
            "artifact": artifact, "detail": detail, "evidence": evidence}


class Repo:
    def __init__(self, root: Path):
        self.root = root
        self.files = [p for p in walk(root) if p.is_file()]
        self.text = {p: read(p) for p in self.files if p.stat().st_size < 2_000_000}
        self.scripts = [p for p in self.files if p.suffix in SCRIPT_EXTS and rel(root, p).startswith("scripts/")]
        self._by_name: dict[str, list[Path]] = {}
        for sp in self.scripts:
            self._by_name.setdefault(sp.name, []).append(sp)
        self._mentions: dict[Path, list[tuple[Path, int]]] | None = None

    def mentions(self) -> dict[Path, list[tuple[Path, int]]]:
        """script -> [(file, line_no)] of every line (outside itself) naming its basename.
        One pass over the corpus: tokenize each line into candidate script filenames and
        look them up in a dict (not scripts x files, not a giant alternation)."""
        if self._mentions is None:
            tok = re.compile(r"[\w.+-]+\.(?:sh|py|bash)\b")
            m: dict[Path, list[tuple[Path, int]]] = {sp: [] for sp in self.scripts}
            for p, t in self.text.items():
                if p.suffix in SKIP_CORPUS_EXTS or len(t) > 400_000 or "\x00" in t[:512]:
                    continue
                for i, line in enumerate(t.splitlines()):
                    if ".sh" not in line and ".py" not in line and ".bash" not in line:
                        continue
                    for name in set(tok.findall(line)):
                        for sp in self._by_name.get(name, ()):
                            if sp != p:
                                m[sp].append((p, i))
            self._mentions = m
        return self._mentions


# ── D1 ──────────────────────────────────────────────────────────────────────
def d1_no_scheduler(repo: Repo):
    root = repo.root
    mentions = repo.mentions()
    sched_files = set()
    for p in repo.files:
        t = repo.text.get(p, "")
        r = rel(root, p)
        if p.suffix in SCHEDULER_EXTS or "organ-manifest" in p.name:
            sched_files.add(p)
        elif p.suffix in {".yml", ".yaml", ".txt", ".sh"} and not r.startswith("docs/gaps/") and SCHEDULER_WORDS.search(t):
            sched_files.add(p)
    scheduled = {sp for sp in repo.scripts if any(f in sched_files for f, _ in mentions[sp])}
    # transitive: a script referenced by a scheduled script is scheduled too
    changed = True
    while changed:
        changed = False
        for sp in repo.scripts:
            if sp not in scheduled and any(f in scheduled for f, _ in mentions[sp]):
                scheduled.add(sp)
                changed = True
    out = []
    for sp in repo.scripts:
        if is_test_or_archived(root, sp):
            continue
        t = repo.text.get(sp, "")
        m = PERIODIC.search(header_comment(t))
        if not m or sp in scheduled:
            continue
        if re.search(r"^\s*while\s+(true|:)\b", t, re.M):
            continue  # self-looping daemon: launched, not scheduled
        out.append(finding(
            "D1", "no-scheduler", "med", rel(root, sp),
            "declares periodic intent but no cron/launchd/systemd/workflow entry references it",
            {"intent_phrase": m.group(0).strip(), "scheduler_files_checked": len(sched_files)},
        ))
    return out


# ── D2 ──────────────────────────────────────────────────────────────────────
# A documented INPUT: a flag followed by a value placeholder (<x>, ALLCAPS, =, FILE/PATH...).
VALUE_FLAG = re.compile(r"(?<![\w-])(--[a-z][a-z0-9-]{2,})(?:=|\s+(?:<[^>]+>|[A-Z][A-Z0-9_]{1,}\b))")


def usage_inputs(text: str) -> list[str]:
    """Value-taking flags named in the script's own usage text."""
    chunks = [header_comment(text)]
    for m in re.finditer(r"(?im)^\s*(?:echo\s+\"?)?usage:?.*$", text):
        chunks.append(m.group(0))
    seen, out = set(), []
    for c in chunks:
        for f in VALUE_FLAG.findall(c):
            if f not in seen and f not in {"--help", "--version"}:
                seen.add(f)
                out.append(f)
    return out


def d2_never_invoked(repo: Repo):
    root = repo.root
    mentions = repo.mentions()
    out = []
    for sp in repo.scripts:
        if is_test_or_archived(root, sp):
            continue
        inputs = usage_inputs(repo.text.get(sp, ""))
        if not inputs:
            continue
        sites = [(f, i) for f, i in mentions[sp] if not rel(root, f).startswith("docs/")]
        if not sites:
            continue  # never invoked at all: the dormant-script detector's job, not D2's
        blocks = []
        for f, i in sites:
            lines = repo.text.get(f, "").splitlines()
            blocks.append("\n".join(lines[max(0, i - 1): i + 4]))
        blob = "\n".join(blocks)
        missing = [f for f in inputs if f not in blob]
        # strong core: NONE of the documented inputs is ever passed anywhere
        if len(missing) == len(inputs):
            out.append(finding(
                "D2", "never-invoked-on-documented-input", "low", rel(root, sp),
                "documents input(s) in its usage text that no invocation in the repo ever passes",
                {"documented_inputs": inputs, "never_invoked_with": missing, "invocation_sites": len(sites)},
            ))
    return out


# ── D4 ──────────────────────────────────────────────────────────────────────
ITEM = re.compile(r"^\s*(?:[-*]\s+\[[ xX]\]\s+|\|\s*)(.*)$")
SCRIPT_REF = re.compile(r"(?:\./)?(scripts/[\w./-]+\.(?:sh|py))")
# Heading-level "this list is mandatory" markers; an item can also self-declare REQUIRED/MANDATORY.
REQUIRED_HEADING = re.compile(r"\b(must pass|mandatory)\b|\((required|mandatory)\)|\[(required|mandatory)\b|required (checklist|items?)", re.I)
REQUIRED = re.compile(r"\b(REQUIRED|MANDATORY)\b")
TELEMETRY = re.compile(r"ambient-emit|ambient\.jsonl|emit_event|emit_ambient|_ambient_write|ambient_emit|\"kind\"\s*:|\bkind=", re.I)


def d4_no_telemetry(repo: Repo, ambient: str):
    root = repo.root
    out, seen = [], set()
    for p in repo.files:
        r = rel(root, p)
        if p.suffix != ".md" or r.startswith("docs/gaps/"):
            continue
        lines = repo.text.get(p, "").splitlines()
        preamble = "\n".join(lines[:30])
        heading, required, items = "", False, []
        sections = []
        for line in lines + ["# <end>"]:
            if line.startswith("#"):
                if required and items:
                    sections.append((heading, items))
                heading, required, items = line.lstrip("# ").strip(), bool(REQUIRED_HEADING.search(line)), []
                continue
            m = ITEM.match(line)
            if m and (line.lstrip().startswith(("-", "*", "|"))):
                body = m.group(1)
                if set(body.strip()) <= set("-:| "):
                    continue  # table separator row
                if required or REQUIRED.search(body):
                    items.append(body.strip())
        for heading, items in sections:
            runners = []
            for it in items:
                runners += SCRIPT_REF.findall(it)
            if not runners:
                runners = SCRIPT_REF.findall(preamble)  # "Run with:" line
            for ref in dict.fromkeys(runners):
                key = (r, heading, ref)
                sp = root / ref
                if key in seen or not sp.is_file():
                    continue
                seen.add(key)
                stext = repo.text.get(sp, read(sp))
                if TELEMETRY.search(stext) or sp.name in ambient:
                    continue
                out.append(finding(
                    "D4", "no-execution-telemetry", "med", ref,
                    "required checklist's runner emits no ambient telemetry, so its execution can never be shown",
                    {"checklist": r, "section": heading, "required_items": len(items),
                     "emits_ambient": False, "seen_in_ambient_log": False},
                ))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--detector", default="D1,D2,D4")
    ap.add_argument("--ambient", default="", help="ambient.jsonl for D4 (default <repo>/.chump-locks/ambient.jsonl)")
    ap.add_argument("--out", default="")
    ap.add_argument("--summary", action="store_true", help="print a per-detector count to stderr")
    a = ap.parse_args()
    root = Path(a.repo).resolve()
    if not root.is_dir():
        print(f"wiring-detectors: not a directory: {root}", file=sys.stderr)
        return 2
    want = {d.strip().upper() for d in a.detector.split(",") if d.strip()}
    if not want or not want <= {"D1", "D2", "D4"}:
        print("wiring-detectors: --detector must be a subset of D1,D2,D4", file=sys.stderr)
        return 2
    repo = Repo(root)
    amb_path = Path(a.ambient) if a.ambient else root / ".chump-locks" / "ambient.jsonl"
    ambient = read(amb_path) if amb_path.is_file() else ""

    findings = []
    if "D1" in want:
        findings += d1_no_scheduler(repo)
    if "D2" in want:
        findings += d2_never_invoked(repo)
    if "D4" in want:
        findings += d4_no_telemetry(repo, ambient)
    findings.sort(key=lambda f: (f["detector"], f["artifact"]))
    lines = "\n".join(json.dumps(f, sort_keys=True) for f in findings)
    if a.out:
        Path(a.out).write_text(lines + ("\n" if lines else ""))
    elif lines:
        print(lines)
    if a.summary:
        for d in sorted(want):
            n = sum(1 for f in findings if f["detector"] == d)
            print(f"wiring-detectors: {d}: {n} finding(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
