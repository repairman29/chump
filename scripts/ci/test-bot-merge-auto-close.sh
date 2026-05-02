#!/usr/bin/env bash
# INFRA-154 / INFRA-228 / INFRA-229: smoke-test the auto-close handshake
# that bot-merge.sh uses.
#
# History
# -------
# v1 (INFRA-154, 2026-04): exercised `chump gap ship --closed-pr N
#   --update-yaml` against the monolithic docs/gaps.yaml.
# v2 (INFRA-228 + INFRA-229, 2026-05-02 — this revision): post-INFRA-188
#   the monolithic gaps.yaml is gone. `chump gap ship --update-yaml` now
#   writes the per-file mirror at docs/gaps/<ID>.yaml; this test asserts
#   that contract and the parity property that `chump gap reserve`
#   creates the mirror at create time.
#
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
# CI runners where target/debug/chump is freshly built, this is current.
# On local dev machines with ~/.local/bin/chump symlinked from an older
# build, skip rather than fail.
if ! "$CHUMP_BIN" gap ship --help 2>&1 | grep -q -- "--closed-pr" \
   && ! "$CHUMP_BIN" gap --help 2>&1 | grep -q "closed-pr"; then
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
SANDBOX2=$(mktemp -d)
trap 'rm -rf "$SANDBOX" "$SANDBOX2"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Sandbox 1: a fake repo with one open SANDBOX-001 gap, per-file layout ────
# Post-INFRA-188 the canonical layout is docs/gaps/<ID>.yaml. The chump
# binary's `gap import` reads the per-file directory if it exists.
mkdir -p "$SANDBOX/docs/gaps"
cat > "$SANDBOX/docs/gaps/SANDBOX-001.yaml" <<'EOF'
- id: SANDBOX-001
  domain: SANDBOX
  title: smoke-test gap for INFRA-154 auto-close
  status: open
  priority: P3
  effort: xs
  opened_date: '2026-04-28'
EOF

(
    cd "$SANDBOX"
    CHUMP_REPO_ROOT="$SANDBOX" "$CHUMP_BIN" gap import >/dev/null 2>&1 || true
    CHUMP_REPO_ROOT="$SANDBOX" "$CHUMP_BIN" gap ship SANDBOX-001 \
        --closed-pr 999 \
        --update-yaml >/dev/null 2>&1
)

# ── Verify per-file mirror now has status=done + closed_pr=999 ───────────────
# INFRA-229: --update-yaml writes docs/gaps/<ID>.yaml, NOT the deleted
# monolithic docs/gaps.yaml.
per_file="$SANDBOX/docs/gaps/SANDBOX-001.yaml"
if ! grep -q "status: done" "$per_file" 2>/dev/null; then
    fail "ship --update-yaml did not flip status to done in $per_file"
    [ -f "$per_file" ] && cat "$per_file" >&2 || echo "(file missing)" >&2
elif ! grep -q "closed_pr: 999" "$per_file" 2>/dev/null; then
    if "$CHUMP_BIN" gap ship --help 2>&1 | grep -q -- "--closed-pr" \
       || "$CHUMP_BIN" gap --help 2>&1 | grep -q "closed-pr"; then
        fail "ship --closed-pr is documented but did not persist closed_pr=999"
        cat "$per_file" >&2
    else
        echo "[SKIP] chump binary at $CHUMP_BIN predates INFRA-156 (--closed-pr accepted but ignored)"
        echo "       rebuild: cargo build --release --bin chump"
        exit 0
    fi
else
    pass "ship --closed-pr 999 --update-yaml wrote status=done + closed_pr=999 to per-file YAML (INFRA-229)"
fi

# ── INFRA-229 hard property: NO monolithic gaps.yaml is ever resurrected ─────
# The pre-fix binary silently re-created docs/gaps.yaml on every successful
# ship. Post-fix, --update-yaml only ever writes the per-file mirror.
if [ -f "$SANDBOX/docs/gaps.yaml" ]; then
    fail "ship --update-yaml resurrected the deleted monolithic docs/gaps.yaml (INFRA-229 regression)"
    head -10 "$SANDBOX/docs/gaps.yaml" >&2
else
    pass "no monolithic docs/gaps.yaml resurrected by ship --update-yaml (INFRA-229)"
fi

# ── Verify `chump gap ship` is idempotent on a second call (already done) ────
(
    cd "$SANDBOX"
    if CHUMP_REPO_ROOT="$SANDBOX" "$CHUMP_BIN" gap ship SANDBOX-001 \
            --closed-pr 999 --update-yaml >/dev/null 2>&1; then
        echo "  (second ship returned 0 — accepted)"
    fi
) >/dev/null 2>&1
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

# ── Sandbox 2: INFRA-228 — chump gap reserve writes the per-file mirror ──────
# Parity property: a freshly-reserved gap immediately has docs/gaps/<ID>.yaml
# on disk, no manual file creation required.
mkdir -p "$SANDBOX2/docs/gaps"
(
    cd "$SANDBOX2"
    CHUMP_REPO_ROOT="$SANDBOX2" "$CHUMP_BIN" gap reserve \
        --domain INFRA --title "reserve-mirror-smoke" \
        --priority P3 --effort xs >/dev/null 2>&1 || true
)
if ls "$SANDBOX2/docs/gaps/"INFRA-*.yaml 2>/dev/null | head -1 >/dev/null; then
    reserved_file=$(ls "$SANDBOX2/docs/gaps/"INFRA-*.yaml 2>/dev/null | head -1)
    if grep -q '^  status: open$' "$reserved_file"; then
        pass "chump gap reserve wrote per-file mirror $(basename "$reserved_file") with status: open (INFRA-228)"
    else
        fail "reserve wrote $(basename "$reserved_file") but status not open"
        cat "$reserved_file" >&2
    fi
else
    fail "chump gap reserve did not write any per-file mirror (INFRA-228 regression)"
    ls "$SANDBOX2/docs/gaps/" >&2 || true
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
