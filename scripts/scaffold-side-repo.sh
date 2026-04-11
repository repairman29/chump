#!/usr/bin/env bash
# W4.2 — Scaffold a thin side repo from templates/side-repo (LICENSE, CI stub, README, issue template).
#
# Usage:
#   ./scripts/scaffold-side-repo.sh /path/to/new-repo "Human readable name"
#   ./scripts/scaffold-side-repo.sh /path/to/new-repo "My Project" --git   # git init + first commit
#
# Refuses non-empty targets. Replaces __PROJECT_NAME__ and __YEAR__ in text files. Requires python3.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:?usage: $0 <target-dir> <\"Project Name\"> [--git]}"
NAME="${2:?usage: $0 <target-dir> <\"Project Name\"> [--git]}"
DO_GIT=0
for a in "${@:3}"; do [[ "$a" == "--git" ]] && DO_GIT=1; done

if [[ -e "$TARGET" ]] && [[ -n "$(ls -A "$TARGET" 2>/dev/null)" ]]; then
  echo "Refuse: $TARGET exists and is not empty." >&2
  exit 1
fi

if ! command -v python3 >/dev/null; then
  echo "python3 required for template substitution." >&2
  exit 1
fi

mkdir -p "$TARGET"
TARGET_ABS=$(cd "$TARGET" && pwd)
if [[ "$TARGET_ABS" == "$ROOT" ]]; then
  echo "Refuse: pick a subdirectory or a path outside the Chump repo root." >&2
  exit 1
fi

cp -R "$ROOT/templates/side-repo/." "$TARGET_ABS/"
YEAR=$(date +%Y)
export TARGET_ABS NAME YEAR
python3 <<'PY'
import os, pathlib
dest = pathlib.Path(os.environ["TARGET_ABS"])
name = os.environ["NAME"]
year = os.environ["YEAR"]
for f in dest.rglob("*"):
    if not f.is_file():
        continue
    try:
        t = f.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    if "__PROJECT_NAME__" in t or "__YEAR__" in t:
        f.write_text(
            t.replace("__PROJECT_NAME__", name).replace("__YEAR__", year),
            encoding="utf-8",
        )
PY

if [[ "$DO_GIT" == "1" ]]; then
  (cd "$TARGET_ABS" && git init -q && git add -A && git commit -q -m "chore: scaffold from Chump templates") || true
  echo "Git: initial commit in $TARGET_ABS"
fi

echo "Scaffolded: $TARGET_ABS (see docs/PROBLEM_VALIDATION_CHECKLIST.md)"
