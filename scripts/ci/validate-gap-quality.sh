#!/usr/bin/env bash
# validate-gap-quality.sh — INFRA-904
#
# Validates quality of gap YAML files in docs/gaps/. Runs on every PR
# that touches docs/gaps/*.yaml to catch vague or incomplete gaps early.
#
# Checks per gap:
#   1. acceptance_criteria non-empty (not null/empty list)
#   2. No TODO/TBD/fill-in placeholder text in acceptance_criteria
#   3. priority in P0-P3
#   4. effort in xs, s, m, l, xl
#   5. domain non-empty
#   6. title non-empty
#   7. status present
#
# Usage:
#   validate-gap-quality.sh [--files "path1 path2 ..."] [--dir docs/gaps]
#                           [--strict] [--json]
#
# Options:
#   --files "paths"    Specific YAML files to check (default: all docs/gaps/*.yaml)
#   --dir PATH         Directory of gap YAMLs (default: docs/gaps)
#   --strict           Treat warnings as errors (exit non-zero for missing fields)
#   --json             Output machine-readable JSON summary
#
# Exit codes:
#   0 = all gaps pass
#   1 = one or more violations found

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
GAPS_DIR="$REPO_ROOT/docs/gaps"
STRICT=0
JSON_OUT=0
SPECIFIC_FILES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --files)  SPECIFIC_FILES="$2"; shift 2 ;;
        --dir)    GAPS_DIR="$2";       shift 2 ;;
        --strict) STRICT=1;            shift ;;
        --json)   JSON_OUT=1;          shift ;;
        -h|--help)
            echo "Usage: validate-gap-quality.sh [--files 'paths'] [--dir DIR] [--strict] [--json]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Collect files to check ────────────────────────────────────────────────────
if [[ -n "$SPECIFIC_FILES" ]]; then
    _file_list="$SPECIFIC_FILES"
else
    _file_list=$(find "$GAPS_DIR" -name '*.yaml' -type f 2>/dev/null | sort | tr '\n' ' ')
fi

if [[ -z "$_file_list" ]]; then
    echo "[validate-gap-quality] No gap YAML files found in $GAPS_DIR"
    exit 0
fi

# ── Validate each file ────────────────────────────────────────────────────────
python3 - <<PYEOF
import sys, json, re
from pathlib import Path

_file_list_str = """$_file_list"""

VALID_PRIORITIES = {'P0', 'P1', 'P2', 'P3'}
VALID_EFFORTS    = {'xs', 's', 'm', 'l', 'xl'}
TODO_RE = re.compile(r'\b(TODO|TBD|fill.?in|<fill|placeholder)\b', re.I)

violations = []
warnings   = []
passed     = 0
strict     = $STRICT

def check_file(path_str):
    path = Path(path_str)
    if not path.exists():
        return  # Skip missing files (e.g. deleted in this PR)

    # Simple YAML extraction without a YAML parser dependency
    content = path.read_text(errors='replace')
    basename = path.name

    # Extract fields using regex (robust enough for chump gap YAML format)
    def extract(key):
        m = re.search(rf'^  {key}:\s*(.+)$', content, re.MULTILINE)
        return m.group(1).strip() if m else ''

    gap_id    = extract('id') or path.stem
    priority  = extract('priority')
    effort    = extract('effort')
    domain    = extract('domain')
    title     = extract('title')
    status    = extract('status')

    # acceptance_criteria: look for any content after the key
    ac_block = ''
    m = re.search(r'^  acceptance_criteria:\n((?:    .+\n?)*)', content, re.MULTILINE)
    if m:
        ac_block = m.group(1).strip()

    file_violations = []
    file_warnings   = []

    # 1. acceptance_criteria non-empty
    if not ac_block or ac_block in ('[]', '- []', '~', 'null', '- ""', '- \'\''):
        file_violations.append('acceptance_criteria is empty or null')
    else:
        # 2. No TODO/TBD placeholders
        if TODO_RE.search(ac_block):
            file_violations.append('acceptance_criteria contains TODO/TBD placeholder(s)')

    # 3. priority in P0-P3
    if priority and priority not in VALID_PRIORITIES:
        file_violations.append(f'priority "{priority}" not in {sorted(VALID_PRIORITIES)}')
    elif not priority:
        file_warnings.append('priority field missing')

    # 4. effort in valid set
    if effort and effort not in VALID_EFFORTS:
        file_violations.append(f'effort "{effort}" not in {sorted(VALID_EFFORTS)}')
    elif not effort:
        file_warnings.append('effort field missing')

    # 5. domain non-empty
    if not domain:
        file_warnings.append('domain field missing')

    # 6. title non-empty
    if not title:
        file_violations.append('title is empty')

    # 7. status present
    if not status:
        file_warnings.append('status field missing')

    if file_violations:
        violations.append({'gap': gap_id, 'file': basename, 'violations': file_violations})
    if file_warnings:
        warnings.append({'gap': gap_id, 'file': basename, 'warnings': file_warnings})
    if not file_violations and (not strict or not file_warnings):
        passed_list.append(gap_id)

passed_list = []

# Parse file list from shell-expanded string
raw_files = [f.strip() for f in _file_list_str.split() if f.strip()]
for f in raw_files:
    check_file(f)

total = len(raw_files)
fail_count = len(violations)
warn_count = len(warnings)

if $JSON_OUT:
    summary = {
        'total': total,
        'passed': total - fail_count,
        'violations': violations,
        'warnings': warnings,
    }
    print(json.dumps(summary, indent=2))
else:
    for v in violations:
        for msg in v['violations']:
            print(f"  FAIL [{v['gap']}] {msg}")
    if $STRICT:
        for w in warnings:
            for msg in w['warnings']:
                print(f"  WARN [{w['gap']}] {msg}")
    if not violations and not ($STRICT and warnings):
        print(f"  All {total} gap(s) pass quality checks.")
    else:
        print(f"\n  {fail_count} gap(s) with violations, {warn_count} gap(s) with warnings")

sys.exit(1 if violations or ($STRICT and warnings) else 0)
PYEOF
