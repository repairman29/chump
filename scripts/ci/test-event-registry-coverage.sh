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

# INFRA-1982: Deprecated kinds — entries with `deprecated: true` are excluded
# from orphan checks (register-without-emit) since they are intentionally no
# longer emitted. They remain in registered so emit-without-register doesn't
# complain if old log replays reference them.
_deprecated_blocks = re.findall(
    r'-\s+kind:\s*([A-Za-z0-9_]+)(?:.(?!-\s+kind:))*?deprecated:\s*true',
    yaml_text, re.S
)
deprecated_kinds = set(_deprecated_blocks)

# Production paths. Excludes scripts/ab-harness/, scripts/ci/,
# scripts/git-hooks/, scripts/auto-docs/, etc. — those legitimately mention
# `"kind":"X"` as test fixtures, doc examples, or hook bypass templates.
# INFRA-1287: extended to include scripts/dev/ and scripts/setup/ which
# contain real emit sites (e.g. ambient-watch.sh emits lease_overlap/edit_burst,
# install-chump-fleet-daemon.sh emits daemon_tick via daemon orchestration).
PROD_PATHS = [
    'src/', 'crates/',
    'scripts/coord/', 'scripts/dispatch/', 'scripts/ops/',
    'scripts/dev/', 'scripts/setup/',
    # INFRA-1695 / META-066: Content Bots Suite dispatcher + orchestrator
    # emit content_bot_invoked / content_bot_output / content_bot_pipeline_step
    # from scripts/content-bots/. Same production-emit semantics as the
    # other scripts/ paths above.
    'scripts/content-bots/',
]
# Also skip per-file patterns that may live inside PROD_PATHS but are tests
# or fixtures (e.g. `src/foo/tests/bar.rs`).
SKIP_PATTERNS = ('/tests/', '/test_', '_test.rs', '/fixtures/')

def grep_lines(pattern, paths):
    """Run grep -rEnI, return list of `path:lineno:content` strings."""
    existing = [p for p in paths if pathlib.Path(p).exists()]
    if not existing:
        return []
    proc = subprocess.run(
        ['grep', '-rEnI', pattern, *existing],
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
# Pattern 3: Rust format-string escaped-quote form: \"kind\":\"fleet_scale_change\"
# Common in format! / write! macros where the JSON is built inline.
# INFRA-1287: adds ~33 new emit sites (daemon_tick, fleet_scale_change, etc.)
emitted |= extract_kinds(
    grep_lines(r'\\"kind\\":\\"[a-zA-Z0-9_]+\\"', ['src/', 'crates/']),
    r'\\"kind\\":\\"([a-zA-Z0-9_]+)\\"',
)
# Pattern 4: Shell _emit "kind_name" — function-mediated emits.
# fleet-wedge-handler.sh, active-target-reaper.sh, etc.
# INFRA-1287: adds ~13 new emit sites.
emitted |= extract_kinds(
    grep_lines(r'_emit\s+"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'_emit\s+"([a-zA-Z0-9_]+)"',
)
# Pattern 5a: emit_alert "kind_name" — ambient-watch.sh.
# INFRA-1287: catches lease_overlap, edit_burst, silent_agent from scripts/dev/.
emitted |= extract_kinds(
    grep_lines(r'emit_alert\s+"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'emit_alert\s+"([a-zA-Z0-9_]+)"',
)
# Pattern 5b: emit_ambient "kind_name" — disk-health-monitor.sh, auto-merge-armer.sh,
# scripts/coord/pr-rescue.sh, and many scripts/ops/ scripts.
# grep -E doesn't support lookbehind, so filter out `_emit_ambient` lines
# in extract_kinds instead of the grep pattern.
# `_emit_ambient` in free-tier-e2e-test.sh takes status codes ("pass","fail"),
# not event kinds — skip those lines.
def extract_kinds_no_prefix_emit(lines, kind_re):
    """Like extract_kinds but skip lines containing _emit_ambient."""
    out = set()
    for line in lines:
        parts = line.split(':', 2)
        if len(parts) < 3:
            continue
        path = parts[0]
        if any(p in path for p in SKIP_PATTERNS):
            continue
        content = parts[2]
        if '_emit_ambient' in content:
            continue
        m = re.search(kind_re, content)
        if m:
            out.add(m.group(1))
    return out

emitted |= extract_kinds_no_prefix_emit(
    grep_lines(r'emit_ambient\s+"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'emit_ambient\s+"([a-zA-Z0-9_]+)"',
)

# Pattern 5c: emit_event "kind_name" — Content Bots Suite dispatcher +
# orchestrator (INFRA-1695, INFRA-1698) use this shell-function form.
emitted |= extract_kinds_no_prefix_emit(
    grep_lines(r'emit_event\s+"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'emit_event\s+"([a-zA-Z0-9_]+)"',
)

# Pattern 6: known alert_kind= variable assignments.
# Narrowly scoped to `alert_kind=` (reaper-heartbeat-watchdog.sh, watchdogs).
# Avoids the noise from broader `*kind*=` patterns that catch internal state
# variables like _cooldown_kind="wedge" which are NOT event kinds.
emitted |= extract_kinds(
    grep_lines(r'alert_kind\s*=\s*"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'alert_kind\s*=\s*"([a-zA-Z0-9_]+)"',
)
# Pattern 7: emit_reaper_event "kind_name" — reaper observability helper.
# Used in scripts/ops/active-target-reaper.sh, scripts/ops/stale-worktree-reaper.sh,
# scripts/coord/worktree-prune.sh. First quoted argument is the kind name.
# INFRA-1287: catches worktree_reap_protected, worktree_reaper_skipped_active, etc.
emitted |= extract_kinds(
    grep_lines(r'emit_reaper_event\s+"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'emit_reaper_event\s+"([a-zA-Z0-9_]+)"',
)
# Pattern 8: EMIT_KIND "kind_name" — uppercase shell helper variant.
# INFRA-1659: conflict-resolver-agent (INFRA-1488) originally shipped with this
# uppercase helper; scanner missed all 8 of its kinds until the helper was
# renamed to _emit. Accepting both casings is more permissive than enforcing
# a naming convention by silent failure.
emitted |= extract_kinds(
    grep_lines(r'EMIT_KIND\s+"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'EMIT_KIND\s+"([a-zA-Z0-9_]+)"',
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
# 'test' is emitted in #[cfg(test)] blocks in src/ (e.g. ambient_rotate.rs)
# which are stripped in production builds — not a real event kind.
NOISE = {'X', 'kind', 'name', 'value', 'type', 'event', 'other', 'test'}
emitted -= NOISE

emit_without_register = sorted((emitted - registered) - allowlist)
# INFRA-1982: exclude deprecated kinds from orphan check — they are intentionally
# no longer emitted but are kept in the registry for historical query compatibility.
register_without_emit = sorted(((registered - emitted) - allowlist) - deprecated_kinds)

# ── INFRA-1371: effect_metric check ──────────────────────────────────────────
# Parse which registered kinds have an effect_metric declaration.
# A kind entry looks like:
#   - kind: session_start
#     effect_metric: self
# We build a dict: kind_name → True/False (has effect_metric on next line).
lines = yaml_text.splitlines()
kinds_missing_effect_metric = []
i = 0
while i < len(lines):
    line = lines[i]
    m = re.match(r'^\s*-\s+kind:\s*([A-Za-z0-9_]+)', line)
    if m:
        kind_name = m.group(1)
        # Check if any of the next few lines (before next '  - kind:') has effect_metric
        has_em = False
        j = i + 1
        while j < len(lines) and not re.match(r'^\s*-\s+kind:', lines[j]):
            if re.match(r'^\s+effect_metric:\s*\S', lines[j]):
                has_em = True
                break
            j += 1
        if not has_em and kind_name not in allowlist:
            # Only flag kinds that are emitted in code (new-kind check)
            if kind_name in emitted:
                kinds_missing_effect_metric.append(kind_name)
    i += 1

# ── Report ──
print(f"[event-registry-audit] mode={mode}")
print(f"[event-registry-audit] registered={len(registered)} "
      f"emitted={len(emitted)} allowlisted={len(allowlist)}")
print(f"[event-registry-audit] emitted-missing-effect_metric: {len(kinds_missing_effect_metric)}")
for k in sorted(kinds_missing_effect_metric):
    print(f"  MISSING-EFFECT-METRIC: {k}")
print(f"[event-registry-audit] emit-without-register: {len(emit_without_register)}")
for k in emit_without_register:
    print(f"  EMIT-NO-REG: {k}")
print(f"[event-registry-audit] register-without-emit (orphans): "
      f"{len(register_without_emit)}")
# INFRA-1287: always print the full orphan list in report mode (grouped alpha).
# In non-report modes, print first 5 + count for CI log brevity.
if register_without_emit:
    if mode == 'report':
        for k in register_without_emit:
            print(f"  ORPHAN: {k}")
    else:
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
# INFRA-1371: emitted kinds without effect_metric fail in strict-emit mode too.
if kinds_missing_effect_metric:
    print("[event-registry-audit] FAIL: emitted kinds missing effect_metric — "
          "add 'effect_metric: self' (or a specific metric name) to each entry "
          "in docs/observability/EVENT_REGISTRY.yaml. See docs/observability/"
          "EVENT_REGISTRY_FORMAT.md for guidance.",
          file=sys.stderr)
    sys.exit(3)
print("[event-registry-audit] OK")
sys.exit(0)
PYEOF
