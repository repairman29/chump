#!/usr/bin/env bash
# test-gitignore-ip-drift.sh — INFRA-1513
#
# Reads the canonical IP-protection rule set from
# docs/infra/GITIGNORE_IP_RULES.yaml and asserts every non-optional rule's
# pattern is present as an exact line in .gitignore. Catches the case where
# a rule is silently dropped from .gitignore (or GITIGNORE_IP_RULES.yaml is
# edited to remove a rule) without a corresponding intentional change to
# both files.
#
# Exit codes:
#   0 — all required rules present (optional rules may WARN)
#   1 — at least one required (non-optional) rule missing from .gitignore
#
# Usage:
#   bash scripts/ci/test-gitignore-ip-drift.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

RULES_FILE="docs/infra/GITIGNORE_IP_RULES.yaml"
GITIGNORE_FILE=".gitignore"

if [ ! -f "$RULES_FILE" ]; then
  echo "FAIL: canonical rules file missing: $RULES_FILE"
  exit 1
fi

if [ ! -f "$GITIGNORE_FILE" ]; then
  echo "FAIL: $GITIGNORE_FILE missing from repo root"
  exit 1
fi

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "SKIP: PyYAML not available in this environment — cannot parse $RULES_FILE"
  exit 0
fi

RESULT="$(python3 - "$RULES_FILE" "$GITIGNORE_FILE" <<'PYEOF'
import sys
import yaml

rules_path, gitignore_path = sys.argv[1], sys.argv[2]

with open(rules_path) as f:
    data = yaml.safe_load(f) or {}

rules = data.get("rules") or []

with open(gitignore_path) as f:
    gitignore_lines = {line.strip() for line in f if line.strip() and not line.strip().startswith("#")}

missing_required = []
missing_optional = []

for rule in rules:
    name = rule.get("name", "<unnamed>")
    pattern = rule.get("pattern")
    optional = bool(rule.get("optional", False))
    if pattern is None:
        missing_required.append((name, "<no pattern specified>"))
        continue
    if pattern.strip() not in gitignore_lines:
        if optional:
            missing_optional.append((name, pattern))
        else:
            missing_required.append((name, pattern))

for name, pattern in missing_optional:
    print(f"WARN\t{name}\t{pattern}")

for name, pattern in missing_required:
    print(f"FAIL\t{name}\t{pattern}")

if not missing_required:
    print(f"OK\t{len(rules)} rules checked, {len(missing_optional)} optional missing")
PYEOF
)"

status=0
while IFS=$'\t' read -r kind name pattern; do
  case "$kind" in
    WARN)
      echo "WARN: optional IP-protection rule '$name' absent from .gitignore (expected pattern: $pattern)"
      ;;
    FAIL)
      echo "FAIL: IP-protection rule '$name' missing from .gitignore (expected pattern: $pattern)"
      status=1
      ;;
    OK)
      echo "OK: $name"
      ;;
  esac
done <<< "$RESULT"

if [ "$status" -ne 0 ]; then
  echo ""
  echo "One or more canonical IP-protection rules (docs/infra/GITIGNORE_IP_RULES.yaml)"
  echo "are missing from .gitignore. Either restore the pattern to .gitignore, or if"
  echo "the rule is genuinely obsolete, remove it from GITIGNORE_IP_RULES.yaml in the"
  echo "same PR (with justification in the commit message)."
fi

exit "$status"
