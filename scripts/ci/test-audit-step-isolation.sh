#!/usr/bin/env bash
# test-audit-step-isolation.sh — RESILIENT-044
#
# Root cause of RESILIENT-044: the `audit` required gate used to run many
# scripts/ci/test-*.sh sub-tests chained inside a small number of `run:`
# blocks. When a script mid-chain failed on a bare non-[FAIL]-formatted exit
# (e.g. `set -e` tripping on an unrelated command before that script's own
# fail() helper fired), the job showed 31 clean [PASS] lines and then a bare
# `exit 1` with no indication of which sub-test was responsible — the GitHub
# UI attributes the whole multi-script `run:` block to one step, so the
# failure was invisible to anyone not willing to bisect the step manually.
#
# By the time this gap was picked, INFRA-2452 (audit moved to its own
# workflow) and INFRA-2565 (audit split into the audit-shard matrix) had
# already restructured audit.yml so each scripts/ci/test-*.sh invocation is
# its own named GitHub Actions step — a step failure is now directly
# attributable by step name, with no wrapper to swallow it. This test is the
# regression guard: it fails the build if that isolation is ever undone by a
# future edit that chains multiple scripts/ci/test-*.sh calls back into one
# `run:` block.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUDIT_YML="$REPO_ROOT/.github/workflows/audit.yml"

[[ -f "$AUDIT_YML" ]] || { echo "[FAIL] $AUDIT_YML missing" >&2; exit 2; }

echo "=== RESILIENT-044 audit-step isolation guard ==="

python3 - "$AUDIT_YML" <<'PY'
import re
import sys

path = sys.argv[1]
src = open(path).read()
lines = src.splitlines()

# Walk `run:` blocks. A block starts at a line matching `run: |` or a bare
# `run: <cmd>` and (for the `|` form) continues while subsequent lines are
# indented deeper than the `run:` line itself.
fails = []
checked = 0
i = 0
test_re = re.compile(r'scripts/ci/test-[A-Za-z0-9_-]+\.sh')

while i < len(lines):
    line = lines[i]
    m = re.match(r'^(\s+)run:\s*(.*)$', line)
    if not m:
        i += 1
        continue
    indent = len(m.group(1))
    rest = m.group(2).strip()
    block = []
    if rest in ('', '|', '|-', '>', '>-'):
        # block-scalar form (`run: |` etc) — following deeper-indented lines
        # (plus blank lines) are the command body.
        j = i + 1
        while j < len(lines):
            l = lines[j]
            if l.strip() == '' or len(l) - len(l.lstrip(' ')) > indent:
                block.append(l)
                j += 1
                continue
            break
    else:
        # single-line `run: <cmd>` form — the command is on this line.
        block.append(rest)
        j = i + 1
    block_text = '\n'.join(block)
    scripts = sorted(set(test_re.findall(block_text)))
    if len(scripts) > 1:
        fails.append((i + 1, scripts))
    else:
        checked += 1
    i = j

print(f"  run: blocks scanned: {checked + len(fails)}, single-test-script blocks: {checked}")
if fails:
    for line_no, scripts in fails:
        print(f"  FAIL line {line_no}: run: block invokes {len(scripts)} test scripts in one step: {scripts}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY

if [[ $? -eq 0 ]]; then
    echo "[PASS] every audit.yml run: block invokes at most one scripts/ci/test-*.sh — sub-test failures stay individually attributable"
else
    echo "[FAIL: audit.yml run: block chains multiple scripts/ci/test-*.sh scripts — reintroduces the RESILIENT-044 silent-exit-1 class]" >&2
    exit 1
fi
