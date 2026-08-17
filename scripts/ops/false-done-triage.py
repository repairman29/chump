#!/usr/bin/env python3
"""false-done-triage — CREDIBLE-279 AC2: turn a BOOKKEEPING-CLOSED count into
per-gap VERDICTS.

`false-done-sweep.py --multi-close-only` proves the closed_pr ATTRIBUTION is
false (the credited PR shipped no implementation) but explicitly declines to
say more: "whether the work landed in some OTHER PR still needs the per-gap
check". This script does that check, using only local git history (no `gh`,
no network) so it runs anywhere the repo is cloned:

  1. Pull the gap's full text (title/description/AC/evidence/notes) via
     `chump gap show <ID> --json` and extract concrete repo paths from it
     (same PATH_RE / NOISE rules as false-done-sweep.py, imported directly
     so the two tools can never silently drift apart).
  2. For each path, `git log --all --oneline -- <path>` to find every commit
     that ever touched it, and pull the "(#NNNN)" PR number out of each
     commit subject (this repo squash-merges, so the PR number is always in
     the merge commit's subject line).
  3. A candidate PR is any such PR OTHER than the one credited as closed_pr.
     - Exactly one distinct candidate PR across all named paths -> verdict
       FOUND_ELSEWHERE, with that PR number and the matching commit(s).
     - Zero candidates across every named path -> verdict NOT_FOUND (the
       work never landed anywhere; the honest recommendation is REOPEN).
     - More than one distinct candidate PR -> verdict AMBIGUOUS (needs a
       human to pick) — never silently guessed.
     - Gap names no concrete path at all -> verdict UNJUDGEABLE, same
       honesty rule as the sweep itself.

Usage:
  python3 scripts/ops/false-done-triage.py --json-in /tmp/bookkeeping.json --json
  python3 scripts/ops/false-done-triage.py --gap CREDIBLE-151

`--json-in` accepts either the `bookkeeping_closed` list itself or the full
`--json` report from false-done-sweep.py (this script reads whichever key is
present). Exit 0 always unless --strict, which exits 1 if any NOT_FOUND
verdict remains (i.e. a done gap that should be reopened still is not).
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "false_done_sweep", os.path.join(_HERE, "false-done-sweep.py")
)
_sweep = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_sweep)

PR_IN_SUBJECT = re.compile(r"\(#(\d+)\)")


def sh(cmd, timeout=60):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None


def gap_show(gap_id):
    out = sh(["chump", "gap", "show", gap_id, "--json"])
    if not out:
        return None
    try:
        return json.loads(out)
    except Exception:
        return None


def commits_touching(path):
    """(commit_sha, subject) pairs for every commit that ever touched `path`,
    NEWEST first. A bare filename (no '/') is a directory-less basename from
    `paths_in()` — e.g. "durable_resume.rs" for a file that actually lives at
    src/commands/durable_resume.rs — so it must be globbed, or `git log --
    durable_resume.rs` silently matches nothing and every such gap comes back
    a false NOT_FOUND."""
    pathspec = f"**/{path}" if "/" not in path else path
    out = sh(["git", "log", "--all", "--format=%H%x1f%s", "--", pathspec])
    if not out:
        return []
    pairs = []
    for line in out.splitlines():
        if "\x1f" not in line:
            continue
        sha, subject = line.split("\x1f", 1)
        pairs.append((sha, subject))
    return pairs


def triage_one(g):
    gid = g["gap"]
    credited_pr = str(g["pr"])
    row = gap_show(gid)
    if row is None:
        return {"gap": gid, "credited_pr": credited_pr, "verdict": "SHOW_FAILED"}

    text = _sweep.gap_text(row)
    paths = _sweep.paths_in(text)
    if not paths:
        return {"gap": gid, "credited_pr": credited_pr, "verdict": "UNJUDGEABLE",
                 "reason": "gap text names no concrete path"}

    candidates = {}  # pr_number -> (path, sha, subject)
    for p in paths:
        history = commits_touching(p)
        # A path with exactly one commit in its entire history is that
        # commit CREATING the file — it cannot also be "the fix" for a bug
        # filed against a gap that (per the sweep's own gap_text() rule)
        # already existed at reserve time. Counting a creation commit as a
        # FOUND_ELSEWHERE match produced 3/3 false positives in the first
        # triage pass (CREDIBLE-053, RESILIENT-112, RESILIENT-144 all
        # matched the PR that originally added the file, not a later fix).
        # Require at least a second touch before trusting this path's signal.
        if len(history) < 2:
            continue
        for sha, subject in history:  # newest first
            m = PR_IN_SUBJECT.search(subject)
            if not m:
                continue
            pr = m.group(1)
            if pr == credited_pr:
                continue
            candidates.setdefault(pr, (p, sha, subject))
            break  # newest non-credited touch per path is the candidate

    if not candidates:
        return {"gap": gid, "credited_pr": credited_pr, "verdict": "NOT_FOUND",
                 "recommendation": "REOPEN", "paths_checked": sorted(paths)[:6]}
    if len(candidates) == 1:
        pr, (p, sha, subject) = next(iter(candidates.items()))
        return {"gap": gid, "credited_pr": credited_pr, "verdict": "FOUND_ELSEWHERE",
                 "recommendation": f"chump gap set {gid} --closed-pr {pr}",
                 "found_pr": pr, "matched_path": p, "commit": sha[:12], "subject": subject}
    return {"gap": gid, "credited_pr": credited_pr, "verdict": "AMBIGUOUS",
             "recommendation": "human triage — multiple candidate PRs",
             "candidates": {pr: {"path": p, "commit": sha[:12], "subject": subject}
                            for pr, (p, sha, subject) in candidates.items()}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json-in", help="path to false-done-sweep.py --json output "
                                        "(or a bare bookkeeping_closed list)")
    ap.add_argument("--gap", help="triage a single gap id (skips --json-in; "
                                    "reads its own credited_pr from chump gap show)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--strict", action="store_true",
                     help="exit 1 if any NOT_FOUND verdict remains")
    a = ap.parse_args()

    if a.gap:
        row = gap_show(a.gap)
        if row is None or not row.get("closed_pr"):
            sys.exit(f"{a.gap}: not found or has no closed_pr")
        items = [{"gap": a.gap, "pr": row["closed_pr"], "title": row.get("title", "")}]
    elif a.json_in:
        raw = json.load(open(a.json_in))
        items = raw.get("bookkeeping_closed", raw) if isinstance(raw, dict) else raw
    else:
        sys.exit("pick one of --json-in / --gap")

    verdicts = [triage_one(g) for g in items]

    if a.json:
        print(json.dumps(verdicts, indent=2))
    else:
        by_verdict = {}
        for v in verdicts:
            by_verdict.setdefault(v["verdict"], []).append(v)
        print(f"false-done triage: {len(verdicts)} bookkeeping-closed gaps")
        for kind in ("FOUND_ELSEWHERE", "NOT_FOUND", "AMBIGUOUS", "UNJUDGEABLE", "SHOW_FAILED"):
            vs = by_verdict.get(kind, [])
            print(f"  {kind:16s}: {len(vs)}")
        for kind in ("FOUND_ELSEWHERE", "NOT_FOUND", "AMBIGUOUS"):
            for v in by_verdict.get(kind, []):
                print(f"    {v['gap']}: {v.get('recommendation', '')}")

    if a.strict and any(v["verdict"] == "NOT_FOUND" for v in verdicts):
        sys.exit(1)


if __name__ == "__main__":
    main()
