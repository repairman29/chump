#!/usr/bin/env bash
# ZERO-WASTE-125: rulebook line budget + registry completeness.
# CLAUDE.md <= 150, AGENTS.md <= 300; new gates must be in docs/process/RULE_REGISTRY.tsv.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
chk() { n=$(wc -l < "$1"); if [ "$n" -gt "$2" ]; then echo "FAIL: $1 is $n lines (budget $2) — remove a rule before adding one"; fail=1; else echo "ok: $1 $n/$2"; fi; }
chk CLAUDE.md 150
chk AGENTS.md 300
python3 scripts/ops/rules-registry.py check || fail=1
exit $fail
