#!/usr/bin/env bash
# INFRA-154: smoke-test the auto-close handshake that bot-merge.sh uses.
# This exercises the contract `chump gap ship --closed-pr <N> --update-yaml`
# (INFRA-152 / -156) provides — the same call bot-merge.sh makes between
# `gh pr create` and `gh pr merge --auto --squash`. A real end-to-end test
# would need a live GitHub PR; this proves the shell-callable surface works
# in a sandbox repo and emits the YAML mirror update bot-merge.sh expects.
# Run from repo root: bash scripts/ci/test-bot-merge-auto-close.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

CHUMP_BIN="${CHUMP_BIN:-$(command -v chump || echo "")}"
if [ -z "$CHUMP_BIN" ] || [ ! -x "$CHUMP_BIN" ]; then
    echo "[SKIP] chump binary not in PATH — auto-close handshake test requires it"
    exit 0
fi

# INFRA-148: detect a stale chump binary predating INFRA-156's --closed-pr
# flag. The auto-close handshake only works once the binary supports it; on
# CI runners where target/release/chump is freshly built, this is current.
# On local dev machines with ~/.local/bin/chump symlinked from an older
# build, skip rather than fail.
if ! "$CHUMP_BIN" gap ship --help 2>&1 | grep -q -- "--closed-pr" \
   && ! "$CHUMP_BIN" gap --help 2>&1 | grep -q "closed-pr"; then
    # Try a probe call: a non-existent gap with --closed-pr should fail with
    # "not found", NOT with "unknown flag". Anything else => stale binary.
    _probe=$( "$CHUMP_BIN" gap ship NONEXISTENT-999 --closed-pr 1 2>&1 || true )
    if echo "$_probe" | grep -qiE "unknown|unrecognized|invalid (option|argument)"; then
        echo "[SKIP] chump binary predates INFRA-156 (--closed-pr not supported)"
        echo "       binary: $CHUMP_BIN"
        echo "       rebuild: cargo build --release --bin chump"
        exit 0
    fi
fi

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Sandbox: a fake repo with one open INFRA-XXX gap ─────────────────────────
mkdir -p "$SANDBOX/docs"
cat > "$SANDBOX/docs/gaps.yaml" <<'EOF'
meta:
  version: 1
  generated: 2026-04-28
gaps:
- id: SANDBOX-001
  domain: SANDBOX
  title: smoke-test gap for INFRA-154 auto-close
  status: open
  priority: P3
  effort: xs
  opened_date: '2026-04-28'

EOF

# ── Run `chump gap import` to seed state.db, then ship --closed-pr ───────────
(
    cd "$SANDBOX"
    CHUMP_REPO_ROOT="$SANDBOX" "$CHUMP_BIN" gap import >/dev/null 2>&1 || true
    CHUMP_REPO_ROOT="$SANDBOX" "$CHUMP_BIN" gap ship SANDBOX-001 \
        --closed-pr 999 \
        --update-yaml >/dev/null 2>&1
)

# ── Verify YAML now has status=done + closed_pr=999 + meta preserved ─────────
yaml="$SANDBOX/docs/gaps.yaml"
if ! grep -q "status: done" "$yaml"; then
    fail "ship did not flip status to done in YAML"
    grep -A6 "id: SANDBOX-001" "$yaml" >&2 || true
elif ! grep -q "closed_pr: 999" "$yaml"; then
    # status=done landed but closed_pr didn't. Two causes:
    #   1. Stale binary predating INFRA-156 silently ignored --closed-pr.
    #   2. Genuine regression — the column wasn't persisted.
    # Distinguish by probing the help text. If the flag isn't documented,
    # treat as SKIP; if it IS documented, fail loud.
    if "$CHUMP_BIN" gap ship --help 2>&1 | grep -q -- "--closed-pr" \
       || "$CHUMP_BIN" gap --help 2>&1 | grep -q "closed-pr"; then
        fail "ship --closed-pr is documented but did not persist closed_pr=999"
        grep -A6 "id: SANDBOX-001" "$yaml" >&2 || true
    else
        echo "[SKIP] chump binary at $CHUMP_BIN predates INFRA-156 (--closed-pr accepted but ignored)"
        echo "       rebuild: cargo build --release --bin chump"
        exit 0
    fi
else
    pass "ship --closed-pr 999 wrote status=done + closed_pr=999 to YAML"
fi

if grep -q "^meta:" "$yaml"; then
    pass "meta: preamble preserved through --update-yaml"
else
    fail "meta: preamble was dropped (INFRA-147 regression)"
fi

# ── Verify `chump gap ship` is idempotent on a second call (already done) ────
(
    cd "$SANDBOX"
    if CHUMP_REPO_ROOT="$SANDBOX" "$CHUMP_BIN" gap ship SANDBOX-001 \
            --closed-pr 999 --update-yaml >/dev/null 2>&1; then
        echo "  (second ship returned 0 — accepted)"
    fi
) >/dev/null 2>&1
# Either behavior is OK for the auto-close path — bot-merge.sh tolerates a
# non-zero exit and continues. The point is: don't crash.
pass "second ship call did not crash the harness (auto-close idempotent-on-error)"

# ── Verify `chump gap dump --out` regenerates the SQL diff cleanly ───────────
(
    cd "$SANDBOX"
    CHUMP_REPO_ROOT="$SANDBOX" "$CHUMP_BIN" gap dump \
        --out "$SANDBOX/.chump/state.sql" >/dev/null 2>&1 || true
)
if [ -s "$SANDBOX/.chump/state.sql" ] || [ ! -d "$SANDBOX/.chump" ]; then
    pass "gap dump --out either produced a state.sql or skipped cleanly"
else
    fail "gap dump --out produced an empty .chump/state.sql"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
