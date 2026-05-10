#!/usr/bin/env python3
"""Helper invoked by bounced-pr-detector.sh — classifies recently-closed-
unmerged PRs as RELANDED (informational) or BOUNCED (file recovery gap).

Reads PR JSON from stdin (output of `gh pr list ... --json ...`).
Writes one ACTION line per processed PR to stdout, in the format:
    RELANDED|<pr>|<title>|<ratio>
    BOUNCED|<pr>|<title>|<ratio>|<files-csv>
"""
import json
import subprocess
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: _bounced_pr_classifier.py <repo_root>", file=sys.stderr)
        return 2

    repo_root = Path(sys.argv[1])

    try:
        prs = json.load(sys.stdin)
    except json.JSONDecodeError:
        # Empty / malformed input — exit cleanly.
        return 0

    if not isinstance(prs, list):
        return 0

    for pr in prs:
        if not isinstance(pr, dict):
            continue
        if pr.get("mergedAt"):
            continue  # merged after all
        pr_num = pr.get("number")
        closed_at = pr.get("closedAt")
        title = pr.get("title", "")
        files = [f["path"] for f in pr.get("files", []) if isinstance(f, dict) and "path" in f]
        if not pr_num or not closed_at or not files:
            continue

        relanded = 0
        for path in files:
            try:
                log = subprocess.run(
                    ["git", "log", f"--since={closed_at}", "--format=%H", "--", path],
                    cwd=str(repo_root),
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
            except subprocess.TimeoutExpired:
                continue
            if log.returncode == 0 and log.stdout.strip():
                relanded += 1

        ratio = relanded / max(1, len(files))
        title_clean = (title or "").replace("|", "/").replace("\n", " ")[:80]
        files_csv = ",".join(files[:5])

        if ratio >= 0.5:
            print(f"RELANDED|{pr_num}|{title_clean}|{ratio:.2f}")
        else:
            print(f"BOUNCED|{pr_num}|{title_clean}|{ratio:.2f}|{files_csv}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
