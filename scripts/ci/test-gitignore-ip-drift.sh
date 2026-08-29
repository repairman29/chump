#!/usr/bin/env bash
# test-gitignore-ip-drift.sh — INFRA-1513
#
# Reads the canonical IP-protection rule set from
# docs/infra/GITIGNORE_IP_RULES.yaml and asserts every rule's pattern is
# present as a literal line in .gitignore. A rule marked `optional: true`
# produces WARN (not FAIL) when absent.
#
# Exit 0 = all non-optional rules present (optional misses allowed).
# Exit 1 = at least one non-optional rule is missing from .gitignore, or
#          the rules file / .gitignore is missing/unreadable.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
RULES_FILE="$REPO_ROOT/docs/infra/GITIGNORE_IP_RULES.yaml"
GITIGNORE="$REPO_ROOT/.gitignore"

echo "=== INFRA-1513 .gitignore IP-protection drift check ==="
echo

if [[ ! -f "$RULES_FILE" ]]; then
    echo "FAIL: canonical rules file missing: $RULES_FILE"
    exit 1
fi

if [[ ! -f "$GITIGNORE" ]]; then
    echo "FAIL: .gitignore missing at $GITIGNORE"
    exit 1
fi

# Emit one line per rule: "<pattern>\t<optional:0|1>\t<id>"
RULE_ROWS="$(python3 - "$RULES_FILE" <<'PYEOF'
import sys
import yaml

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

rules = data.get("rules") or []
if not rules:
    print("__NO_RULES__")
    sys.exit(0)

for rule in rules:
    pattern = rule.get("pattern", "")
    optional = "1" if rule.get("optional") else "0"
    rid = rule.get("id", "<unknown>")
    print(f"{pattern}\t{optional}\t{rid}")
PYEOF
)"

if [[ "$RULE_ROWS" == "__NO_RULES__" ]]; then
    echo "FAIL: $RULES_FILE has no rules defined"
    exit 1
fi

FAIL=0
WARN=0
PASS=0

while IFS=$'\t' read -r pattern optional rid; do
    [[ -z "$pattern" ]] && continue

    # Literal-line match: the exact pattern must appear as its own line
    # (ignoring leading/trailing whitespace) somewhere in .gitignore.
    if grep -qxF "$pattern" "$GITIGNORE" || grep -qxF " $pattern" "$GITIGNORE"; then
        echo "  PASS [$rid] present: $pattern"
        PASS=$((PASS + 1))
    elif [[ "$optional" == "1" ]]; then
        echo "  WARN [$rid] optional rule absent from .gitignore: $pattern"
        WARN=$((WARN + 1))
    else
        echo "  FAIL [$rid] required rule missing from .gitignore: $pattern"
        echo "       expected .gitignore to contain a line matching exactly: $pattern"
        FAIL=$((FAIL + 1))
    fi
done <<< "$RULE_ROWS"

echo
echo "=== Summary: $PASS pass, $WARN warn, $FAIL fail ==="

if [[ "$FAIL" -gt 0 ]]; then
    echo "FAIL: one or more required IP-protection rules are missing from .gitignore."
    echo "Fix: add the missing pattern(s) to .gitignore, OR if the rule is truly"
    echo "retired, remove it from $RULES_FILE in the same PR."
    exit 1
fi

echo "PASS: all required IP-protection rules are present in .gitignore."
exit 0
