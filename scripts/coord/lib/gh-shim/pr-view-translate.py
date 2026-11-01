#!/usr/bin/env python3.12
"""
pr-view-translate.py — INFRA-1282

Translates `gh pr view <PR-or-branch> [--json FIELDS] [-q/--jq EXPR]` to a
REST `/repos/{owner}/{repo}/pulls/{N}` call (cache-first via the chump
local cache at .chump/github_cache.db), then reshapes the REST JSON to
match the gh-pr-view-with-json output shape.

Why: `gh pr view` uses GraphQL. The chump fleet polls hot PRs heavily
(pr-watch.sh, bot-merge.sh existing-PR check, queue-driver branch
lookup). Routing through REST + cache cuts ~100 GraphQL calls/hr per
the 2026-05-14 throttle audit.

Exit codes:
    0   success — translation handled, output written
    2   unsupported pattern — caller should fall through to real gh
    3   PR not found (cache miss + REST lookup failed)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import Any


# REST field → gh pr view --json name. Tuple is (rest_path, transform_kind).
FIELD_MAP: dict[str, tuple[str, str]] = {
    "number": ("number", "as_is"),
    "title": ("title", "as_is"),
    "body": ("body", "as_is"),
    "url": ("html_url", "as_is"),
    "isDraft": ("draft", "yesno"),
    "mergeable": ("mergeable", "yesno"),
    "state": ("state", "upper"),
    "mergeStateStatus": ("mergeable_state", "upper"),
    "headRefName": ("head.ref", "as_is"),
    "baseRefName": ("base.ref", "as_is"),
    "createdAt": ("created_at", "as_is"),
    "updatedAt": ("updated_at", "as_is"),
    "closedAt": ("closed_at", "as_is"),
    "mergedAt": ("merged_at", "as_is"),
    "author": ("user.login", "wrap_login"),
    "autoMergeRequest": ("auto_merge", "automerge"),
}


def deep_get(obj: Any, path: str) -> Any:
    cur = obj
    for part in path.split("."):
        if cur is None:
            return None
        if isinstance(cur, dict):
            cur = cur.get(part)
        else:
            return None
    return cur


def transform(value: Any, kind: str) -> Any:
    if value is None:
        return None
    if kind == "as_is":
        return value
    if kind == "upper":
        if isinstance(value, str):
            return value.upper()
        return value
    if kind == "yesno":
        return bool(value)
    if kind == "wrap_login":
        return {"login": value} if isinstance(value, str) else None
    if kind == "automerge":
        if not value:
            return None
        method = value.get("merge_method") if isinstance(value, dict) else None
        if method and isinstance(method, str):
            value = dict(value)
            value["mergeMethod"] = method.upper()
        return value
    return value


def project(rest_json: dict, fields: list[str]) -> dict | None:
    out: dict = {}
    for f in fields:
        if f not in FIELD_MAP:
            return None
        rest_path, kind = FIELD_MAP[f]
        val = deep_get(rest_json, rest_path)
        out[f] = transform(val, kind)
    return out


def resolve_repo_root() -> Path:
    env = os.environ.get("CHUMP_REPO")
    if env:
        return Path(env)
    try:
        res = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=False,
        )
        if res.returncode == 0:
            return Path(res.stdout.strip())
    except Exception:
        pass
    return Path.cwd()


def cache_db_path(repo_root: Path) -> Path:
    return repo_root / ".chump" / "github_cache.db"


def cache_lookup_by_number(db_path: Path, number: int, max_age_s: int = 60) -> dict | None:
    """Return a REST-shaped PR dict from cache, or None on miss/stale.

    INFRA-1368: also fetches merge_state_status column so mergeStateStatus
    lookups are served from the dedicated column rather than parsing
    raw_payload_json (which has inconsistent format between webhook and REST
    sources). The returned dict always has mergeable_state injected from the
    column when present so project() finds it at the top level.
    """
    if not db_path.exists():
        return None
    conn = sqlite3.connect(str(db_path))
    try:
        try:
            cur = conn.execute(
                """SELECT raw_payload_json,
                          CAST((strftime('%s','now') - strftime('%s', fetched_at_local)) AS INTEGER),
                          merge_state_status,
                          mergeable_state
                   FROM pr_state WHERE number = ?""",
                (number,),
            )
        except Exception:
            # merge_state_status column not yet present (pre-migration DB) — fall back
            cur = conn.execute(
                """SELECT raw_payload_json,
                          CAST((strftime('%s','now') - strftime('%s', fetched_at_local)) AS INTEGER),
                          NULL,
                          mergeable_state
                   FROM pr_state WHERE number = ?""",
                (number,),
            )
        row = cur.fetchone()
        if not row:
            return None
        payload, age, merge_state_status, mergeable_state_col = row
        if age is None or age >= max_age_s:
            return None
        try:
            data = json.loads(payload)
        except Exception:
            return None
        # Unwrap webhook payload format: webhook receiver stores the full
        # pull_request event ({"action":..., "pull_request":{...}}) but REST
        # calls return a flat PR object. Normalise so project() always works.
        if isinstance(data, dict) and "pull_request" in data:
            data = data["pull_request"]
        # INFRA-1368: inject mergeable_state from the dedicated column so
        # mergeStateStatus is always available regardless of payload format.
        col_val = merge_state_status or mergeable_state_col
        if col_val is not None:
            data["mergeable_state"] = col_val
        return data
    finally:
        conn.close()


def cache_lookup_by_branch(db_path: Path, branch: str) -> int | None:
    if not db_path.exists():
        return None
    conn = sqlite3.connect(str(db_path))
    try:
        cur = conn.execute(
            "SELECT number FROM pr_state WHERE head_ref = ? AND merged_at IS NULL ORDER BY number DESC LIMIT 1",
            (branch,),
        )
        row = cur.fetchone()
        return row[0] if row else None
    finally:
        conn.close()


def rest_fetch(pr_number: int, repo: str | None = None) -> dict | None:
    env = os.environ.copy()
    env["CHUMP_GH_NO_SHIM"] = "1"
    if repo:
        url = f"repos/{repo}/pulls/{pr_number}"
    else:
        url = f"repos/{{owner}}/{{repo}}/pulls/{pr_number}"
    res = subprocess.run(
        ["gh", "api", url],
        capture_output=True, text=True, env=env, check=False,
    )
    if res.returncode != 0:
        return None
    try:
        return json.loads(res.stdout)
    except Exception:
        return None


def emit_ambient(event: dict, repo_root: Path) -> None:
    log = repo_root / ".chump-locks" / "ambient.jsonl"
    try:
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open("a") as f:
            f.write(json.dumps(event) + "\n")
    except Exception:
        pass


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("target", nargs="?", default=None)
    ap.add_argument("--json", dest="json_fields", default=None)
    ap.add_argument("-q", "--jq", dest="jq_expr", default=None)
    ap.add_argument("--repo", dest="repo", default=None)
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--comments", action="store_true")
    ap.add_argument("--web", action="store_true")
    args, unknown = ap.parse_known_args(argv)

    if args.watch or args.comments or args.web or unknown:
        return 2
    if not args.target:
        return 2
    if not args.json_fields:
        return 2

    fields = [f.strip() for f in args.json_fields.split(",") if f.strip()]
    if not fields:
        return 2
    for f in fields:
        if f not in FIELD_MAP:
            return 2

    repo_root = resolve_repo_root()
    db = cache_db_path(repo_root)

    if re.fullmatch(r"\d+", args.target):
        pr_number = int(args.target)
    else:
        n = cache_lookup_by_branch(db, args.target)
        if n is None:
            return 2
        pr_number = n

    pr = cache_lookup_by_number(db, pr_number)
    cache_age_kind = "cache_hit"
    if pr is None:
        cache_age_kind = "cache_miss"
        pr = rest_fetch(pr_number, args.repo)
        if pr is None:
            return 3

    import datetime as _dt
    emit_ambient({
        "ts": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "kind": cache_age_kind,
        "source": "gh-shim-pr-view-rewrite",
        "pr": pr_number,
        "fields": ",".join(fields),
    }, repo_root)

    out = project(pr, fields)
    if out is None:
        return 2

    out_json = json.dumps(out)

    if args.jq_expr:
        env = os.environ.copy()
        env["CHUMP_GH_NO_SHIM"] = "1"
        res = subprocess.run(
            ["jq", "-r", args.jq_expr],
            input=out_json, capture_output=True, text=True, env=env, check=False,
        )
        if res.returncode != 0:
            sys.stderr.write(res.stderr)
            return 2
        sys.stdout.write(res.stdout)
    else:
        sys.stdout.write(out_json + "\n")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
