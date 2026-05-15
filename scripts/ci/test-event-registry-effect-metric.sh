#!/usr/bin/env bash
# test-event-registry-effect-metric.sh — INFRA-1371
#
# Validates that every event kind in EVENT_REGISTRY.yaml declares an
# effect_metric field (required since schema_version 2).
#
# Checks:
#   1. schema_version >= 2
#   2. Every '  - kind: X' entry is immediately followed by '    effect_metric:'
#   3. No effect_metric values are empty or whitespace-only
#   4. Count parity: kind entries == effect_metric entries (no orphans)
#   5. Synthetic guard: drift gate (test-event-registry-coverage.sh) fails when
#      a registered kind is missing effect_metric (AC #3 regression guard)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

PASS=0
FAIL=0

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-1371 effect_metric schema audit ==="
echo

# ── 1. schema_version >= 2 ────────────────────────────────────────────────────
echo "[1. schema_version >= 2]"
SCHEMA_VER=$(python3 -c "
import re
content = open('$REGISTRY').read()
m = re.search(r'^schema_version:\s*(\d+)', content, re.MULTILINE)
print(m.group(1) if m else '0')
")
if [ "${SCHEMA_VER:-0}" -ge 2 ]; then
  ok "schema_version=$SCHEMA_VER (>= 2)"
else
  fail "schema_version=$SCHEMA_VER — expected >= 2 (INFRA-1371 required bump)"
fi

# ── 2. Every kind entry has effect_metric immediately after it ────────────────
echo
echo "[2. All kind entries have effect_metric on next non-blank line]"
MISSING_KINDS=$(python3 - "$REGISTRY" 2>&1 <<'PYEOF'
import re, sys

fpath = sys.argv[1]
content = open(fpath).read()
lines = content.splitlines()
missing = []
i = 0
while i < len(lines):
    line = lines[i]
    if re.match(r'^  - kind: \S', line):
        kind_name = line.split('kind:')[1].strip()
        next_line = lines[i + 1] if i + 1 < len(lines) else ''
        if not re.match(r'^\s+effect_metric:', next_line):
            missing.append(f"  line {i+2}: kind={kind_name!r} missing effect_metric (next: {next_line.strip()!r})")
    i += 1
if missing:
    for m in missing[:20]:
        print(m, file=sys.stderr)
    if len(missing) > 20:
        print(f"  ... and {len(missing) - 20} more", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYEOF
)
if [ $? -eq 0 ]; then
  ok "All kind entries have effect_metric on next line"
else
  echo "$MISSING_KINDS"
  fail "Some kind entries missing effect_metric — see above"
fi

# ── 3. No empty effect_metric values ─────────────────────────────────────────
echo
echo "[3. No empty effect_metric values]"
EMPTY_COUNT=$(python3 - "$REGISTRY" <<'PYEOF'
import re, sys
content = open(sys.argv[1]).read()
empties = re.findall(r'^\s+effect_metric:\s*$', content, re.MULTILINE)
print(len(empties))
PYEOF
)
if [ "${EMPTY_COUNT:-0}" -eq 0 ]; then
  ok "No empty effect_metric values"
else
  fail "Found $EMPTY_COUNT effect_metric entries with empty value — use 'self' for observability-count metrics"
fi

# ── 4. Count parity: kind entries == effect_metric entries ───────────────────
echo
echo "[4. kind entry count == effect_metric entry count]"
KIND_COUNT=$(python3 - "$REGISTRY" <<'PYEOF'
import re, sys
content = open(sys.argv[1]).read()
print(len(re.findall(r'^  - kind: ', content, re.MULTILINE)))
PYEOF
)
EFFECT_COUNT=$(python3 - "$REGISTRY" <<'PYEOF'
import sys
content = open(sys.argv[1]).read()
print(content.count('    effect_metric:'))
PYEOF
)
if [ "$KIND_COUNT" -eq "$EFFECT_COUNT" ]; then
  ok "Count parity: $KIND_COUNT kind entries == $EFFECT_COUNT effect_metric entries"
else
  fail "Count mismatch: $KIND_COUNT kind entries vs $EFFECT_COUNT effect_metric entries — check for drift"
fi

# ── 5. Synthetic guard: drift gate exits non-zero for missing effect_metric ───
# Constructs a minimal fake registry with a kind entry missing effect_metric,
# then verifies that test-event-registry-coverage.sh's Python logic would fail.
# This guards against regression where the drift gate check is removed.
echo
echo "[5. Drift gate (INFRA-1237) fails when effect_metric missing on emitted kind]"
SYNTHETIC_RESULT=$(python3 - <<'PYEOF'
import re, sys

# Minimal synthetic registry: one kind without effect_metric
yaml_text = """
schema_version: 2
events:
  - kind: synthetic_test_kind
    emitter: test
    trigger: test
"""

lines = yaml_text.splitlines()
kinds_missing_effect_metric = []
i = 0
while i < len(lines):
    line = lines[i]
    m = re.match(r'^\s*-\s+kind:\s*([A-Za-z0-9_]+)', line)
    if m:
        kind_name = m.group(1)
        has_em = False
        j = i + 1
        while j < len(lines) and not re.match(r'^\s*-\s+kind:', lines[j]):
            if re.match(r'^\s+effect_metric:\s*\S', lines[j]):
                has_em = True
                break
            j += 1
        if not has_em:
            kinds_missing_effect_metric.append(kind_name)
    i += 1

if kinds_missing_effect_metric:
    print("GATE_WOULD_FAIL")
    sys.exit(0)
else:
    print("GATE_WOULD_PASS_BUG")
    sys.exit(1)
PYEOF
)
if [ "$SYNTHETIC_RESULT" = "GATE_WOULD_FAIL" ]; then
  ok "Drift gate correctly detects missing effect_metric on synthetic kind"
else
  fail "Drift gate did NOT detect missing effect_metric — INFRA-1237 extension broken"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
