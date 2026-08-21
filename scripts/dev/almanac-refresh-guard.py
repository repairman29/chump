#!/usr/bin/env python3
"""almanac-refresh-guard.py — RESILIENT-352

The almanac refresh cron (installed by
`~/Projects/almanac/scripts/chump-ftue-hook.sh`, chump-side counterpart of
`scripts/dev/almanac-census.py` / `almanac-zero-hits.py`) ran rc=0 every
cycle for ~11 days while 106/112 fleet indexes silently rotted — a green
facade. Root cause: the loop only checked whether the index CHECKOUT's own
HEAD had moved since the last cycle. A checkout parked on a stale commit
(a dev `git checkout`d a feature branch inside the shared indexing worktree
and never switched back — "dev-hijack") reports the *same* HEAD every
cycle, so "no change" and "genuinely fresh" were indistinguishable, and the
loop happily reindexed nothing while reporting success.

This guard fixes both halves:

1. **Track origin/main, not local HEAD.** Every cycle fetches `origin` and
   compares the last-successfully-indexed commit against `origin/main` —
   never against the checkout's own possibly-parked HEAD.
2. **Force-reset before reindexing.** The index checkout is a dedicated
   worktree that no dev session should ever leave dirty or on a different
   branch; each cycle forces it back to `origin/main` (`checkout --force
   --detach` + `reset --hard` + `clean -fdx`) before invoking the reindex
   command, so a dev-hijacked checkout self-heals within one cycle instead
   of staying parked until a human notices.

Every invocation appends exactly one JSON line to the log, and the `kind`
field is the thing the 11-day incident needed and didn't have — it makes
"real work happened" and "nothing needed doing" and "drift detected but the
checkout could not be repaired" three distinct, greppable outcomes instead
of one overloaded rc=0:

  - `up_to_date`   — last-indexed commit already equals origin/main; no
                     reset, no reindex. Genuinely fresh.
  - `real_fresh`   — origin/main had moved; checkout was force-reset and
                     the reindex command ran and exited 0. Marker advances.
  - `parked`       — origin/main had moved but the checkout could not be
                     brought to it (fetch failed, force-reset failed, or
                     the reindex command exited non-zero). Marker does NOT
                     advance, so the next cycle retries. Exit code is
                     non-zero so a supervising loop notices instead of
                     reporting rc=0 for a cycle that did nothing.

Usage:
    python3 scripts/dev/almanac-refresh-guard.py \\
        --checkout /path/to/index/checkout \\
        --marker /path/to/index/checkout.last-indexed \\
        --reindex-cmd 'almanac index --repo /path/to/index/checkout' \\
        --log ~/.almanac/refresh-guard.jsonl

`--marker` is deliberately a sibling file OUTSIDE the checkout (default:
`<checkout>.last-indexed-commit`) rather than a dotfile inside it — a file
inside the checkout would be wiped by the very `git clean -fdx` this script
runs to undo dev-hijack, which would make every cycle look like a fresh
start and defeat idempotency.
"""

import argparse
import json
import os
import subprocess
import sys
import time


def run(cmd, cwd=None, check=True):
    return subprocess.run(
        cmd, cwd=cwd, check=check, capture_output=True, text=True,
    )


def default_marker_path(checkout: str) -> str:
    checkout = checkout.rstrip("/")
    return f"{checkout}.last-indexed-commit"


def read_marker(marker_path: str) -> str:
    try:
        with open(marker_path, "r") as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""


def write_marker(marker_path: str, sha: str) -> None:
    tmp = f"{marker_path}.tmp"
    with open(tmp, "w") as f:
        f.write(sha + "\n")
    os.replace(tmp, marker_path)


def log_line(log_path: str, record: dict) -> None:
    record.setdefault("ts", None)
    os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
    with open(log_path, "a") as f:
        f.write(json.dumps(record) + "\n")


def force_reset_to_origin(checkout: str, branch: str) -> tuple[bool, str]:
    """Stomp any dev-hijack (wrong branch, dirty tree, stray commits) and
    land the checkout exactly on origin/<branch>. Returns (ok, error)."""
    ref = f"origin/{branch}"
    try:
        run(["git", "checkout", "--force", "--detach", ref], cwd=checkout)
        run(["git", "reset", "--hard", ref], cwd=checkout)
        run(["git", "clean", "-fdx"], cwd=checkout)
        return True, ""
    except subprocess.CalledProcessError as e:
        return False, (e.stderr or e.stdout or str(e)).strip()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--checkout", required=True, help="dedicated index-only git checkout")
    ap.add_argument("--branch", default="main", help="branch to track (default: main)")
    ap.add_argument("--marker", default=None, help="path to the last-indexed-commit marker file")
    ap.add_argument("--reindex-cmd", required=True, help="shell command that (re)builds the index")
    ap.add_argument(
        "--log",
        default=os.path.expanduser("~/.almanac/refresh-guard.jsonl"),
        help="JSONL log of every cycle's outcome",
    )
    ap.add_argument("--repo-name", default=None, help="label for log lines (default: basename of --checkout)")
    args = ap.parse_args()

    checkout = os.path.abspath(args.checkout)
    marker_path = args.marker or default_marker_path(checkout)
    repo_name = args.repo_name or os.path.basename(checkout.rstrip("/"))
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    if not os.path.isdir(checkout):
        log_line(args.log, {
            "ts": now, "repo": repo_name, "kind": "parked",
            "reason": f"checkout does not exist: {checkout}",
        })
        print(f"parked: checkout does not exist: {checkout}", file=sys.stderr)
        return 1

    try:
        run(["git", "fetch", "origin", args.branch, "--quiet"], cwd=checkout)
        origin_sha = run(
            ["git", "rev-parse", f"origin/{args.branch}"], cwd=checkout
        ).stdout.strip()
    except subprocess.CalledProcessError as e:
        log_line(args.log, {
            "ts": now, "repo": repo_name, "kind": "parked",
            "reason": f"fetch/rev-parse failed: {(e.stderr or e.stdout or '').strip()}",
        })
        print("parked: fetch/rev-parse failed", file=sys.stderr)
        return 1

    last_indexed = read_marker(marker_path)

    if last_indexed == origin_sha:
        log_line(args.log, {
            "ts": now, "repo": repo_name, "kind": "up_to_date",
            "index_commit": origin_sha,
        })
        print(f"up_to_date: index already tracks origin/{args.branch} ({origin_sha[:12]})")
        return 0

    ok, err = force_reset_to_origin(checkout, args.branch)
    if not ok:
        log_line(args.log, {
            "ts": now, "repo": repo_name, "kind": "parked",
            "reason": f"force-reset failed: {err}",
            "index_commit": last_indexed, "origin_commit": origin_sha,
        })
        print(f"parked: force-reset to origin/{args.branch} failed: {err}", file=sys.stderr)
        return 1

    proc = subprocess.run(args.reindex_cmd, shell=True, cwd=checkout, capture_output=True, text=True)
    if proc.returncode != 0:
        log_line(args.log, {
            "ts": now, "repo": repo_name, "kind": "parked",
            "reason": f"reindex-cmd exited {proc.returncode}: {(proc.stderr or proc.stdout or '').strip()[:500]}",
            "index_commit": last_indexed, "origin_commit": origin_sha,
        })
        print(f"parked: reindex-cmd exited {proc.returncode}", file=sys.stderr)
        return 1

    write_marker(marker_path, origin_sha)
    log_line(args.log, {
        "ts": now, "repo": repo_name, "kind": "real_fresh",
        "index_commit": origin_sha, "previous_index_commit": last_indexed,
    })
    print(f"real_fresh: {repo_name} {last_indexed[:12] or '(none)'} -> {origin_sha[:12]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
