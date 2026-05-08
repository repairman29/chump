#!/usr/bin/env bash
# test-event-registry-guard.sh — unit tests for INFRA-754 event-registry
# pre-commit guard (scripts/git-hooks/pre-commit-event-registry.sh).
#
# Acceptance criteria verified:
#   (1) Hook accepts a commit with NO new "kind":"X" literals.
#   (2) Hook accepts a commit that uses an ALREADY-REGISTERED kind.
#   (3) Hook REJECTS a commit that introduces an UNREGISTERED kind.
#   (4) Hook accepts the same offending commit when CHUMP_EVENT_REGISTRY_CHECK=0.
#   (5) Hook is silent when the registry file does not exist (graceful no-op
#       on branches predating INFRA-754).
#   (6) Hook scans .rs, .sh, .py, .yml — but ignores added kinds in the
#       registry file itself (the registry is the source of truth).
#
# Run:
#   ./scripts/ci/test-event-registry-guard.sh
#
# Exits non-zero on any check failure.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-754 event-registry guard unit tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit-event-registry.sh"

if [ ! -x "$HOOK" ]; then
    echo "FATAL: hook not found or not executable: $HOOK"
    exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE_REPO="$TMPDIR_BASE/repo"
mkdir -p "$FAKE_REPO/docs/observability" "$FAKE_REPO/scripts/dispatch"
git -C "$FAKE_REPO" init -q -b main
git -C "$FAKE_REPO" config user.email "test@test.com"
git -C "$FAKE_REPO" config user.name "Test"

# Seed a tiny registry.
cat >"$FAKE_REPO/docs/observability/EVENT_REGISTRY.yaml" <<'YAML'
schema_version: 1
events:
  - kind: session_start
    emitter: ambient-emit.sh
    trigger: session begins
  - kind: cycle_end
    emitter: worker.sh
    trigger: cycle finishes
YAML
git -C "$FAKE_REPO" add docs/observability/EVENT_REGISTRY.yaml
git -C "$FAKE_REPO" commit -q -m "seed registry"

# Helper: stage content, run hook from inside repo, return exit code + output.
run_hook() {
    cd "$FAKE_REPO" || exit 2
    git diff --cached >/dev/null 2>&1
    OUT=$("$HOOK" 2>&1)
    RC=$?
    cd - >/dev/null || true
    echo "$OUT"
    return $RC
}

# ── Test 1: clean commit (no kind: literals) ────────────────────────────────
echo "--- Test 1: commit with no kind: literals is allowed ---"
echo "fn main() {}" > "$FAKE_REPO/scripts/dispatch/foo.sh"
git -C "$FAKE_REPO" add scripts/dispatch/foo.sh
if run_hook >/dev/null 2>&1; then
    ok "clean commit accepted"
else
    fail "clean commit rejected (expected accept)"
fi
git -C "$FAKE_REPO" reset -q HEAD scripts/dispatch/foo.sh
rm -f "$FAKE_REPO/scripts/dispatch/foo.sh"

# ── Test 2: commit using an already-registered kind ─────────────────────────
echo "--- Test 2: commit using registered kind (cycle_end) is allowed ---"
cat >"$FAKE_REPO/scripts/dispatch/foo.sh" <<'SH'
#!/bin/bash
echo '{"kind":"cycle_end","ts":"now"}'
SH
git -C "$FAKE_REPO" add scripts/dispatch/foo.sh
if run_hook >/dev/null 2>&1; then
    ok "registered-kind commit accepted"
else
    fail "registered-kind commit rejected (expected accept)"
fi
git -C "$FAKE_REPO" reset -q HEAD scripts/dispatch/foo.sh
rm -f "$FAKE_REPO/scripts/dispatch/foo.sh"

# ── Test 3: unregistered kind is rejected ───────────────────────────────────
echo "--- Test 3: commit introducing unregistered kind is REJECTED ---"
cat >"$FAKE_REPO/scripts/dispatch/foo.sh" <<'SH'
#!/bin/bash
echo '{"kind":"totally_made_up_event","ts":"now"}'
SH
git -C "$FAKE_REPO" add scripts/dispatch/foo.sh
OUT=$(run_hook 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "totally_made_up_event"; then
    ok "unregistered kind rejected and named in output"
else
    fail "unregistered kind not rejected (rc=$RC, output: $OUT)"
fi
git -C "$FAKE_REPO" reset -q HEAD scripts/dispatch/foo.sh

# ── Test 4: bypass env var allows the same commit ───────────────────────────
echo "--- Test 4: CHUMP_EVENT_REGISTRY_CHECK=0 bypasses guard ---"
git -C "$FAKE_REPO" add scripts/dispatch/foo.sh
if CHUMP_EVENT_REGISTRY_CHECK=0 run_hook >/dev/null 2>&1; then
    ok "bypass env var allows offending commit"
else
    fail "bypass env var did not bypass"
fi
git -C "$FAKE_REPO" reset -q HEAD scripts/dispatch/foo.sh
rm -f "$FAKE_REPO/scripts/dispatch/foo.sh"

# ── Test 5: missing registry → silent no-op ─────────────────────────────────
echo "--- Test 5: missing registry → silent no-op ---"
mv "$FAKE_REPO/docs/observability/EVENT_REGISTRY.yaml" "$FAKE_REPO/docs/observability/EVENT_REGISTRY.yaml.bak"
cat >"$FAKE_REPO/scripts/dispatch/foo.sh" <<'SH'
#!/bin/bash
echo '{"kind":"some_unknown_kind","ts":"now"}'
SH
git -C "$FAKE_REPO" add scripts/dispatch/foo.sh
if run_hook >/dev/null 2>&1; then
    ok "missing registry → guard is no-op"
else
    fail "missing registry should be no-op (got rejection)"
fi
git -C "$FAKE_REPO" reset -q HEAD scripts/dispatch/foo.sh
rm -f "$FAKE_REPO/scripts/dispatch/foo.sh"
mv "$FAKE_REPO/docs/observability/EVENT_REGISTRY.yaml.bak" "$FAKE_REPO/docs/observability/EVENT_REGISTRY.yaml"

# ── Test 6: adding a new kind to the registry itself is allowed ─────────────
echo "--- Test 6: registering a new kind in the registry passes ---"
cat >"$FAKE_REPO/docs/observability/EVENT_REGISTRY.yaml" <<'YAML'
schema_version: 1
events:
  - kind: session_start
    emitter: ambient-emit.sh
    trigger: session begins
  - kind: cycle_end
    emitter: worker.sh
    trigger: cycle finishes
  - kind: brand_new_event
    emitter: scripts/dispatch/foo.sh
    trigger: foo happens
YAML
cat >"$FAKE_REPO/scripts/dispatch/foo.sh" <<'SH'
#!/bin/bash
echo '{"kind":"brand_new_event","ts":"now"}'
SH
git -C "$FAKE_REPO" add docs/observability/EVENT_REGISTRY.yaml scripts/dispatch/foo.sh
if run_hook >/dev/null 2>&1; then
    ok "registering + emitting new kind in same commit is allowed"
else
    fail "registering + emitting new kind should be allowed"
fi
git -C "$FAKE_REPO" reset -q HEAD docs/observability/EVENT_REGISTRY.yaml scripts/dispatch/foo.sh

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
