#!/usr/bin/env bash
# css-token-discipline.sh — INFRA-1590
#
# Scans staged (or all) web/**/*.{js,html,css} files for design-token drift.
# Delegates analysis to an inline Python 3 script (multi-line regex required).
#
# Rules enforced:
#   Rule 1: raw hex / rgb() / rgba() / hsl() literals OUTSIDE :root / [data-theme]
#   Rule 2: new --*-primary or --*-secondary CSS variable definitions
#   Rule 3: var(--token, FALLBACK) where FALLBACK ≠ token's :root value
#   Rule 4: a single color literal in > 3 different files (drift detector)
#
# Pattern mirrors scripts/git-hooks/pre-commit-rust-first.sh (META-064).
#
# Usage:
#   css-token-discipline.sh [--all]               # --all: scan entire web/; default: staged only
#   css-token-discipline.sh --index <index.html>  # override canonical token source
#
# Env overrides:
#   CHUMP_CSS_TOKEN_INDEX=<path>   canonical index.html (default: web/v2/index.html)
#   CHUMP_CSS_BASELINE=<path>      baseline whitelist (default: .css-discipline-baseline.txt)
#
# Exit: 0 = clean, 1 = violations found, 2 = internal error

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
INDEX_HTML="${CHUMP_CSS_TOKEN_INDEX:-$REPO_ROOT/web/v2/index.html}"
BASELINE="${CHUMP_CSS_BASELINE:-$REPO_ROOT/.css-discipline-baseline.txt}"
SCAN_ALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --all)  SCAN_ALL=1; shift ;;
        --index) INDEX_HTML="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ── Collect files to scan ────────────────────────────────────────────────────

FILE_LIST_TMP=$(mktemp)
trap 'rm -f "$FILE_LIST_TMP"' EXIT

if [ "$SCAN_ALL" = "1" ]; then
    find "$REPO_ROOT/web" -type f \( -name "*.js" -o -name "*.html" -o -name "*.css" \) \
        2>/dev/null > "$FILE_LIST_TMP" || true
else
    git diff --cached --name-only 2>/dev/null \
        | grep -E '\.(js|html|css)$' \
        | grep -E '^web/' \
        | while IFS= read -r f; do
            [ -f "$REPO_ROOT/$f" ] && echo "$REPO_ROOT/$f"
          done > "$FILE_LIST_TMP" || true
fi

if [ ! -s "$FILE_LIST_TMP" ]; then
    exit 0
fi

# ── Delegate to Python 3 for analysis ────────────────────────────────────────

python3 - "$INDEX_HTML" "$BASELINE" "$FILE_LIST_TMP" "$REPO_ROOT" <<'PYEOF'
import sys, re, os

index_html   = sys.argv[1]
baseline_txt = sys.argv[2]
file_list    = sys.argv[3]
repo_root    = sys.argv[4].rstrip('/') + '/'

# Load files to scan
with open(file_list) as f:
    files = [l.strip() for l in f if l.strip() and os.path.isfile(l.strip())]

if not files:
    sys.exit(0)

def rel(path):
    """Return repo-relative path for baseline key matching."""
    return path[len(repo_root):] if path.startswith(repo_root) else path

# ── Load baseline whitelist ──────────────────────────────────────────────────

baseline = set()
if os.path.isfile(baseline_txt):
    with open(baseline_txt) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                baseline.add(line)

def is_baseline(key):
    return key in baseline

# ── Parse canonical :root tokens from index.html ─────────────────────────────

root_tokens = {}  # token_name -> value_string
if os.path.isfile(index_html):
    text = open(index_html).read()
    # Find all :root { } and [data-theme] { } blocks
    block_pattern = re.compile(
        r'(?::root|html\[data-theme[^\]]*\]|\[data-theme[^\]]*\])\s*\{([^}]*)\}',
        re.DOTALL
    )
    for m in block_pattern.finditer(text):
        block = m.group(1)
        for line in block.splitlines():
            tm = re.match(r'\s*--([\w-]+)\s*:\s*(.+?)\s*;', line)
            if tm:
                root_tokens[tm.group(1)] = tm.group(2).strip()

# ── Canonical token names ─────────────────────────────────────────────────────

CANONICAL = {
    '--text', '--text-secondary', '--bg', '--bg-surface', '--bg-elevated',
    '--accent', '--accent-dim', '--success', '--warn', '--error',
    '--border', '--radius', '--radius-sm',
}

# ── Strip :root / [data-theme] blocks from file text ─────────────────────────

ROOT_BLOCK_RE = re.compile(
    r'(?::root|html\[data-theme[^\]]*\]|\[data-theme[^\]]*\])\s*\{[^}]*\}',
    re.DOTALL
)

def strip_root_blocks(text):
    return ROOT_BLOCK_RE.sub('', text)

# ── Violation tracking ────────────────────────────────────────────────────────

violations = []
color_file_map = {}   # color_literal -> set of files

def add_v(filepath, lineno, rule, detail):
    key = f"{rel(filepath)}:{lineno}:{rule}"
    if not is_baseline(key):
        violations.append(f"{filepath}:{lineno}  [{rule}]  {detail}")

# ── Rule 1: raw hex / rgb() / rgba() / hsl() outside :root ───────────────────

HEX_RE   = re.compile(r'#[0-9a-fA-F]{3,8}\b')
COLOR_FN  = re.compile(r'\b(?:rgb|rgba|hsl|hsla)\s*\([^)]+\)')
COMMENT_RE = re.compile(r'^\s*(?://|/\*|\*)')

for filepath in files:
    try:
        text = open(filepath, encoding='utf-8', errors='replace').read()
    except Exception:
        continue

    stripped = strip_root_blocks(text)
    for lineno, line in enumerate(stripped.splitlines(), 1):
        if COMMENT_RE.match(line):
            continue
        for m in HEX_RE.finditer(line):
            color = m.group(0)
            color_file_map.setdefault(color, set()).add(filepath)
            add_v(filepath, lineno, 'rule1-hex', f"raw hex '{color}' outside :root (use var(--token))")
        for m in COLOR_FN.finditer(line):
            fn = m.group(0)
            color_file_map.setdefault(fn, set()).add(filepath)
            add_v(filepath, lineno, 'rule1-fn', f"color function '{fn}' outside :root (use var(--token))")

# ── Rule 2: new --*-primary or --*-secondary definitions ─────────────────────

ALIAS_RE = re.compile(r'(--[\w]+-(?:primary|secondary))\s*:')

for filepath in files:
    try:
        lines = open(filepath, encoding='utf-8', errors='replace').readlines()
    except Exception:
        continue
    for lineno, line in enumerate(lines, 1):
        for m in ALIAS_RE.finditer(line):
            tok = m.group(1)
            canonical_list = ', '.join(sorted(CANONICAL))
            add_v(filepath, lineno, 'rule2-alias',
                  f"non-canonical token '{tok}' — canonical names: {canonical_list}")

# ── Rule 3: var(--token, FALLBACK) where FALLBACK ≠ :root value ──────────────

VAR_FALLBACK_RE = re.compile(r'var\(--([\w-]+),\s*([^)]+)\)')

for filepath in files:
    try:
        lines = open(filepath, encoding='utf-8', errors='replace').readlines()
    except Exception:
        continue
    for lineno, line in enumerate(lines, 1):
        for m in VAR_FALLBACK_RE.finditer(line):
            tok = m.group(1)
            fallback = m.group(2).strip().rstrip(')').strip()
            if tok not in root_tokens:
                continue
            canonical = root_tokens[tok].strip()
            if fallback != canonical:
                add_v(filepath, lineno, 'rule3-fallback',
                      f"var(--{tok}, {fallback}) fallback ≠ :root value '{canonical}'")

# ── Rule 4: color literal in > 3 different files ─────────────────────────────

for color, file_set in color_file_map.items():
    if len(file_set) > 3:
        key = f"rule4:{color}"
        if not is_baseline(key):
            violations.append(
                f"drift  [rule4-drift]  '{color}' appears in {len(file_set)} files"
                " — consolidate into a :root token"
            )

# ── Report ────────────────────────────────────────────────────────────────────

if not violations:
    sys.exit(0)

RED = '\033[0;31m'
NC  = '\033[0m'
print(f"\n{RED}❌ CSS token-discipline violations (INFRA-1590):{NC}", file=sys.stderr)
print(file=sys.stderr)
for v in violations:
    print(f"  {v}", file=sys.stderr)
print(file=sys.stderr)
print("Canonical tokens: --text --text-secondary --bg --bg-surface --bg-elevated"
      " --accent --accent-dim --success --warn --error --border --radius --radius-sm",
      file=sys.stderr)
print("Token reference:  docs/process/CSS_TOKEN_DISCIPLINE.md", file=sys.stderr)
print("Bypass: add 'Token-Discipline-Bypass: <reason>' to commit body", file=sys.stderr)
print("Baseline (existing violations): .css-discipline-baseline.txt", file=sys.stderr)
print(file=sys.stderr)
sys.exit(1)
PYEOF
