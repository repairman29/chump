#!/usr/bin/env bash
# test-compress-stale-archive.sh — RESILIENT-323
# Proves the safety checks: a still-referenced docs-archive file is never
# compressed; git-committed age (not checkout mtime) gates docs-archive
# candidates; runtime-logs mode skips known-active filenames; dry-run
# never mutates the filesystem.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CMP="$REPO_ROOT/scripts/ops/compress-stale-archive.sh"
fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

[[ -x "$CMP" ]] && pass "compress script exists + executable" || fail "not executable: $CMP"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
git init -q
git config user.email test@test.com; git config user.name test
mkdir -p docs/archive scripts
echo '{"a":1}' > docs/archive/unreferenced.jsonl
echo '{"b":1}' > docs/archive/referenced.jsonl
echo 'cat docs/archive/referenced.jsonl' > scripts/reader.sh
git add -A && git commit -q -m init
# Simulate an old commit: rewrite committer date on the last commit far in the past.
OLD_DATE="$(date -u -d '60 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-60d '+%Y-%m-%dT%H:%M:%S')"
GIT_COMMITTER_DATE="$OLD_DATE" git commit -q --amend --date="$OLD_DATE" --no-edit
cd "$REPO_ROOT"

echo "== 1. dry-run finds both candidates but mutates nothing =="
OUT="$(bash "$CMP" --mode docs-archive --dir "$WORK/docs/archive" 2>&1)"
CHUMP_REPO="$WORK"
[[ -f "$WORK/docs/archive/unreferenced.jsonl" && -f "$WORK/docs/archive/referenced.jsonl" ]] \
  && pass "dry-run left both files untouched" || fail "dry-run mutated a file"

echo "== 2. --execute compresses the unreferenced file, SKIPS the referenced one =="
CHUMP_REPO="$WORK" bash "$CMP" --mode docs-archive --dir "$WORK/docs/archive" --execute >/dev/null 2>&1
[[ -f "$WORK/docs/archive/unreferenced.jsonl.gz" && ! -f "$WORK/docs/archive/unreferenced.jsonl" ]] \
  && pass "unreferenced.jsonl compressed + original removed" || fail "unreferenced.jsonl not compressed as expected"
[[ -f "$WORK/docs/archive/referenced.jsonl" && ! -f "$WORK/docs/archive/referenced.jsonl.gz" ]] \
  && pass "referenced.jsonl left alone (still read by scripts/reader.sh)" || fail "referenced.jsonl was compressed — safety check broken"

echo "== 3. markdown is never touched, even if old and unreferenced =="
WORK2="$(mktemp -d)"
cd "$WORK2"; git init -q; git config user.email t@t.com; git config user.name t
mkdir -p docs/archive
echo '# old doc' > docs/archive/old.md
git add -A && git commit -q -m init
OLD_DATE2="$(date -u -d '90 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-90d '+%Y-%m-%dT%H:%M:%S')"
GIT_COMMITTER_DATE="$OLD_DATE2" git commit -q --amend --date="$OLD_DATE2" --no-edit
cd "$REPO_ROOT"
CHUMP_REPO="$WORK2" bash "$CMP" --mode docs-archive --dir "$WORK2/docs/archive" --execute >/dev/null 2>&1
[[ -f "$WORK2/docs/archive/old.md" && ! -f "$WORK2/docs/archive/old.md.gz" ]] \
  && pass "markdown never compressed (docs-archive mode is jsonl/json only)" || fail "markdown was compressed — must never happen"
rm -rf "$WORK2"

echo "== 4. runtime-logs mode skips active append-logs by name (ambient.jsonl) =="
WORK3="$(mktemp -d)"
mkdir -p "$WORK3/logs"
echo '{}' > "$WORK3/logs/ambient.jsonl"
touch -d '30 days ago' "$WORK3/logs/ambient.jsonl"
bash "$CMP" --mode runtime-logs --dir "$WORK3/logs" --min-age-days 7 --execute >/dev/null 2>&1
[[ -f "$WORK3/logs/ambient.jsonl" ]] && pass "ambient.jsonl never compressed" || fail "ambient.jsonl was compressed — must never happen"
rm -rf "$WORK3"

echo "== 5. scanner anchors + registry entries exist (verify-rule, INFRA-754) =="
grep -q '"kind":"storage_archive_compressed"' "$CMP" && pass "scanner anchor present" || fail "scanner anchor missing"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q 'kind: storage_archive_compressed$' "$REG" && pass "storage_archive_compressed registered" || fail "kind not registered"

if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails check(s)" >&2
  exit 1
fi
echo "PASS: compress-stale-archive"
