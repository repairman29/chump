#!/usr/bin/env python3
"""take-both-resolve — strip git conflict markers, keep both sides intact.

INFRA-1920. Mass-rescue helper for the common case where N PRs all touch
the same additive text file (event registries, env-var allowlists, raw-gh
allowlists, etc.) and each new merge to main creates N identical-shape
conflicts.

Use it like this:

    python3 scripts/dev/take-both-resolve.py <file> [<file> ...]

For each path, drops every line that begins with one of the git conflict
markers:

    <<<<<<<      (start of HEAD section)
    =======      (separator)
    >>>>>>>      (end of incoming section)

…and writes the file back. Content from BOTH sides is preserved verbatim
— that's the "take-both" semantic. Idempotent: running on an already-clean
file is a no-op.

SAFETY CONTRACT — read before using:

* Designed for ADDITIVE merges only. If HEAD added line X and the incoming
  branch added line Y in the same conflict region, you end up with both
  X and Y. That's correct for append-only registries.
* SILENTLY DESTRUCTIVE for SEMANTIC conflicts. If HEAD changed `foo = 1`
  to `foo = 2` and incoming changed it to `foo = 3`, you'll end up with
  both lines side-by-side (`foo = 2` then `foo = 3`) — almost certainly
  not what you want. Inspect the file's resolution by hand before
  committing in that case.
* Safe-by-construction for files like:
    - scripts/ci/event-registry-reserved.txt
    - scripts/ci/raw-gh-allowlist.txt
    - scripts/ci/env-vars-internal.txt
    - any other line-keyed allowlist or registry
* Use git diff on the result before committing if unsure.

Exit codes:
    0  every file processed (or no files needed work)
    1  no file paths supplied on the command line
"""

import sys


CONFLICT_PREFIXES = ("<<<<<<< ", "=======", ">>>>>>> ")


def take_both(path: str) -> bool:
    """Strip conflict markers from path. Returns True if file was modified."""
    with open(path, "r") as fh:
        original = fh.read()
    kept = []
    modified = False
    for line in original.split("\n"):
        # Match `=======` exactly OR `<<<<<<< X` / `>>>>>>> Y` (with payload)
        is_marker = (
            line.startswith("<<<<<<< ")
            or line == "======="
            or line.startswith("=======\n")
            or line.startswith(">>>>>>> ")
        )
        if is_marker:
            modified = True
            continue
        kept.append(line)
    if modified:
        with open(path, "w") as fh:
            fh.write("\n".join(kept))
    return modified


def main(argv: list[str]) -> int:
    if not argv:
        sys.stderr.write(
            "usage: take-both-resolve.py <file> [<file> ...]\n"
            "       strips git conflict markers, keeps both sides\n"
            "       see docstring for the safety contract\n"
        )
        return 1
    for path in argv:
        try:
            changed = take_both(path)
        except FileNotFoundError:
            sys.stderr.write(f"skip: {path} not found\n")
            continue
        if changed:
            sys.stderr.write(f"resolved (take-both): {path}\n")
        else:
            sys.stderr.write(f"clean (no markers): {path}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
