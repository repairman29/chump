#!/usr/bin/env bash
# test-notify-kind-escalation-coverage.sh — RESILIENT-1096
#
# WHY: board_ceo_briefing shipped a script that sets CHUMP_NOTIFY_KIND to a
# brand-new value with no entry in operator-escalation-registry.txt. Because
# an unlisted kind silently defaults to PAGE (see the registry file's own
# header), that gap meant "page the operator's phone every hour" until
# RESILIENT-1092 caught it by hand. This is the class-prevention gate: any
# literal CHUMP_NOTIFY_KIND=<value> assignment found in production scripts
# MUST have a suppress|page|direct verdict line in the registry, or CI fails.
#
# Mirrors the existing scanner-anchor / event-registry-reserved discipline
# used for ambient kinds (test-event-registry-coverage.sh) — same idea,
# applied to the narrower notify-operator escalation-kind vocabulary.
#
# Scope: only LITERAL string assignments are checkable statically
# (CHUMP_NOTIFY_KIND=foo, CHUMP_NOTIFY_KIND="foo", CHUMP_NOTIFY_KIND='foo').
# Variable-valued assignments (CHUMP_NOTIFY_KIND="$kind") are dynamic and are
# skipped — their possible values are enumerated at their own call sites,
# which this scanner also visits.
#
# Bypass (emergency): CHUMP_NOTIFY_KIND_COVERAGE_ALLOW_DRIFT=1 — must include
# a `Notify-Kind-Escalation-Bypass: <reason>` trailer in the commit body.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

REGISTRY="scripts/coord/operator-escalation-registry.txt"

if [[ ! -f "$REGISTRY" ]]; then
    echo "[notify-kind-escalation-coverage] FAIL: $REGISTRY missing" >&2
    exit 3
fi

if [[ "${CHUMP_NOTIFY_KIND_COVERAGE_ALLOW_DRIFT:-0}" == "1" ]]; then
    echo "[notify-kind-escalation-coverage] WARN: bypass via CHUMP_NOTIFY_KIND_COVERAGE_ALLOW_DRIFT=1"
    echo "[notify-kind-escalation-coverage]   Commit body must include 'Notify-Kind-Escalation-Bypass: <reason>'"
    exit 0
fi

exec python3 - "$REGISTRY" <<'PYEOF'
import re, subprocess, sys, pathlib

registry_path = sys.argv[1]
registry_text = pathlib.Path(registry_path).read_text()

# Verdict lines look like: `<kind><TAB or spaces>suppress|page|direct   # comment`
verdicts = {}
for line in registry_text.splitlines():
    s = line.strip()
    if not s or s.startswith('#'):
        continue
    m = re.match(r'^([A-Za-z0-9_]+)\s+(suppress|page|direct)\b', s)
    if m:
        verdicts[m.group(1)] = m.group(2)

# Production paths that legitimately set CHUMP_NOTIFY_KIND for a real
# escalation. Excludes scripts/ci/ (test fixtures use throwaway kind names
# like pr_stuck_alpha that are never real escalations).
PROD_PATHS = [
    'src/', 'crates/',
    'scripts/coord/', 'scripts/dispatch/', 'scripts/ops/',
    'scripts/dev/', 'scripts/setup/',
]
SKIP_PATTERNS = ('/tests/', '/test_', '_test.rs', '/fixtures/')

def grep_lines(pattern, paths):
    existing = [p for p in paths if pathlib.Path(p).exists()]
    if not existing:
        return []
    proc = subprocess.run(
        ['grep', '-rEnI', pattern, *existing],
        capture_output=True, text=True
    )
    if proc.returncode > 1:
        return []
    return [ln for ln in proc.stdout.splitlines() if ln]

# Literal-valued assignments only: CHUMP_NOTIFY_KIND=foo / ="foo" / ='foo'.
# A leading $ (variable value) or backtick is excluded by the character class.
PATTERN = r'CHUMP_NOTIFY_KIND=["\x27]?[A-Za-z][A-Za-z0-9_]*["\x27]?'
VALUE_RE = re.compile(r'CHUMP_NOTIFY_KIND=["\x27]?([A-Za-z][A-Za-z0-9_]*)["\x27]?')

# Doc-comment placeholders, not real escalation kinds — e.g. the usage
# example `CHUMP_NOTIFY_KIND=x notify-operator.sh "<msg>"` in a `#` comment.
NOISE = {'x', 'foo', 'kind', 'name'}

found = {}  # kind -> first path:lineno seen
for line in grep_lines(PATTERN, PROD_PATHS):
    parts = line.split(':', 2)
    if len(parts) < 3:
        continue
    path, lineno = parts[0], parts[1]
    if any(p in path for p in SKIP_PATTERNS):
        continue
    content = parts[2]
    # Skip shell/comment lines whose CHUMP_NOTIFY_KIND=... is inside prose
    # documentation rather than an executed assignment — i.e. the line's
    # first non-whitespace char is '#'.
    if content.lstrip().startswith('#'):
        continue
    m = VALUE_RE.search(content)
    if not m:
        continue
    kind = m.group(1)
    if kind in NOISE:
        continue
    found.setdefault(kind, f"{path}:{lineno}")

missing = sorted(k for k in found if k not in verdicts)

print(f"[notify-kind-escalation-coverage] literal CHUMP_NOTIFY_KIND sites={len(found)} "
      f"registry-verdicts={len(verdicts)}")
if missing:
    print("[notify-kind-escalation-coverage] FAIL: kinds with no escalation-registry verdict:", file=sys.stderr)
    for k in missing:
        print(f"  MISSING-VERDICT: {k} (first seen at {found[k]})", file=sys.stderr)
    print("[notify-kind-escalation-coverage] add a 'suppress|page|direct' line to "
          f"{registry_path} for each kind above.", file=sys.stderr)
    sys.exit(1)

print("[notify-kind-escalation-coverage] OK")
sys.exit(0)
PYEOF
