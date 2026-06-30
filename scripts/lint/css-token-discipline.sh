#!/usr/bin/env bash
# css-token-discipline.sh — INFRA-1590
#
# Enforce PWA design-token discipline on web/**/*.{js,html,css}.
# Mirrors the META-064 Rust-First-Bypass pattern.
#
# Rules:
#   1. No raw hex (#xxx/#xxxxxx) / rgb() / rgba() / hsl() outside :root{} or
#      [data-theme]{} blocks.
#   2. No new --*-primary or --*-secondary CSS variable definitions.
#      Canonical: --text --text-secondary --bg --bg-surface --bg-elevated
#                 --accent --accent-dim --success --warn --error --border
#                 --radius --radius-sm
#   3. No var(--token, FALLBACK) where FALLBACK != the token's :root value.
#   4. Color literal appearing in >3 different files (drift detector).
#
# Bypass: 'Token-Discipline-Bypass: <reason>' in commit body.
#         Emits kind=token_discipline_bypass to ambient.jsonl.
# Baseline: .css-discipline-baseline.txt — grandfathered files (one per line).
# Disable:  CHUMP_TOKEN_DISCIPLINE_CHECK=0
#
# Usage:
#   no args   — scan staged web/**/*.{js,html,css} (pre-commit mode)
#   FILE...   — scan specific files (CI/test mode)

set -uo pipefail

if [[ "${CHUMP_TOKEN_DISCIPLINE_CHECK:-1}" == "0" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BASELINE_FILE="${CSS_DISCIPLINE_BASELINE_OVERRIDE:-$REPO_ROOT/.css-discipline-baseline.txt}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

TMPDIR_LINT="/tmp/css-lint-$$"
mkdir -p "$TMPDIR_LINT"
trap 'rm -rf "$TMPDIR_LINT"' EXIT

FILES_TXT="$TMPDIR_LINT/files.txt"
CHECKER_PY="$TMPDIR_LINT/checker.py"
OUT_JSON="$TMPDIR_LINT/out.json"

# ── Build file list ────────────────────────────────────────────────────────
CI_MODE=0
if [[ $# -gt 0 ]]; then
    CI_MODE=1
    printf '%s\n' "$@" > "$FILES_TXT"
else
    git diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
        | grep -E '^web/.*\.(js|html|css)$' \
        > "$FILES_TXT" || true
fi

if [[ ! -s "$FILES_TXT" ]]; then
    exit 0
fi

# ── Bypass trailer (pre-commit mode only) ─────────────────────────────────
HAS_BYPASS=0
BYPASS_REASON=""
if [[ "$CI_MODE" -eq 0 ]]; then
    MSG_FILE="$(git rev-parse --git-common-dir 2>/dev/null)/COMMIT_EDITMSG"
    if [[ -f "$MSG_FILE" ]]; then
        BYPASS_LINE="$(grep -E '^Token-Discipline-Bypass:' "$MSG_FILE" 2>/dev/null | head -1 || true)"
        if [[ -n "$BYPASS_LINE" ]]; then
            HAS_BYPASS=1
            BYPASS_REASON="${BYPASS_LINE#Token-Discipline-Bypass:}"
            BYPASS_REASON="${BYPASS_REASON# }"
        fi
    fi
fi

# ── Write Python checker to temp file ─────────────────────────────────────
cat > "$CHECKER_PY" << 'PYEOF'
#!/usr/bin/env python3
"""css-token-discipline inner checker — reads file paths from stdin."""
import re, sys, os, subprocess, json

index_html   = sys.argv[1]
baseline_f   = sys.argv[2]
content_mode = sys.argv[3]   # "staged" or "disk"

# ── Baseline ───────────────────────────────────────────────────────────────
baselined = set()
if os.path.exists(baseline_f):
    for ln in open(baseline_f):
        ln = ln.split('#')[0].strip()
        if ln:
            baselined.add(ln)

def is_baselined(f):
    return f in baselined or os.path.basename(f) in baselined

# ── :root token values ─────────────────────────────────────────────────────
root_vals = {}
if os.path.exists(index_html):
    text = open(index_html, encoding='utf-8', errors='replace').read()
    m = re.search(r':root\s*\{([^}]+)\}', text, re.DOTALL)
    if m:
        for ln in m.group(1).splitlines():
            vm = re.match(r'\s*(--[\w-]+)\s*:\s*(.+?)\s*;?\s*$', ln)
            if vm:
                root_vals[vm.group(1)] = vm.group(2).strip().rstrip(';').strip()

CANON_DEFS = {
    '--text', '--text-secondary', '--bg', '--bg-surface', '--bg-elevated',
    '--accent', '--accent-dim', '--success', '--warn', '--error',
    '--border', '--radius', '--radius-sm',
    '--nav-width', '--header-h', '--safe-top', '--safe-bottom', '--safe-left',
}

COLOR_RE = re.compile(
    r'(?<!["\w-])('
    r'#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\b'
    r'|rgba?\s*\([^)]+\)'
    r'|hsla?\s*\([^)]+\)'
    r')',
    re.IGNORECASE,
)
VAR_FALLBACK_RE = re.compile(
    r'var\(\s*(--[\w-]+)\s*,\s*([^)]+?)\s*\)', re.IGNORECASE
)

def in_definition_block(text, pos):
    """True if pos is inside a :root{} or [data-theme]{} block.

    Collects only the selector text on the SAME LINE as the opening brace
    so that ':root' appearing in unrelated comments earlier in the file
    doesn't falsely match.
    """
    before = text[:pos]
    depth  = 0
    i = len(before) - 1
    while i >= 0:
        c = before[i]
        if c == '}':
            depth += 1
        elif c == '{':
            if depth == 0:
                # Collect selector: only back to the previous newline (same line)
                j = i - 1
                sel_chars = []
                while j >= 0 and before[j] not in '\n\r{}':
                    sel_chars.append(before[j])
                    j -= 1
                selector = ''.join(reversed(sel_chars)).strip()
                return bool(re.search(r':root|data-theme', selector))
            depth -= 1
        i -= 1
    return False

def strip_css_comments(content):
    """Replace /* ... */ block contents with spaces, preserving line structure."""
    result = []
    i = 0
    n = len(content)
    while i < n:
        if content[i:i+2] == '/*':
            end = content.find('*/', i + 2)
            if end == -1:
                end = n - 2
            chunk = content[i:end+2]
            # Keep newlines so line numbers stay accurate; blank out rest
            result.append(re.sub(r'[^\n]', ' ', chunk))
            i = end + 2
        else:
            result.append(content[i])
            i += 1
    return ''.join(result)

def check_content(filepath, content):
    violations = []
    # Strip CSS comments before rule1 scanning so hex in comments isn't flagged
    content_no_comments = strip_css_comments(content)
    lines = content.splitlines()
    lines_nc = content_no_comments.splitlines()
    for lineno, line in enumerate(lines, 1):
        line_nc   = lines_nc[lineno - 1] if lineno - 1 < len(lines_nc) else line
        line_start = sum(len(l) + 1 for l in lines[:lineno - 1])

        # Rule 2
        for m in re.finditer(r'(--[\w]+-(?:primary|secondary))\s*:', line):
            vname = m.group(1)
            if vname not in CANON_DEFS:
                violations.append(
                    f"{filepath}:{lineno}: [rule2] non-canonical var definition "
                    f"'{vname}' — use --text, --bg, --accent, etc."
                )

        # Rule 3
        for m in VAR_FALLBACK_RE.finditer(line):
            token    = m.group(1)
            fallback = m.group(2).strip()
            if token in root_vals and fallback != root_vals[token]:
                violations.append(
                    f"{filepath}:{lineno}: [rule3] var({token}, {fallback!r}) "
                    f"fallback mismatch — :root value is '{root_vals[token]}'"
                )

        # Rule 1 — scan comment-stripped line so hex in /* ... */ is ignored
        for m in COLOR_RE.finditer(line_nc):
            color     = m.group(0)
            col_start = m.start()
            before_col = line[:col_start]
            last_var = before_col.rfind('var(')
            if last_var != -1:
                between = before_col[last_var:]
                if between.count('(') > between.count(')'):
                    continue  # inside var() fallback — rule 3 handles
            pos = line_start + col_start
            if in_definition_block(content, pos):
                continue
            violations.append(
                f"{filepath}:{lineno}: [rule1] raw color '{color}' outside "
                f":root/[data-theme] — use var(--token)"
            )
    return violations

color_to_files = {}

def accum_colors(filepath, content):
    for m in COLOR_RE.finditer(content):
        key = m.group(0).lower().replace(' ', '')
        color_to_files.setdefault(key, set()).add(filepath)

all_violations = []
checked_files  = []

for filepath in sys.stdin.read().splitlines():
    filepath = filepath.strip()
    if not filepath:
        continue
    if is_baselined(filepath):
        continue
    checked_files.append(filepath)

    if content_mode == 'staged':
        try:
            content = subprocess.check_output(
                ['git', 'show', f':{filepath}'], stderr=subprocess.DEVNULL
            ).decode('utf-8', errors='replace')
        except subprocess.CalledProcessError:
            try:
                content = open(filepath, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
    else:
        try:
            content = open(filepath, encoding='utf-8', errors='replace').read()
        except OSError:
            continue

    all_violations.extend(check_content(filepath, content))
    accum_colors(filepath, content)

# Rule 4
for color, files in color_to_files.items():
    if len(files) > 3:
        all_violations.append(
            f"[rule4] raw color '{color}' in {len(files)} files (drift) "
            f"— tokenize in :root: {', '.join(sorted(files))}"
        )

print(json.dumps({'violations': all_violations, 'checked': checked_files}))
PYEOF

# ── Run Python checker ────────────────────────────────────────────────────
MODE="$( [[ $CI_MODE -eq 0 ]] && echo staged || echo disk )"
python3 "$CHECKER_PY" "$INDEX_HTML" "$BASELINE_FILE" "$MODE" \
    < "$FILES_TXT" > "$OUT_JSON" 2>/dev/null
PY_RC=$?

if [[ $PY_RC -ne 0 ]]; then
    echo "[css-token-discipline] checker error (exit $PY_RC)" >&2
    exit 1
fi

# ── Parse results ─────────────────────────────────────────────────────────
VIOLATIONS="$(python3 -c "
import json, sys
d = json.load(open('$OUT_JSON'))
print('\n'.join(d['violations']))
" 2>/dev/null || true)"

CHECKED_JSON="$(python3 -c "
import json
d = json.load(open('$OUT_JSON'))
print(json.dumps(d['checked']))
" 2>/dev/null || echo '[]')"

if [[ -z "$VIOLATIONS" ]]; then
    exit 0
fi

# ── Bypass ─────────────────────────────────────────────────────────────────
if [[ "$HAS_BYPASS" -eq 1 ]]; then
    if [[ -d "$(dirname "$AMBIENT")" ]]; then
        _sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
        _reason_json="$(printf '%s' "$BYPASS_REASON" \
            | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' \
            2>/dev/null || echo '""')"
        printf '{"ts":"%s","kind":"token_discipline_bypass","commit_sha":"%s","reason":%s,"files":%s}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_sha" "$_reason_json" "$CHECKED_JSON" \
            >> "$AMBIENT" 2>/dev/null || true
    fi
    exit 0
fi

# ── Block ──────────────────────────────────────────────────────────────────
VCOUNT="$(printf '%s\n' "$VIOLATIONS" | grep -c . || true)"
red=$'\033[0;31m'
nc=$'\033[0m'
printf '\n%s❌ css-token-discipline (INFRA-1590): %s violation(s)%s\n\n' \
    "$red" "$VCOUNT" "$nc" >&2
printf '%s\n' "$VIOLATIONS" | sed 's/^/  /' >&2
cat >&2 <<'USAGE'

Rules:
  rule1 — use var(--token) instead of raw hex/rgb/hsl outside :root
  rule2 — don't define --*-primary or --*-secondary; use canonical names
  rule3 — var(--token, FALLBACK): fallback must match :root value exactly
  rule4 — same raw color in >3 files → tokenize in :root

Canonical tokens:
  --text  --text-secondary  --bg  --bg-surface  --bg-elevated
  --accent  --accent-dim  --success  --warn  --error  --border
  --radius  --radius-sm

Fix: use var(--existing-token) or add a token to web/v2/index.html :root{}.

Bypass (add to commit body):
  Token-Discipline-Bypass: <one-sentence reason>

Grandfather an existing file:
  echo 'path/to/file.js' >> .css-discipline-baseline.txt

Full rules: docs/process/CSS_TOKEN_DISCIPLINE.md
Disable:    CHUMP_TOKEN_DISCIPLINE_CHECK=0 git commit ...
USAGE
exit 1
