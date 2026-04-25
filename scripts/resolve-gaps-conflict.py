#!/usr/bin/env python3
# INFRA-052 — auto-resolve gaps.yaml tail-append rebase conflicts.
#
# Every PR that adds a `- id: ...` gap entry appends to the bottom of
# docs/gaps.yaml. When two such PRs are in flight, the second one's
# rebase always conflicts at the tail with markers shaped like:
#
#   <<<<<<< HEAD
#   (the gap entry that landed first)
#   =======
#   (the gap entry that's being rebased)
#   >>>>>>> <commit>
#
# The correct resolution is always: keep BOTH sides, in order. This
# script does that mechanically. It refuses to act on conflicts that
# look like real content overlaps (markers nested inside markers, or
# any markers left behind after the substitution pass) so it cannot
# silently corrupt a non-append conflict.
#
# Usage:
#   scripts/resolve-gaps-conflict.py docs/gaps.yaml
#
# Exit codes:
#   0  — resolved one or more conflict blocks; file is clean
#   2  — no conflict markers found (nothing to do)
#   3  — markers remain after substitution (real conflict, abort)

import sys
import re

if len(sys.argv) != 2:
    print("usage: resolve-gaps-conflict.py <path>", file=sys.stderr)
    sys.exit(64)

path = sys.argv[1]
with open(path) as f:
    content = f.read()

pattern = re.compile(
    r'<<<<<<< HEAD\n(.*?)\n=======\n(.*?)\n>>>>>>> [^\n]*\n',
    re.DOTALL,
)

count = 0


def replace(m):
    global count
    count += 1
    ours, theirs = m.group(1), m.group(2)
    return ours.rstrip() + '\n' + theirs + '\n'


new = pattern.sub(replace, content)

if count == 0:
    print("no conflict markers found", file=sys.stderr)
    sys.exit(2)

if '<<<<<<<' in new or '=======' in new or '>>>>>>>' in new:
    print(
        "ERROR: markers remain after pass — non-append conflict, refusing to write",
        file=sys.stderr,
    )
    sys.exit(3)

with open(path, 'w') as f:
    f.write(new)

print(f"resolved {count} conflict block(s) in {path}")
