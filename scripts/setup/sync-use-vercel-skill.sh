#!/usr/bin/env bash
# Distribute the use-vercel skill (INFRA-8172) to non-repo agent skill dirs.
# Usage: sync-use-vercel-skill.sh [extra-skills-dir ...]
# Defaults: ~/Projects/.claude/skills and $CHUMP_FLEET_SKILLS_DIR (if set).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/.claude/skills/use-vercel/SKILL.md"
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }
dests=("$@")
if [ ${#dests[@]} -eq 0 ]; then
  dests=("$HOME/Projects/.claude/skills")
  [ -n "${CHUMP_FLEET_SKILLS_DIR:-}" ] && dests+=("$CHUMP_FLEET_SKILLS_DIR")
fi
for d in "${dests[@]}"; do
  case "$d" in */.agents/skills*) echo "refusing .agents/skills (never loaded): $d" >&2; exit 1;; esac
  mkdir -p "$d/use-vercel"
  cp "$SRC" "$d/use-vercel/SKILL.md"
  echo "synced -> $d/use-vercel/SKILL.md"
done
