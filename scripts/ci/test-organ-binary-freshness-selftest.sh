#!/usr/bin/env bash
# RESILIENT-495: smoke test for organ-binary-freshness-selftest.sh
set -euo pipefail
S="$(cd "$(dirname "$0")/../ops" && pwd)/organ-binary-freshness-selftest.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/w" 2>/dev/null
cd "$T/w"; git checkout -q -b main; echo a > f; git add f; git commit -qm a; git push -q origin main
export CHUMP_AMBIENT_LOG="$T/amb.jsonl"
"$S" --organ t --bin-dir "$T/w" >/dev/null || { echo "FAIL: fresh should pass"; exit 1; }
[[ ! -s "$CHUMP_AMBIENT_LOG" ]] || { echo "FAIL: no event expected"; exit 1; }
git clone -q "$T/origin.git" "$T/w2"; cd "$T/w2"; echo b > f; git commit -qam b; git push -q origin HEAD:main
if "$S" --organ t --bin-dir "$T/w" 2>/dev/null; then echo "FAIL: stale should fail"; exit 1; fi
grep -q '"kind":"organ_binary_stale"' "$CHUMP_AMBIENT_LOG" || { echo "FAIL: event missing"; exit 1; }
echo "PASS"
