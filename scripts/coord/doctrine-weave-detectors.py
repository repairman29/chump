#!/usr/bin/env python3
"""doctrine-weave-detectors.py — META-1041 (META-256 Doctrine Loom stitches 2+3).

Consumes the graph from doctrine-seam-finder.py and runs two detectors:

  missing-thread  (kind=doctrine_weave_asymmetry)
    * X references Y but Y never references X            (reason=one-way)
    * two playbooks overlap heavily on topics yet neither
      references the other                                (reason=overlap-no-link)

  frayed-edge     (kind=doctrine_weave_frayed_edge)
    * a reference to a section that no longer exists in the target:
      `FILE.md#anchor` (anchor not among the target's heading slugs) or
      `FILE.md §N` (no heading carries §N / a leading "N." number)
    * a mention of a gap ID whose record is closed
      (status done / closed / shipped / superseded / wont_fix ...)

Usage:
  doctrine-weave-detectors.py [--root DIR] [--emit] [--ambient FILE]
                              [--min-overlap F]

Prints findings as JSON. With --emit, also appends one ambient event per
finding (default log: <root>/.chump-locks/ambient.jsonl, or $CHUMP_AMBIENT_LOG).
Always exits 0: findings are signals for the Loom, not failures.
"""
import argparse
import importlib.util
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "doctrine_seam_finder", os.path.join(HERE, "doctrine-seam-finder.py"))
seam = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(seam)

CLOSED = {"done", "closed", "closed_not_a_bug", "shipped", "superseded",
          "wont_fix", "wontfix", "already_satisfied"}
GAP_RE = re.compile(r"\b([A-Z][A-Z]+-\d{1,5})\b")
# FILE.md#anchor  or  [..](FILE.md#anchor)
ANCHOR_RE = re.compile(r"([\w./-]+\.md)#([\w%-]+)")
# FILE.md §5  /  FILE.md §5.2  (section sign within a short span after the file)
SECTION_RE = re.compile(r"([\w./-]+\.md)[^\n§]{0,12}§\s*(\d+(?:\.\d+)*)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$", re.M)


def slug(heading):
    s = re.sub(r"[^\w\s-]", "", heading.lower())
    return re.sub(r"\s", "-", s.strip())


def headings(text):
    text = seam.CODE_FENCE_RE.sub(" ", text)
    return [h for _, h in HEADING_RE.findall(text)]


def section_exists(heads, num):
    pat = re.compile(r"§\s*" + re.escape(num) + r"(?![\d.]*\d)|^" + re.escape(num) + r"[.)\s]")
    return any(pat.search(h) for h in heads)


def closed_gaps(root):
    out = {}
    d = os.path.join(root, "docs", "gaps")
    if not os.path.isdir(d):
        return out
    for fn in os.listdir(d):
        if not fn.endswith(".yaml"):
            continue
        gid, status = fn[:-5], None
        with open(os.path.join(d, fn), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r"\s{0,2}(?:- )?status:\s*['\"]?([\w-]+)", line)
                if m:
                    status = m.group(1)
                    break
        if status in CLOSED:
            out[gid] = status
    return out


def missing_threads(graph, min_overlap):
    found = []
    for e in graph["edges"]:
        if e["asymmetric"]:
            found.append({"kind": "doctrine_weave_asymmetry", "reason": "one-way",
                          "from": e["from"], "to": e["to"]})
    for o in graph["overlap"]:
        if not o["linked"] and o["score"] >= min_overlap:
            found.append({"kind": "doctrine_weave_asymmetry", "reason": "overlap-no-link",
                          "from": o["a"], "to": o["b"], "score": o["score"]})
    return found


def frayed_edges(root, graph, closed):
    scope = [p["path"] for p in graph["playbooks"]]
    sset = set(scope)
    by_name = {}
    for p in scope:
        by_name.setdefault(os.path.basename(p), []).append(p)
    texts = {p: seam.read(root, p) for p in scope}
    heads = {p: headings(texts[p]) for p in scope}
    slugs = {p: {slug(h) for h in heads[p]} for p in scope}
    found = []
    for src in scope:
        prose = seam.CODE_FENCE_RE.sub(" ", texts[src])
        seen = set()

        def add(rec):
            key = json.dumps(rec, sort_keys=True)
            if key not in seen:
                seen.add(key)
                found.append(rec)

        for ref, anchor in ANCHOR_RE.findall(prose):
            tgt = seam.resolve(ref, src, sset, by_name)
            if tgt and tgt != src and anchor.lower() not in slugs[tgt]:
                add({"kind": "doctrine_weave_frayed_edge", "reason": "missing-section",
                     "from": src, "to": tgt, "section": "#" + anchor})
        for ref, num in SECTION_RE.findall(prose):
            tgt = seam.resolve(ref, src, sset, by_name)
            if tgt and tgt != src and not section_exists(heads[tgt], num):
                add({"kind": "doctrine_weave_frayed_edge", "reason": "missing-section",
                     "from": src, "to": tgt, "section": "§" + num})
        for gid in sorted(set(GAP_RE.findall(prose))):
            if gid in closed:
                add({"kind": "doctrine_weave_frayed_edge", "reason": "closed-gap",
                     "from": src, "gap_id": gid, "gap_status": closed[gid]})
    return found


def emit(findings, ambient):
    os.makedirs(os.path.dirname(ambient) or ".", exist_ok=True)
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(ambient, "a", encoding="utf-8") as fh:
        for f in findings:
            ev = {"ts": ts, **f}
            fh.write(json.dumps(ev, sort_keys=True) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=os.path.join(HERE, "..", ".."))
    ap.add_argument("--emit", action="store_true")
    ap.add_argument("--ambient")
    ap.add_argument("--min-overlap", type=float, default=0.3)
    args = ap.parse_args(argv)
    root = os.path.abspath(args.root)
    graph = seam.build(root, min(args.min_overlap, 0.2))
    findings = missing_threads(graph, args.min_overlap) + \
        frayed_edges(root, graph, closed_gaps(root))
    if args.emit:
        ambient = args.ambient or os.environ.get("CHUMP_AMBIENT_LOG") or \
            os.path.join(root, ".chump-locks", "ambient.jsonl")
        emit(findings, ambient)
    json.dump({"schema": 1, "findings": findings}, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
