#!/usr/bin/env bash
# pre-commit-hardcoded-dates.sh — INFRA-971
#
# Refuses staged src/*.rs additions that place a hardcoded YYYY-MM-DD
# timestamp literal inside a #[test] or #[cfg(test)] block.
#
# Motivation:
#   Rolling-window test windows (e.g. 7d, 30d) expire once today's date
#   slides past the hardcoded literal.  The INFRA-537 infra537_* trio
#   started failing on 2026-05-13 because their fixture used "2026-05-06"
#   timestamps that fell outside the 7-day window.
#
#   Use dynamic timestamps (recent_iso(secs) helper, or std::time::SystemTime)
#   instead of hardcoded date strings in test fixtures.
#
# Bypass:
#   Append to the offending line:   // chump-fmt: time-bomb-ok
#   Suppress entire guard for one commit:
#     CHUMP_HARDCODED_DATE_CHECK=0 git commit ...
#     (add `Hardcoded-Date-Bypass: <reason>` trailer to commit body)

set -uo pipefail

if [[ "${CHUMP_HARDCODED_DATE_CHECK:-1}" == "0" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Collect staged .rs files in src/
STAGED_RS=$(git diff --cached --name-only --diff-filter=ACM -- 'src/*.rs' 2>/dev/null || true)
if [[ -z "$STAGED_RS" ]]; then
    exit 0
fi

# Python does the heavy lifting: context-aware test-block detector.
python3 - "$REPO_ROOT" "$STAGED_RS" << 'PYEOF'
import subprocess, sys, re

repo_root = sys.argv[1]
staged_files = sys.argv[2].split() if sys.argv[2] else []

date_re   = re.compile(r'"(\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}Z?)?)"')
bypass_re = re.compile(r'//\s*chump-fmt:\s*time-bomb-ok')

def get_added_line_numbers(path):
    """Return a set of 1-based line numbers that are newly added in the staged diff."""
    result = subprocess.run(
        ['git', 'diff', '--cached', '-U0', '--', path],
        capture_output=True, text=True, cwd=repo_root
    )
    added = set()
    current_line = 0
    for line in result.stdout.splitlines():
        # @@ -a[,b] +c[,d] @@ — new file starts at line c, spans d lines
        if line.startswith('@@'):
            m = re.search(r'\+(\d+)(?:,(\d+))?', line)
            if m:
                current_line = int(m.group(1))
            continue
        if line.startswith('+') and not line.startswith('+++'):
            added.add(current_line)
            current_line += 1
        elif not line.startswith('-'):
            current_line += 1
    return added

def scan_file(path, added_lines):
    """Return list of (lineno, date_str, context_snippet) for violations."""
    result = subprocess.run(
        ['git', 'show', f':{path}'],
        capture_output=True, text=True, cwd=repo_root
    )
    if result.returncode != 0:
        return []

    lines = result.stdout.splitlines()
    violations = []
    in_test_attr = False   # saw #[test] or #[cfg(test)], expecting fn opening
    in_test_block = False  # currently inside a #[test] fn or #[cfg(test)] module
    brace_depth   = 0
    test_depth    = 0      # brace depth at the time we entered test context

    for i, raw in enumerate(lines, 1):
        stripped = raw.strip()

        # Detect test-context entry points
        if stripped in ('#[test]', '#[cfg(test)]') or re.match(r'#\[cfg\(test', stripped):
            in_test_attr = True

        if in_test_attr and '{' in stripped and not in_test_block:
            in_test_block = True
            in_test_attr  = False
            test_depth    = brace_depth  # depth before this opening brace

        if in_test_block:
            brace_depth += stripped.count('{') - stripped.count('}')
            if brace_depth <= test_depth:
                in_test_block = False

        if not in_test_block:
            # Still track depth for non-test lines
            if not in_test_attr:
                brace_depth += stripped.count('{') - stripped.count('}')
            continue

        # Only care about newly-added lines
        if i not in added_lines:
            continue

        m = date_re.search(raw)
        if m and not bypass_re.search(raw):
            violations.append((i, m.group(0), raw.strip()[:80]))

    return violations

all_violations = []
for path in staged_files:
    added = get_added_line_numbers(path)
    if not added:
        continue
    viols = scan_file(path, added)
    for lineno, date_str, snippet in viols:
        all_violations.append((path, lineno, date_str, snippet))

if not all_violations:
    sys.exit(0)

print('', file=sys.stderr)
print('─' * 70, file=sys.stderr)
print('❌ INFRA-971 hardcoded-date guard blocked this commit.', file=sys.stderr)
print('', file=sys.stderr)
print('Hardcoded YYYY-MM-DD literals in #[test] blocks expire when a', file=sys.stderr)
print('rolling window slides past them (e.g. 7d filter in ship_quality).', file=sys.stderr)
print('Root cause on record: infra537 trio failed 2026-05-13.', file=sys.stderr)
print('', file=sys.stderr)
print('Violations:', file=sys.stderr)
for path, lineno, date_str, snippet in all_violations:
    print(f'  {path}:{lineno}  {date_str}', file=sys.stderr)
    print(f'    {snippet}', file=sys.stderr)
print('', file=sys.stderr)
print('Fix: replace with a dynamic relative timestamp:', file=sys.stderr)
print('  let t = recent_iso(3600);  // 1 hour ago (ship_quality helper)', file=sys.stderr)
print('  let t = recent_iso(0);     // now', file=sys.stderr)
print('  // or std::time::', file=sys.stderr)
print('  //   SystemTime::now() - Duration::from_secs(N)', file=sys.stderr)
print('', file=sys.stderr)
print('To whitelist a line (epoch sentinels, parse-unit tests, etc.):', file=sys.stderr)
print('  append  // chump-fmt: time-bomb-ok  to that line', file=sys.stderr)
print('', file=sys.stderr)
print('Bypass entire guard once (requires Hardcoded-Date-Bypass: trailer):', file=sys.stderr)
print('  CHUMP_HARDCODED_DATE_CHECK=0 git commit ...', file=sys.stderr)
print('─' * 70, file=sys.stderr)
sys.exit(1)
PYEOF
