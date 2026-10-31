#!/usr/bin/env bash
# ZERO-WASTE-125: CI gate — CLAUDE.md / AGENTS.md must stay within the ratcheted
# ceilings in docs/observability/RULE_REGISTRY.yaml (one-in-one-out: to add a rule
# at budget, remove one, then ratchet the ceiling down), and every git hook must
# have a registry entry.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
REG=docs/observability/RULE_REGISTRY.yaml
fail=0
ceil() { awk -v k="$1" '$0 ~ "^  "k":" {f=1} f && /ceiling_lines:/ {print $2; exit}' "$REG"; }
for pair in "claude_md:CLAUDE.md" "agents_md:AGENTS.md"; do
  key=${pair%%:*}; file=${pair#*:}
  c=$(ceil "$key"); n=$(wc -l < "$file")
  if [ -z "$c" ]; then echo "[FAIL] no ceiling for $key in $REG"; fail=1
  elif [ "$n" -gt "$c" ]; then echo "[FAIL] $file is $n lines > ceiling $c (one-in-one-out: remove a rule first)"; fail=1
  else echo "[PASS] $file $n <= $c"; fi
done
for h in scripts/git-hooks/*; do
  [ -f "$h" ] || continue
  b=$(basename "$h")
  case "$b" in *.sh|*.md|*.txt|*.py) continue;; esac
  grep -q "$h" "$REG" || { echo "[FAIL] git hook $h has no entry in $REG"; fail=1; }
done
exit $fail
