#!/usr/bin/env bash
# scripts/ci/test-gitignore-ip-drift.sh — INFRA-1513
#
# Asserts every non-optional rule in docs/infra/GITIGNORE_IP_RULES.yaml has
# its `pattern` present as a line in .gitignore. Optional rules that are
# absent produce a WARN instead of a FAIL (escape hatch, AC5).
#
# Exit 0: all non-optional rules present (optional gaps only WARN).
# Exit 1: at least one non-optional rule is missing from .gitignore.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RULES_YAML="$REPO_ROOT/docs/infra/GITIGNORE_IP_RULES.yaml"
GITIGNORE="$REPO_ROOT/.gitignore"

if [[ ! -f "$RULES_YAML" ]]; then
    echo "FAIL: canonical rules file missing: $RULES_YAML" >&2
    exit 1
fi

if [[ ! -f "$GITIGNORE" ]]; then
    echo "FAIL: .gitignore missing at repo root" >&2
    exit 1
fi

PYTHON3="$(command -v python3 || true)"
if [[ -z "$PYTHON3" ]]; then
    echo "FAIL: python3 not found (required to parse $RULES_YAML)" >&2
    exit 1
fi

# Emits one line per rule: "<id>\t<pattern>\t<optional:0|1>"
RULES_TSV="$("$PYTHON3" - "$RULES_YAML" <<'PYEOF'
import sys
import yaml

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}

for rule in data.get("rules", []):
    rule_id = rule.get("id", "")
    pattern = rule.get("pattern", "")
    optional = "1" if rule.get("optional", False) else "0"
    print(f"{rule_id}\t{pattern}\t{optional}")
PYEOF
)"

if [[ -z "$RULES_TSV" ]]; then
    echo "FAIL: no rules found in $RULES_YAML" >&2
    exit 1
fi

FAIL_COUNT=0
WARN_COUNT=0

while IFS=$'\t' read -r rule_id pattern optional; do
    [[ -z "$rule_id" ]] && continue
    if grep -qxF "$pattern" "$GITIGNORE"; then
        continue
    fi
    if [[ "$optional" == "1" ]]; then
        echo "WARN: optional rule '$rule_id' absent from .gitignore — expected pattern: $pattern"
        WARN_COUNT=$((WARN_COUNT + 1))
    else
        echo "FAIL: rule '$rule_id' absent from .gitignore — expected pattern: $pattern" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done <<< "$RULES_TSV"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "FAIL: $FAIL_COUNT required IP-protection rule(s) missing from .gitignore ($WARN_COUNT warning(s))" >&2
    exit 1
fi

echo "PASS: all $(echo "$RULES_TSV" | wc -l | tr -d ' ') canonical IP-protection rule(s) checked ($WARN_COUNT warning(s))"
exit 0
