#!/usr/bin/env python3
"""closed-pr-integrity-check — CREDIBLE-1489.

`status: done` / `superseded` is only trustworthy if the recorded `closed_pr`
is the PR that shipped the gap. During the 2026-10-05 orphan-branch triage ~31
of 95 branches were real unshipped work hidden behind gaps closed with a
`closed_pr` pointing at an UNRELATED PR (e.g. a Discord-digest PR), or an
implausibly old one. This check flags those closures.

Flags (per done/superseded gap that carries a closed_pr):
  MISMATCH   the cached PR exists but neither its title, head branch nor body
             mentions the gap id.
  TOO_OLD    the PR was created more than --slack-days BEFORE the gap was
             opened, so it cannot have shipped it.
  (UNVERIFIED gaps — PR absent from the cache — are counted, never flagged:
   "cannot check" is not evidence of a bad closure.)

Inputs:
  --gaps-json FILE   JSON list of gaps (id, status, closed_pr, opened_date, ...).
                     Default: `chump gap list --json` (all statuses).
  --cache-db FILE    github PR cache (default .chump/github_cache.db).
  --pr-meta FILE     alternative PR metadata: {"<n>": {"title","head_ref",
                     "created_at","body"}} (used by tests / offline runs).

Output / exit:
  text report (or --json). --strict exits 1 when anything is flagged.
  --reopen-cmds prints the `chump gap set <ID> --status open ...` commands that
  re-open each flagged gap; nothing is changed unless --apply is also given.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sqlite3
import subprocess
import sys

CLOSED_STATUSES = {"done", "superseded"}


def load_gaps(path: str | None) -> list[dict]:
    if path:
        with open(path) as f:
            data = json.load(f)
    else:
        out = subprocess.run(
            ["chump", "gap", "list", "--json"], capture_output=True, text=True, check=True
        )
        data = json.loads(out.stdout)
    return data["gaps"] if isinstance(data, dict) else data


def load_pr_meta(cache_db: str | None, pr_meta: str | None) -> dict[int, dict]:
    meta: dict[int, dict] = {}
    if pr_meta:
        with open(pr_meta) as f:
            for k, v in json.load(f).items():
                meta[int(k)] = v
        return meta
    if cache_db and os.path.exists(cache_db):
        conn = sqlite3.connect(f"file:{cache_db}?mode=ro", uri=True)
        try:
            for n, title, head_ref, payload in conn.execute(
                "SELECT number, title, head_ref, raw_payload_json FROM pr_state"
            ):
                created = body = None
                try:
                    p = json.loads(payload or "{}")
                    created, body = p.get("created_at"), p.get("body")
                except ValueError:
                    pass
                meta[int(n)] = {
                    "title": title or "",
                    "head_ref": head_ref or "",
                    "created_at": created,
                    "body": body or "",
                }
        finally:
            conn.close()
    return meta


def parse_date(s: str | None) -> dt.date | None:
    if not s:
        return None
    try:
        return dt.date.fromisoformat(str(s).strip().strip("'\"")[:10])
    except ValueError:
        return None


def check(gaps: list[dict], meta: dict[int, dict], slack_days: int) -> dict:
    flagged, unverified, checked = [], [], 0
    for g in gaps:
        if str(g.get("status", "")).lower() not in CLOSED_STATUSES:
            continue
        try:
            pr = int(g.get("closed_pr") or 0)
        except (TypeError, ValueError):
            pr = 0
        if pr <= 0:
            continue
        gid = g["id"]
        m = meta.get(pr)
        if m is None:
            unverified.append({"id": gid, "closed_pr": pr})
            continue
        checked += 1
        hay = " ".join(str(m.get(k) or "") for k in ("title", "head_ref", "body")).lower()
        reasons = []
        if gid.lower() not in hay:
            reasons.append("MISMATCH")
        opened, created = parse_date(g.get("opened_date")), parse_date(m.get("created_at"))
        if opened and created and (opened - created).days > slack_days:
            reasons.append("TOO_OLD")
        if reasons:
            flagged.append(
                {
                    "id": gid,
                    "status": g.get("status"),
                    "closed_pr": pr,
                    "reasons": reasons,
                    "pr_title": m.get("title", ""),
                }
            )
    return {"checked": checked, "flagged": flagged, "unverified": unverified}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gaps-json")
    ap.add_argument("--cache-db", default=".chump/github_cache.db")
    ap.add_argument("--pr-meta")
    ap.add_argument("--slack-days", type=int, default=1)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--reopen-cmds", action="store_true")
    ap.add_argument("--apply", action="store_true", help="with --reopen-cmds: actually re-open")
    a = ap.parse_args()

    res = check(load_gaps(a.gaps_json), load_pr_meta(a.cache_db, a.pr_meta), a.slack_days)
    if a.json:
        print(json.dumps(res, indent=2))
    else:
        print(
            f"closed_pr integrity: checked={res['checked']} flagged={len(res['flagged'])} "
            f"unverified(PR not in cache)={len(res['unverified'])}"
        )
        for f in res["flagged"]:
            print(f"  FLAG {f['id']} ({f['status']}) closed_pr=#{f['closed_pr']} "
                  f"[{','.join(f['reasons'])}] PR title: {f['pr_title']!r}")
    if a.reopen_cmds:
        for f in res["flagged"]:
            note = f"closed_pr #{f['closed_pr']} failed integrity check ({'/'.join(f['reasons'])}); re-opened for verification"
            cmd = ["chump", "gap", "set", f["id"], "--status", "open", "--notes", note]
            print("REOPEN: " + " ".join(subprocess.list2cmdline([c]) for c in cmd))
            if a.apply:
                subprocess.run(cmd, check=False)
    return 1 if (a.strict and res["flagged"]) else 0


if __name__ == "__main__":
    sys.exit(main())
