#!/usr/bin/env bash
# pre-commit-hardcoded-dates.sh — INFRA-971 + INFRA-1402
#
# Refuses staged files that contain hardcoded timestamp literals likely to
# become time-bomb fixtures once a rolling window slides past them.
#
# Scanned file types:
#   src/*.rs          — ISO-8601 date/datetime inside #[test] / #[cfg(test)]
#                       blocks (original INFRA-971 check).
#   scripts/**/*.sh   — ISO-8601 date/datetime inside Python/bash heredocs
#                       (INFRA-1402: caught INFRA-1368 class: `now =
#                       "2026-05-15T22:00:00Z"` hardcoded inside <<PYEOF).
#   **/*.py           — `now`/`current_ts` assigned to string literal,
#                       or datetime.datetime(YYYY,...) constructor calls.
#
# Bypass:
#   Append to the offending line:
#     # chump-fmt: time-bomb-ok   (Python / heredoc)
#     // chump-fmt: time-bomb-ok  (Rust)
#   Suppress entire guard for one commit:
#     CHUMP_HARDCODED_DATE_CHECK=0 git commit ...
#     (add `Hardcoded-Date-Bypass: <reason>` trailer to commit body)

set -uo pipefail

if [[ "${CHUMP_HARDCODED_DATE_CHECK:-1}" == "0" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Collect staged files by type.
# Shell scan is limited to scripts/ci/ and scripts/ops/ — those are the
# directories that contain test fixtures. The git-hooks/ directory itself
# is excluded to avoid false-positives from error-message example strings.
STAGED_RS=$(git diff --cached --name-only --diff-filter=ACM -- 'src/*.rs' 2>/dev/null || true)
STAGED_SH=$(git diff --cached --name-only --diff-filter=ACM -- 'scripts/ci/*.sh' 'scripts/ops/*.sh' 'tests/*.sh' 2>/dev/null || true)
STAGED_PY=$(git diff --cached --name-only --diff-filter=ACM -- '*.py' 'scripts/ci/*.py' 'scripts/ops/*.py' 2>/dev/null || true)

if [[ -z "$STAGED_RS" && -z "$STAGED_SH" && -z "$STAGED_PY" ]]; then
    exit 0
fi

# Python does the heavy lifting: context-aware scanners for each file type.
python3 - "$REPO_ROOT" "$STAGED_RS" "$STAGED_SH" "$STAGED_PY" << 'PYEOF'
import subprocess, sys, re

repo_root    = sys.argv[1]
staged_rs    = sys.argv[2].split() if sys.argv[2] else []
staged_sh    = sys.argv[3].split() if sys.argv[3] else []
staged_py    = sys.argv[4].split() if sys.argv[4] else []

date_re      = re.compile(r'"(\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}Z?)?)"')
bypass_rust  = re.compile(r'//\s*chump-fmt:\s*time-bomb-ok')
bypass_py    = re.compile(r'#\s*chump-fmt:\s*time-bomb-ok')
# Python/heredoc patterns added by INFRA-1402:
#   now = "2026-..."  / current_ts = "2026-..."
now_assign_re = re.compile(
    r'^\s*(now|current_ts|current_time|start_ts|end_ts)\s*=\s*["\'](\d{4}-\d{2}-\d{2}'
    r'(?:T\d{2}:\d{2}:\d{2}Z?)?)["\']')
#   datetime.datetime(2026, ...) constructor literal
dt_ctor_re   = re.compile(r'datetime\.datetime\(\s*(\d{4})\s*,')
#   bare ISO-8601 string comparison / age-math (e.g. `>= "2026-05-15"`)
py_iso_cmp_re = re.compile(r'["\'](\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}Z?)?)["\']')

def get_added_line_numbers(path):
    """Return a set of 1-based line numbers that are newly added in the staged diff."""
    result = subprocess.run(
        ['git', 'diff', '--cached', '-U0', '--', path],
        capture_output=True, text=True, cwd=repo_root
    )
    added = set()
    current_line = 0
    for line in result.stdout.splitlines():
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

def get_file_lines(path):
    result = subprocess.run(
        ['git', 'show', f':{path}'],
        capture_output=True, text=True, cwd=repo_root
    )
    if result.returncode != 0:
        return []
    return result.stdout.splitlines()

# ── Rust scanner (original INFRA-971) ────────────────────────────────────────

def scan_rs(path, added_lines):
    lines = get_file_lines(path)
    violations = []
    in_test_attr  = False
    in_test_block = False
    brace_depth   = 0
    test_depth    = 0

    for i, raw in enumerate(lines, 1):
        stripped = raw.strip()
        if stripped in ('#[test]', '#[cfg(test)]') or re.match(r'#\[cfg\(test', stripped):
            in_test_attr = True
        if in_test_attr and '{' in stripped and not in_test_block:
            in_test_block = True
            in_test_attr  = False
            test_depth    = brace_depth
        if in_test_block:
            brace_depth += stripped.count('{') - stripped.count('}')
            if brace_depth <= test_depth:
                in_test_block = False
        if not in_test_block:
            if not in_test_attr:
                brace_depth += stripped.count('{') - stripped.count('}')
            continue
        if i not in added_lines:
            continue
        m = date_re.search(raw)
        if m and not bypass_rust.search(raw):
            violations.append((i, m.group(0), raw.strip()[:80]))
    return violations

# ── Python/heredoc scanner (INFRA-1402) ─────────────────────────────────────

# Patterns that indicate a line is inside a "test context" in Python/shell:
# We treat ALL lines as candidates in .sh heredocs and .py test files.
# The burden is low: any new date literal must be either dynamic or bypassed.

def scan_py_lines(lines, added_lines, bypass_re_used, path_label):
    """Scan a list of (original_lineno, text) pairs for time-bomb patterns."""
    violations = []
    for lineno, raw in lines:
        if lineno not in added_lines:
            continue
        stripped = raw.strip()
        if bypass_re_used.search(raw):
            continue
        # Pattern (b): variable assignment to literal timestamp
        m = now_assign_re.match(raw)
        if m:
            violations.append((lineno, f'{m.group(1)} = "{m.group(2)}"', raw.strip()[:80]))
            continue
        # Pattern (c): datetime.datetime(YYYY, ...) constructor
        m = dt_ctor_re.search(raw)
        if m:
            violations.append((lineno, f'datetime.datetime({m.group(1)}, ...)', raw.strip()[:80]))
            continue
        # Pattern (a): bare ISO-8601 string used in age math
        # Only flag when the same line also contains comparison operators or
        # age-related keywords to limit false positives.
        if re.search(r'(age|max_age|window|since|before|after|older|<=|>=|< |> )', raw, re.IGNORECASE):
            m2 = py_iso_cmp_re.search(raw)
            if m2:
                violations.append((lineno, f'"{m2.group(1)}"', raw.strip()[:80]))
    return violations

def scan_sh_for_heredocs(path, added_lines):
    """Extract Python/bash heredoc blocks and scan them for time-bomb patterns."""
    lines = get_file_lines(path)
    violations = []
    in_heredoc  = False
    heredoc_end = None
    heredoc_lineno_offset = 0  # original file line of heredoc open

    for i, raw in enumerate(lines, 1):
        stripped = raw.strip()
        if not in_heredoc:
            # Detect heredoc open: << 'PYEOF' / <<PYEOF / <<"PYEOF" etc.
            m = re.search(r"<<'?\"?([A-Z_a-z][A-Z_a-z0-9]*)'?\"?", raw)
            if m:
                in_heredoc = True
                heredoc_end = m.group(1)
                heredoc_lineno_offset = i
        else:
            if stripped == heredoc_end:
                in_heredoc = False
                heredoc_end = None
                continue
            # Scan heredoc line for time-bomb patterns; lineno is file line i.
            viols = scan_py_lines([(i, raw)], added_lines, bypass_py, path)
            violations.extend(viols)
    return violations

def scan_py_file(path, added_lines):
    """Scan a Python file for time-bomb patterns in added lines."""
    lines = get_file_lines(path)
    indexed = [(i + 1, line) for i, line in enumerate(lines)]
    return scan_py_lines(indexed, added_lines, bypass_py, path)

# ── Run all scanners ─────────────────────────────────────────────────────────

all_violations = []

for path in staged_rs:
    added = get_added_line_numbers(path)
    if not added:
        continue
    for lineno, date_str, snippet in scan_rs(path, added):
        all_violations.append((path, lineno, date_str, snippet))

for path in staged_sh:
    added = get_added_line_numbers(path)
    if not added:
        continue
    for lineno, date_str, snippet in scan_sh_for_heredocs(path, added):
        all_violations.append((path, lineno, date_str, snippet))

for path in staged_py:
    added = get_added_line_numbers(path)
    if not added:
        continue
    for lineno, date_str, snippet in scan_py_file(path, added):
        all_violations.append((path, lineno, date_str, snippet))

if not all_violations:
    sys.exit(0)

print('', file=sys.stderr)
print('─' * 70, file=sys.stderr)
print('❌ INFRA-971/1402 hardcoded-date guard blocked this commit.', file=sys.stderr)
print('', file=sys.stderr)
print('Hardcoded timestamp literals in test fixtures expire when a rolling', file=sys.stderr)
print('window slides past them. This guard catches:', file=sys.stderr)
print('  (a) ISO-8601 date strings in Rust #[test] blocks (INFRA-971)', file=sys.stderr)
print('  (b) now/current_ts = "YYYY-..." assignments in Python / heredocs', file=sys.stderr)
print('  (c) datetime.datetime(YYYY,...) constructor calls in test fixtures', file=sys.stderr)
print('  (d) ISO-8601 literals in age/window comparison expressions', file=sys.stderr)
print('Root causes on record: infra537 trio (2026-05-13), INFRA-1368 (2026-05-16).', file=sys.stderr)
print('', file=sys.stderr)
print('Violations:', file=sys.stderr)
for path, lineno, date_str, snippet in all_violations:
    print(f'  {path}:{lineno}  {date_str}', file=sys.stderr)
    print(f'    {snippet}', file=sys.stderr)
print('', file=sys.stderr)
print('Fix: use a dynamic relative timestamp instead of a hardcoded one:', file=sys.stderr)
print('  Rust:   let t = recent_iso(3600);  // 1h ago', file=sys.stderr)
print('  Python: import time; now = datetime.utcnow().strftime(\'%Y-%m-%dT%H:%M:%SZ\')', file=sys.stderr)
print('  Shell:  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)', file=sys.stderr)
print('', file=sys.stderr)
print('To whitelist a line (epoch sentinels, parse-unit tests, etc.):', file=sys.stderr)
print('  Rust:   append  // chump-fmt: time-bomb-ok  to that line', file=sys.stderr)
print('  Python/shell: append  # chump-fmt: time-bomb-ok  to that line', file=sys.stderr)
print('', file=sys.stderr)
print('Bypass entire guard once (requires Hardcoded-Date-Bypass: trailer):', file=sys.stderr)
print('  CHUMP_HARDCODED_DATE_CHECK=0 git commit ...', file=sys.stderr)
print('─' * 70, file=sys.stderr)
sys.exit(1)
PYEOF
