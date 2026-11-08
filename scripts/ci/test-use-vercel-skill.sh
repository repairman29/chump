#!/usr/bin/env bash
# INFRA-8172: use-vercel skill is present, well-formed, distributable, and pointed to.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/.claude/skills/use-vercel/SKILL.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$S" ] || fail "missing $S"
head -1 "$S" | grep -qx -- '---' || fail "no frontmatter"
grep -q '^name: use-vercel$' "$S" || fail "frontmatter name"
grep -q '^description: .\+' "$S" || fail "frontmatter description"
[ ! -e "$ROOT/.agents/skills/use-vercel" ] || fail "must not live in .agents/skills"
grep -q '\.claude/skills/use-vercel' "$ROOT/CLAUDE.md" || fail "CLAUDE.md pointer missing"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
bash "$ROOT/scripts/setup/sync-use-vercel-skill.sh" "$T/skills" >/dev/null
cmp -s "$S" "$T/skills/use-vercel/SKILL.md" || fail "sync copy differs"
if bash "$ROOT/scripts/setup/sync-use-vercel-skill.sh" "$T/.agents/skills" >/dev/null 2>&1; then fail "should refuse .agents/skills"; fi
echo "PASS test-use-vercel-skill"
