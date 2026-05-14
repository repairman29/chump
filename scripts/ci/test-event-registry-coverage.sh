#!/usr/bin/env bash
# test-event-registry-coverage.sh — INFRA-1237 (CREDIBLE)
#
# Audit docs/observability/EVENT_REGISTRY.yaml drift on every PR. Grep the
# production paths for `kind=` emit literals; diff against the registered
# kinds in the YAML.
#
# The existing scripts/git-hooks/pre-commit-event-registry.sh only checks
# the STAGED diff — emit sites that predate INFRA-754 or were committed
# under a hook bypass slip through. This script audits the FULL tree on
# every CI run and fails the build on drift.
#
# Modes (CHUMP_REGISTRY_GATE_MODE):
#   strict-emit (default) — emit-without-register FAILS; orphans warn-only
#   strict              — both directions fail (use after orphan
#                         reconciliation gap lands)
#   report              — print drift counts, never fail (diagnostic)
#
# Allowlist (scripts/ci/event-registry-reserved.txt) — one kind per line,
# optionally with inline `# reason` comment. Comments + blanks ignored.
#
# Bypass: CHUMP_EVENT_REGISTRY_ALLOW_DRIFT=1 — emergency bypass; must
#         include `Event-Registry-Drift-Bypass: <reason>` in commit body.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

REGISTRY="docs/observability/EVENT_REGISTRY.yaml"
ALLOWLIST="scripts/ci/event-registry-reserved.txt"
MODE="${CHUMP_REGISTRY_GATE_MODE:-strict-emit}"

if [[ ! -f "$REGISTRY" ]]; then
    echo "[event-registry-audit] FAIL: $REGISTRY missing" >&2
    exit 3
fi

# Optional allowlist — empty file is fine for first-run.
[[ -f "$ALLOWLIST" ]] || ALLOWLIST=/dev/null

# Bypass (emergency).
if [[ "${CHUMP_EVENT_REGISTRY_ALLOW_DRIFT:-0}" == "1" ]]; then
    echo "[event-registry-audit] WARN: bypass via CHUMP_EVENT_REGISTRY_ALLOW_DRIFT=1"
    echo "[event-registry-audit]   Commit body must include 'Event-Registry-Drift-Bypass: <reason>'"
    exit 0
fi

exec python3 - "$REGISTRY" "$ALLOWLIST" "$MODE" <<'PYEOF'
import re, subprocess, sys, pathlib

registry_path, allowlist_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
yaml_text = pathlib.Path(registry_path).read_text()

# Registered kinds: each appears as `^  - kind: <name>`.
registered = set(re.findall(r'^\s*-\s+kind:\s*([A-Za-z0-9_]+)', yaml_text, re.M))

# Production paths. Excludes scripts/ab-harness/, scripts/ci/,
# scripts/git-hooks/, scripts/auto-docs/, etc. — those legitimately mention
# `"kind":"X"` as test fixtures, doc examples, or hook bypass templates.
PROD_PATHS = [
    'src/', 'crates/',
    'scripts/coord/', 'scripts/dispatch/', 'scripts/ops/',
]
# Also skip per-file patterns that may live inside PROD_PATHS but are tests
# or fixtures (e.g. `src/foo/tests/bar.rs`).
SKIP_PATTERNS = ('/tests/', '/test_', '_test.rs', '/fixtures/')

def grep_lines(pattern, paths):
    """Run grep -rEnI, return list of `path:lineno:content` strings."""
    proc = subprocess.run(
        ['grep', '-rEnI', pattern, *paths],
        capture_output=True, text=True
    )
    # rc 1 == no matches (OK); rc 2+ == real error
    if proc.returncode > 1:
        return []
    return [ln for ln in proc.stdout.splitlines() if ln]

def extract_kinds(lines, kind_re):
    """From grep output lines, return set of kinds (skipping fixture paths)."""
    out = set()
    for line in lines:
        parts = line.split(':', 2)
        if len(parts) < 3:
            continue
        path = parts[0]
        if any(p in path for p in SKIP_PATTERNS):
            continue
        m = re.search(kind_re, parts[2])
        if m:
            out.add(m.group(1))
    return out

# Pattern 1: "kind":"<name>" — JSON literals (serde::json! macro,
# shell heredocs, etc.). Search ALL production paths.
emitted = extract_kinds(
    grep_lines(r'"kind"\s*:\s*"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'"kind"\s*:\s*"([a-zA-Z0-9_]+)"',
)
# Pattern 2: kind = "<name>" — Rust struct-init form. Only in src/, crates/.
emitted |= extract_kinds(
    grep_lines(r'kind\s*=\s*"[a-zA-Z0-9_]+"', ['src/', 'crates/']),
    r'kind\s*=\s*"([a-zA-Z0-9_]+)"',
)

# Allowlist — kinds exempt from BOTH directions.
allowlist = set()
try:
    with open(allowlist_path) as f:
        for ln in f:
            s = ln.strip()
            if not s or s.startswith('#'):
                continue
            k = s.split('#', 1)[0].strip()
            if k:
                allowlist.add(k)
except FileNotFoundError:
    pass

# Drop obvious noise (placeholders inadvertently caught by the regex).
NOISE = {'X', 'kind', 'name', 'value', 'type', 'event', 'other'}
emitted -= NOISE

emit_without_register = sorted((emitted - registered) - allowlist)
register_without_emit = sorted((registered - emitted) - allowlist)

# ── Report ──
print(f"[event-registry-audit] mode={mode}")
print(f"[event-registry-audit] registered={len(registered)} "
      f"emitted={len(emitted)} allowlisted={len(allowlist)}")
print(f"[event-registry-audit] emit-without-register: {len(emit_without_register)}")
for k in emit_without_register:
    print(f"  EMIT-NO-REG: {k}")
print(f"[event-registry-audit] register-without-emit (orphans): "
      f"{len(register_without_emit)}")
if register_without_emit and mode != 'report':
    head = register_without_emit[:5]
    for k in head:
        print(f"  ORPHAN: {k}")
    if len(register_without_emit) > 5:
        print(f"  ... +{len(register_without_emit)-5} more "
              f"(run with CHUMP_REGISTRY_GATE_MODE=report for full list)")

# ── Exit policy ──
if mode == 'report':
    sys.exit(0)
if emit_without_register:
    print("[event-registry-audit] FAIL: emit-without-register violations — "
          "register each kind in docs/observability/EVENT_REGISTRY.yaml or "
          "add to scripts/ci/event-registry-reserved.txt with a reason.",
          file=sys.stderr)
    sys.exit(1)
if mode == 'strict' and register_without_emit:
    print("[event-registry-audit] FAIL: register-without-emit violations — "
          "implement each kind or remove from registry. (Default mode "
          "'strict-emit' only warns on orphans; set CHUMP_REGISTRY_GATE_MODE=strict "
          "to fail on this too.)",
          file=sys.stderr)
    sys.exit(2)
print("[event-registry-audit] OK")
sys.exit(0)
PYEOF
