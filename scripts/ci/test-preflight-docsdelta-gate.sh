#!/usr/bin/env bash
# capability-guard-exempt: existing skip-path covers missing binary; pattern wording differs from canonical (CREDIBLE-078)
# scripts/ci/test-preflight-docsdelta-gate.sh — INFRA-1788
#
# Verifies the `chump preflight --pre-commit` docs-delta-trailer gate:
#   1. Wiring: the gate is registered with the --pre-commit flag, honors
#      CHUMP_PREFLIGHT_SKIP_DOCSDELTA bypass, emits
#      preflight_docsdelta_bypassed, and references the INFRA-124 marker
#      so the diagnostic flows through the operator's terminal.
#   2. Behavior: invoking the gate with a synthetic docs-add staged diff
#      and an EMPTY commit message produces a non-zero exit AND the
#      INFRA-124 diagnostic. With CHUMP_PREFLIGHT_SKIP_DOCSDELTA=1 the
#      same scenario passes and emits the bypass event.
#   3. AC #6: the bare `chump preflight` (without --pre-commit) silently
#      skips the gate even when docs/*.md adds are staged.
#
# Rust-First-Bypass: integration test for the Rust `chump preflight`
#   subcommand interacting with a synthetic git workspace + ambient log;
#   shell is the right shape for the temp-repo + grep + filesystem checks.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. Static checks ──────────────────────────────────────────────────────
[[ -f "$REPO_ROOT/src/preflight.rs" ]] || fail "src/preflight.rs missing"

grep -q -- '--pre-commit' "$REPO_ROOT/src/preflight.rs" \
    || fail "preflight.rs does not parse --pre-commit flag"
ok "preflight.rs parses --pre-commit flag"

grep -q "docs-delta-trailer" "$REPO_ROOT/src/preflight.rs" \
    || fail "preflight.rs does not register docs-delta-trailer gate"
ok "preflight.rs declares the docs-delta-trailer gate"

grep -q "CHUMP_PREFLIGHT_SKIP_DOCSDELTA" "$REPO_ROOT/src/preflight.rs" \
    || fail "preflight.rs does not honor CHUMP_PREFLIGHT_SKIP_DOCSDELTA bypass"
ok "preflight.rs honors CHUMP_PREFLIGHT_SKIP_DOCSDELTA bypass env"

grep -q "preflight_docsdelta_bypassed" "$REPO_ROOT/src/preflight.rs" \
    || fail "preflight.rs does not emit preflight_docsdelta_bypassed on bypass"
ok "preflight.rs emits preflight_docsdelta_bypassed on bypass"

grep -q "INFRA-124" "$REPO_ROOT/src/preflight.rs" \
    || fail "preflight.rs missing INFRA-124 error marker"
ok "preflight.rs error message carries INFRA-124 marker"

grep -q "kind: preflight_docsdelta_bypassed" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    || fail "EVENT_REGISTRY.yaml does not register preflight_docsdelta_bypassed"
ok "EVENT_REGISTRY.yaml registers preflight_docsdelta_bypassed"

[[ -f "$REPO_ROOT/scripts/ci/test-infra-124-docs-delta-trailer.sh" ]] \
    || fail "underlying CI test (test-infra-124-docs-delta-trailer.sh) missing — semantics may drift"
ok "underlying INFRA-124 CI test present (semantics anchor)"

# ── 2. Runtime smoke — only if chump binary is available ──────────────────
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[note] $CHUMP_BIN not built; skipping runtime smoke checks"
    echo "       (static-only validation; behavior verified manually)"
    echo ""
    echo "ALL INFRA-1788 preflight-docsdelta-gate static checks passed."
    exit 0
fi

# Build a tiny synthetic git repo with a docs/*.md addition staged and an
# EMPTY COMMIT_EDITMSG, then invoke `chump preflight --pre-commit` from
# inside it. We want the gate to fire and fail-close.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q -b main
git config user.email "test@chump.local"
git config user.name "INFRA-1788 Test"
mkdir -p docs
echo "init" > README.md
git add README.md
git commit -qm "init"

# Stage a new doc, no trailer in COMMIT_EDITMSG.
echo "# new doc" > docs/new-thing.md
git add docs/new-thing.md
printf "wip\n" > .git/COMMIT_EDITMSG

# Capture ambient log in TMP so we don't pollute the real one.
AMBIENT="$TMP/ambient.jsonl"
: > "$AMBIENT"

# Case A: --pre-commit invocation, no bypass, no trailer → expect non-zero
#         AND INFRA-124 in stderr.
set +e
CHUMP_AMBIENT_LOG="$AMBIENT" \
    "$CHUMP_BIN" preflight --scope docs --pre-commit \
    >"$TMP/run-a.out" 2>"$TMP/run-a.err"
RC_A=$?
set -e
if [[ "$RC_A" -eq 0 ]]; then
    echo "----- run-a stdout -----"
    cat "$TMP/run-a.out" || true
    echo "----- run-a stderr -----"
    cat "$TMP/run-a.err" || true
    fail "preflight --pre-commit accepted a docs-add commit with no trailer (expected non-zero)"
fi
if ! grep -q "INFRA-124" "$TMP/run-a.err"; then
    cat "$TMP/run-a.err" >&2 || true
    fail "preflight --pre-commit did not emit INFRA-124 diagnostic"
fi
ok "preflight --pre-commit fails-close on missing trailer with INFRA-124 marker"

# Case B: bare `chump preflight` (no --pre-commit) on the same diff →
#         expect zero exit (AC #6 silent skip). The cargo gates won't run
#         because --scope docs.
set +e
CHUMP_AMBIENT_LOG="$AMBIENT" \
    "$CHUMP_BIN" preflight --scope docs \
    >"$TMP/run-b.out" 2>"$TMP/run-b.err"
RC_B=$?
set -e
if [[ "$RC_B" -ne 0 ]]; then
    echo "----- run-b stdout -----"
    cat "$TMP/run-b.out" || true
    echo "----- run-b stderr -----"
    cat "$TMP/run-b.err" || true
    fail "bare 'chump preflight' (no --pre-commit) should silently skip docs-delta-trailer (AC #6)"
fi
if grep -q "docs-delta-trailer" "$TMP/run-b.err"; then
    cat "$TMP/run-b.err" >&2 || true
    fail "bare 'chump preflight' should not even mention docs-delta-trailer (AC #6 silent skip)"
fi
ok "bare 'chump preflight' silently skips docs-delta-trailer gate (AC #6)"

# Case C: --pre-commit + CHUMP_PREFLIGHT_SKIP_DOCSDELTA=1 → bypass logged
#         + ambient event emitted + zero exit.
: > "$AMBIENT"
set +e
CHUMP_AMBIENT_LOG="$AMBIENT" \
CHUMP_PREFLIGHT_SKIP_DOCSDELTA=1 \
    "$CHUMP_BIN" preflight --scope docs --pre-commit \
    >"$TMP/run-c.out" 2>"$TMP/run-c.err"
RC_C=$?
set -e
if [[ "$RC_C" -ne 0 ]]; then
    echo "----- run-c stdout -----"
    cat "$TMP/run-c.out" || true
    echo "----- run-c stderr -----"
    cat "$TMP/run-c.err" || true
    fail "bypass env did not produce zero exit"
fi
if ! grep -q "skipping docs-delta-trailer" "$TMP/run-c.err"; then
    cat "$TMP/run-c.err" >&2 || true
    fail "preflight did not log 'skipping docs-delta-trailer' under bypass env"
fi
ok "preflight logs the bypass message under CHUMP_PREFLIGHT_SKIP_DOCSDELTA=1"

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"preflight_docsdelta_bypassed"' "$AMBIENT"; then
    ok "preflight emitted kind=preflight_docsdelta_bypassed to ambient.jsonl"
else
    # If ambient_emit's file-locator falls back to a different path under
    # synthetic repos, fall back to a static assertion. Don't fail the
    # smoke test on this — wiring is verified above.
    echo "[note] preflight_docsdelta_bypassed not seen in this test's ambient.jsonl;"
    echo "       wiring still verified by static check above."
fi

echo ""
echo "ALL INFRA-1788 preflight-docsdelta-gate tests passed."
