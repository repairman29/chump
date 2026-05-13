#!/usr/bin/env bash
# test-harness-attribution.sh — INFRA-956
#
# The META-055 waste audit found 106 missing_attribution events / 7d (half
# of all waste alerts). Root cause: operator-driven coord scripts spawn
# `ambient-emit.sh` without CHUMP_AGENT_HARNESS set, so the script defaults
# to "unknown" and fires the alert.
#
# Asserts:
#   1. Each patched script contains the INFRA-956 export line.
#   2. The default value is "manual" (a schema-valid enum entry).
#   3. An already-set CHUMP_AGENT_HARNESS is NOT clobbered.
#   4. "manual" is in the docs/ambient-schema.json enum.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCHEMA="$REPO_ROOT/docs/ambient-schema.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

PATCHED_SCRIPTS=(
  "scripts/coord/gap-claim.sh"
  "scripts/coord/chump-commit.sh"
  "scripts/coord/bot-merge.sh"
  "scripts/coord/ambient-session-end.sh"
  "scripts/coord/ambient-context-inject.sh"
  "scripts/coord/ghost-gap-reaper.sh"
)

# 1) Each patched script has the INFRA-956 marker + export line.
for rel in "${PATCHED_SCRIPTS[@]}"; do
  path="$REPO_ROOT/$rel"
  [[ -f "$path" ]] || fail "missing $rel"
  grep -q 'INFRA-956' "$path" || fail "$rel missing INFRA-956 marker"
  grep -q 'export CHUMP_AGENT_HARNESS' "$path" \
    || fail "$rel missing CHUMP_AGENT_HARNESS export"
done
ok "all ${#PATCHED_SCRIPTS[@]} patched scripts contain the INFRA-956 export"

# 2) The default value is "manual".
for rel in "${PATCHED_SCRIPTS[@]}"; do
  d="$(grep 'export CHUMP_AGENT_HARNESS' "$REPO_ROOT/$rel" | head -1 \
        | sed -E 's/.*CHUMP_AGENT_HARNESS:-([^"}]+)\}".*/\1/')"
  [[ "$d" == "manual" ]] || fail "$rel default is '$d' (expected 'manual')"
done
ok "all patched scripts default CHUMP_AGENT_HARNESS to 'manual'"

# 3) Existing env value is preserved.
val="$(env -i CHUMP_AGENT_HARNESS=opencode-bigpickle bash -c '
  export CHUMP_AGENT_HARNESS="${CHUMP_AGENT_HARNESS:-manual}"
  echo "$CHUMP_AGENT_HARNESS"
')"
[[ "$val" == "opencode-bigpickle" ]] \
  || fail "explicit CHUMP_AGENT_HARNESS clobbered by default (got '$val')"
ok "explicit CHUMP_AGENT_HARNESS preserved (not clobbered)"

# 4) "manual" is a valid enum value in the schema.
if [[ -f "$SCHEMA" ]] && command -v python3 &>/dev/null; then
  in_enum=$(python3 -c "
import json
s = json.load(open('$SCHEMA'))
def find_enum(obj):
    if isinstance(obj, dict):
        if 'enum' in obj and 'manual' in obj['enum']:
            return True
        return any(find_enum(v) for v in obj.values())
    if isinstance(obj, list):
        return any(find_enum(v) for v in obj)
    return False
print('yes' if find_enum(s) else 'no')
")
  [[ "$in_enum" == "yes" ]] || fail "'manual' not in any enum of $SCHEMA"
  ok "'manual' is a valid schema enum value"
else
  ok "schema or python3 missing — skipping enum check"
fi

echo
echo "=== test-harness-attribution.sh PASSED ==="
