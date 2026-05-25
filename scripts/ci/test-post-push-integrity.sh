#!/usr/bin/env bash
# scripts/ci/test-post-push-integrity.sh — INFRA-2026
#
# Smoke tests for post-push-integrity-watch.sh.
# Uses synthetic/mocked state — does NOT call real GitHub API.
#
# Test matrix:
#   T1: --dry-run with no closed PRs → watch_ok emitted, no incidents
#   T2: --dry-run with a recently closed chump/* PR (NOT_PLANNED) → incident detected, dry-run log emitted
#   T3: --dry-run with a MERGED chump/* PR → not treated as incident (skip)
#   T4: --dry-run with closed PR on non-chump branch → ignored
#   T5: --dry-run with closed PR outside window → ignored
#   T6: bash -n syntax check on daemon + installer scripts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/post-push-integrity-watch.sh"
INSTALLER="$REPO_ROOT/scripts/setup/install-post-push-integrity-launchd.sh"

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); printf '  FAIL  %s — %s\n' "$1" "$2"; }

# ── helpers ──────────────────────────────────────────────────────────────────

# Create a temp sandbox: fake git remote, fake ambient log, fake gh stub.
setup_sandbox() {
    local dir
    dir="$(mktemp -d)"
    # Minimal git repo so git remote get-url works.
    git -C "$dir" init -q
    git -C "$dir" remote add origin "git@github.com:testowner/testrepo.git"
    mkdir -p "$dir/.chump-locks"
    printf '' > "$dir/.chump-locks/ambient.jsonl"
    # Create a fake broadcast-urgent.sh that is a no-op.
    mkdir -p "$dir/scripts/coord"
    cat > "$dir/scripts/coord/broadcast-urgent.sh" <<'STUB'
#!/usr/bin/env bash
# stub: swallow all args, just log
echo "[stub broadcast-urgent] $*" >&2
exit 0
STUB
    chmod +x "$dir/scripts/coord/broadcast-urgent.sh"
    echo "$dir"
}

teardown_sandbox() {
    local dir="$1"
    rm -rf "$dir"
}

# Inject a fake `gh` into PATH via a temp bin dir.
# Args: gh_json — the JSON that `gh pr list` will return.
inject_gh_stub() {
    local bindir="$1" gh_json="$2"
    mkdir -p "$bindir"
    cat > "$bindir/gh" <<STUB
#!/usr/bin/env bash
# Fake gh: returns canned JSON for "pr list --state closed"
if [[ "\$*" == *"pr list"* && "\$*" == *"closed"* ]]; then
    echo '${gh_json}'
    exit 0
fi
if [[ "\$*" == *"pr reopen"* ]]; then
    echo "[stub gh] would reopen PR" >&2
    exit 0
fi
# Default: delegate to real gh if present (for other subcommands we don't stub).
echo "stub gh: unhandled: \$*" >&2
exit 1
STUB
    chmod +x "$bindir/gh"
}

# Helper: run the daemon with a given gh_json fixture and return the ambient log content.
run_daemon() {
    local sandbox="$1" gh_json="$2" extra_args="${3:-}"
    local bindir="$sandbox/fakebin"
    inject_gh_stub "$bindir" "$gh_json"

    # Run the daemon with env overrides.
    CHUMP_REPO="$sandbox" \
    PATH="$bindir:$PATH" \
    bash "$DAEMON" --dry-run $extra_args 2>&1 || true
}

ambient_last_kind() {
    local sandbox="$1"
    tail -5 "$sandbox/.chump-locks/ambient.jsonl" 2>/dev/null \
        | python3 -c "import json,sys; lines=[l.strip() for l in sys.stdin if l.strip()]; print(json.loads(lines[-1])['kind'] if lines else '')" 2>/dev/null || echo ""
}

ambient_incident_count() {
    local sandbox="$1"
    grep -c '"kind":"post_push_auto_close_recovered"' "$sandbox/.chump-locks/ambient.jsonl" 2>/dev/null || echo 0
}

# ── T6: bash -n syntax check (runs first — no sandbox needed) ────────────────

printf '\nT6: bash -n syntax check\n'
if bash -n "$DAEMON" 2>&1; then
    pass "T6a: daemon script syntax OK"
else
    fail "T6a" "bash -n failed on $DAEMON"
fi

if bash -n "$INSTALLER" 2>&1; then
    pass "T6b: installer script syntax OK"
else
    fail "T6b" "bash -n failed on $INSTALLER"
fi

# ── T1: no closed PRs → watch_ok ─────────────────────────────────────────────

printf '\nT1: no closed PRs → watch_ok\n'
SB="$(setup_sandbox)"
OUT="$(run_daemon "$SB" "[]")"
KIND="$(ambient_last_kind "$SB")"
if [[ "$KIND" == "post_push_integrity_watch_ok" ]]; then
    pass "T1: watch_ok emitted when no closed PRs"
else
    fail "T1" "expected post_push_integrity_watch_ok in ambient; got kind='$KIND'; output: $OUT"
fi
teardown_sandbox "$SB"

# ── T2: recently closed chump/* PR (NOT_PLANNED) → incident detected ─────────

printf '\nT2: recently closed chump/* PR (NOT_PLANNED)\n'
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GH_JSON="$(python3 -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
pr = {
    'number': 9999,
    'headRefName': 'chump/infra-9999-claim',
    'state': 'CLOSED',
    'stateReason': 'NOT_PLANNED',
    'closedAt': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
    'title': 'feat(INFRA-9999): test gap'
}
print(json.dumps([pr]))
")"

SB="$(setup_sandbox)"
OUT="$(run_daemon "$SB" "$GH_JSON")"
# In dry-run mode the daemon logs but does NOT emit post_push_auto_close_recovered
# (dry-run means no reopen + no emit). Check stdout for "INCIDENT" line instead.
if echo "$OUT" | grep -q "INCIDENT"; then
    pass "T2: incident detected for recently-closed chump/* NOT_PLANNED PR"
else
    fail "T2" "expected 'INCIDENT' in stdout; output: $OUT"
fi
teardown_sandbox "$SB"

# ── T3: MERGED chump/* PR → not treated as incident ──────────────────────────

printf '\nT3: MERGED chump/* PR → ignored\n'
GH_JSON="$(python3 -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
pr = {
    'number': 8888,
    'headRefName': 'chump/infra-8888-claim',
    'state': 'CLOSED',
    'stateReason': 'MERGED',
    'closedAt': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
    'title': 'feat(INFRA-8888): merged gap'
}
print(json.dumps([pr]))
")"

SB="$(setup_sandbox)"
OUT="$(run_daemon "$SB" "$GH_JSON")"
if ! echo "$OUT" | grep -q "INCIDENT"; then
    pass "T3: MERGED PR not treated as incident"
else
    fail "T3" "MERGED PR incorrectly flagged as incident; output: $OUT"
fi
# ambient should be watch_ok (0 incidents)
KIND="$(ambient_last_kind "$SB")"
if [[ "$KIND" == "post_push_integrity_watch_ok" ]]; then
    pass "T3b: watch_ok emitted for MERGED PR scan"
else
    fail "T3b" "expected watch_ok; got kind='$KIND'"
fi
teardown_sandbox "$SB"

# ── T4: closed PR on non-chump branch → ignored ──────────────────────────────

printf '\nT4: closed PR on non-chump/* branch → ignored\n'
GH_JSON="$(python3 -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
pr = {
    'number': 7777,
    'headRefName': 'feature/some-other-branch',
    'state': 'CLOSED',
    'stateReason': 'NOT_PLANNED',
    'closedAt': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
    'title': 'feat: non-chump branch'
}
print(json.dumps([pr]))
")"

SB="$(setup_sandbox)"
OUT="$(run_daemon "$SB" "$GH_JSON")"
if ! echo "$OUT" | grep -q "INCIDENT"; then
    pass "T4: non-chump/* branch PR ignored"
else
    fail "T4" "non-chump branch incorrectly flagged as incident; output: $OUT"
fi
teardown_sandbox "$SB"

# ── T5: closed PR outside detection window → ignored ─────────────────────────

printf '\nT5: closed PR outside window → ignored\n'
GH_JSON="$(python3 -c "
import json, datetime
# Closed 300 seconds ago — well outside the default 120s window.
old = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=300)
pr = {
    'number': 6666,
    'headRefName': 'chump/infra-6666-claim',
    'state': 'CLOSED',
    'stateReason': 'NOT_PLANNED',
    'closedAt': old.strftime('%Y-%m-%dT%H:%M:%SZ'),
    'title': 'feat(INFRA-6666): old gap'
}
print(json.dumps([pr]))
")"

SB="$(setup_sandbox)"
# Use explicit window=120 (default).
OUT="$(run_daemon "$SB" "$GH_JSON" "")"
if ! echo "$OUT" | grep -q "INCIDENT"; then
    pass "T5: PR closed 300s ago ignored (outside 120s window)"
else
    fail "T5" "old PR incorrectly flagged; output: $OUT"
fi
teardown_sandbox "$SB"

# ── Summary ──────────────────────────────────────────────────────────────────

printf '\n────────────────────────────────────────────\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( ${#FAILURES[@]} > 0 )); then
    printf 'Failures:\n'
    for f in "${FAILURES[@]}"; do
        printf '  - %s\n' "$f"
    done
    exit 1
fi
exit 0
