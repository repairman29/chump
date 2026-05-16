#!/usr/bin/env bash
# pre-commit-ac-completeness.sh — INFRA-1401
#
# Blocks a commit when the gap's acceptance_criteria references a CI/coord/ops
# script that is neither staged NOR already present in the repo.
#
# Pattern observed 2026-05-15/16: PRODUCT-127/128/130/131 each declared a
# smoke test in AC ("scripts/ci/test-cockpit-*.sh") but the PR shipped the
# feature WITHOUT the test. Required 4 follow-up PRs (#2147-2151) to backfill.
#
# Detection:
#   1. Parse gap ID(s) from the commit subject — looks for feat/fix/chore/(GAP-ID):
#   2. For each gap ID, read docs/gaps/<id>.yaml and extract acceptance_criteria text
#   3. Search AC text for script filename patterns:
#        scripts/(ci|coord|ops|git|setup)/(test-)?[a-z0-9_-]+\.(sh|rs|py)
#   4. For each referenced file: pass if staged OR exists in current HEAD tree
#   5. Block commit with a list of missing files
#
# Bypass:
#   Add trailer to commit body:  AC-Backfill-Reason: <one-sentence why test ships separately>
#   Or suppress entirely:        CHUMP_AC_COMPLETENESS_CHECK=0 git commit ...
#
# Note: the detector only fires when the commit mentions a gap ID in the subject.
# Commits without a gap prefix (chore, docs, refactor, etc.) are not checked.

set -uo pipefail

if [[ "${CHUMP_AC_COMPLETENESS_CHECK:-1}" == "0" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || \
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── 1. Extract commit subject ─────────────────────────────────────────────────
# Use COMMIT_EDITMSG if available (during git commit), else read stdin.
if [[ -f "$REPO_ROOT/.git/COMMIT_EDITMSG" ]]; then
    SUBJECT=$(head -1 "$REPO_ROOT/.git/COMMIT_EDITMSG")
elif [[ -n "${GIT_EDITOR:-}" ]]; then
    SUBJECT=""
else
    # Attempt to get the staged commit message if available
    SUBJECT=$(git log --format='%s' -1 HEAD 2>/dev/null || true)
fi

if [[ -z "$SUBJECT" ]]; then
    exit 0
fi

# ── 2. Parse gap IDs from subject ─────────────────────────────────────────────
# Matches: feat(INFRA-1234):, fix(PRODUCT-56):, or bare INFRA-1234 in subject
GAP_IDS=$(echo "$SUBJECT" | grep -oE '[A-Z]+-[0-9]+' | sort -u || true)
if [[ -z "$GAP_IDS" ]]; then
    exit 0
fi

# ── 3. Check for bypass trailer in commit message ─────────────────────────────
if [[ -f "$REPO_ROOT/.git/COMMIT_EDITMSG" ]]; then
    if grep -qE '^AC-Backfill-Reason:' "$REPO_ROOT/.git/COMMIT_EDITMSG"; then
        exit 0
    fi
fi

# ── 4. Python: read AC YAML + detect missing files ───────────────────────────
python3 - "$REPO_ROOT" "$GAP_IDS" << 'PYEOF'
import subprocess, sys, re, os

repo_root = sys.argv[1]
gap_ids = sys.argv[2].split()

# Regex for script filenames referenced in AC text
SCRIPT_RE = re.compile(
    r'\bscripts/(?:ci|coord|ops|git|setup|dispatch)/(?:test-)?[a-zA-Z0-9_-]+\.(?:sh|rs|py)\b'
)

def read_gap_ac(gap_id):
    """Return the raw text of acceptance_criteria for a gap YAML, or empty string."""
    yaml_path = os.path.join(repo_root, 'docs', 'gaps', f'{gap_id}.yaml')
    if not os.path.exists(yaml_path):
        return ''
    try:
        with open(yaml_path) as f:
            return f.read()
    except Exception:
        return ''

def file_in_staged_tree(path):
    """Return True if the file is staged (index) or exists in HEAD tree."""
    # Check index (staged files, including new files)
    r = subprocess.run(
        ['git', 'ls-files', '--cached', '--', path],
        capture_output=True, text=True, cwd=repo_root
    )
    if r.stdout.strip():
        return True
    # Check HEAD tree (already committed files)
    r2 = subprocess.run(
        ['git', 'cat-file', '-e', f'HEAD:{path}'],
        capture_output=True, cwd=repo_root
    )
    return r2.returncode == 0

all_missing = []
for gap_id in gap_ids:
    ac_text = read_gap_ac(gap_id)
    if not ac_text:
        continue
    referenced = set(SCRIPT_RE.findall(ac_text))
    for script_path in sorted(referenced):
        if not file_in_staged_tree(script_path):
            all_missing.append((gap_id, script_path))

if not all_missing:
    sys.exit(0)

import json, datetime as dt
# Emit ambient event
ambient = os.path.join(repo_root, '.chump-locks', 'ambient.jsonl')
try:
    event = json.dumps({
        "ts": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "kind": "pre_commit_ac_test_missing",
        "gaps": list({g for g, _ in all_missing}),
        "missing_files": [f for _, f in all_missing],
    })
    with open(ambient, 'a') as af:
        af.write(event + '\n')
except Exception:
    pass

print('', file=sys.stderr)
print('-' * 70, file=sys.stderr)
print('INFRA-1401 AC-completeness gate blocked this commit.', file=sys.stderr)
print('', file=sys.stderr)
print('These files are referenced in acceptance_criteria but are neither', file=sys.stderr)
print('staged nor present in the repo:', file=sys.stderr)
print('', file=sys.stderr)
for gap_id, path in all_missing:
    print(f'  [{gap_id}]  {path}', file=sys.stderr)
print('', file=sys.stderr)
print('Options:', file=sys.stderr)
print('  1. Add the missing test/script files to this commit (preferred)', file=sys.stderr)
print('  2. Add a trailer to the commit body if shipping test separately:', file=sys.stderr)
print('       AC-Backfill-Reason: <one-sentence why the test ships in a follow-up>', file=sys.stderr)
print('  3. Bypass entirely (sparingly):', file=sys.stderr)
print('       CHUMP_AC_COMPLETENESS_CHECK=0 git commit ...', file=sys.stderr)
print('-' * 70, file=sys.stderr)
sys.exit(1)
PYEOF
