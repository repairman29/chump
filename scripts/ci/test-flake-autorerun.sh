#!/usr/bin/env bash
# test-flake-autorerun.sh — INFRA-764 unit tests for cargo-test-with-rerun.sh.
#
# Acceptance criteria
#   1. Pass-through: command exits 0 → wrapper exits 0
#   2. Real failure (test NOT in catalog) → wrapper exits non-zero, no rerun
#   3. All failures in catalog → wrapper auto-reruns once
#   4. Catalog rerun green → wrapper exits 0 (recovered)
#   5. Catalog rerun still red → wrapper exits non-zero (persisted)
#   6. CHUMP_FLAKE_AUTORERUN=0 bypass → no auto-rerun even on catalog hit

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-764 flake-autorerun harness tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/ci/cargo-test-with-rerun.sh"

if [[ ! -x "$WRAPPER" ]]; then
    echo "FATAL: wrapper not executable: $WRAPPER"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Set up a stand-alone fake repo with its own KNOWN_FLAKES.yaml so the
# test doesn't accidentally cross-pollute the real catalog.
FAKE="$TMP/repo"
mkdir -p "$FAKE/docs/process" "$FAKE/scripts/ci" "$FAKE/.chump-locks"
git -C "$FAKE" init -q -b main
cp "$WRAPPER" "$FAKE/scripts/ci/cargo-test-with-rerun.sh"
chmod +x "$FAKE/scripts/ci/cargo-test-with-rerun.sh"

# Catalog seeded with one known flake test name.
cat > "$FAKE/docs/process/KNOWN_FLAKES.yaml" <<'YAML'
schema_version: 1
flakes:
  - test: known_module::tests::flaky_one
    reason: "synthetic catalog entry for INFRA-764 fixture"
    tracking_gap: INFRA-764
    added: "2026-05-08"
    last_observed: "2026-05-08"
    max_reruns: 1
YAML

# Need an initial commit so git rev-parse --show-toplevel works.
git -C "$FAKE" add . && git -C "$FAKE" -c user.email=t@t -c user.name=t commit -q -m s

# Helper: stand up a fake `cargo` binary on PATH whose behavior is
# controlled by env vars + a state file.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cargo" <<'MOCK'
#!/usr/bin/env bash
# Mock cargo: emits cargo-test-style output. Behavior controlled by env:
#   FAKE_FAIL_NAMES — comma-separated test names to mark FAILED on the FIRST run.
#   FAKE_FAIL_NAMES_RERUN — same, used on the SECOND run (default: empty → green).
# Tracks invocation count via $TMP_STATE/cargo.count file.
case "$1" in
    test)
        STATE_DIR="${TMP_STATE:?need TMP_STATE}"
        mkdir -p "$STATE_DIR"
        COUNT_FILE="$STATE_DIR/cargo.count"
        n=0
        [[ -f "$COUNT_FILE" ]] && n=$(<"$COUNT_FILE")
        n=$((n+1))
        echo "$n" > "$COUNT_FILE"

        if [[ "$n" == "1" ]]; then
            names="${FAKE_FAIL_NAMES:-}"
        else
            names="${FAKE_FAIL_NAMES_RERUN:-}"
        fi
        IFS=',' read -ra arr <<< "$names"
        for t in "${arr[@]}"; do
            [[ -z "$t" ]] && continue
            echo "test $t ... FAILED"
        done
        echo "test passing_one ... ok"
        if [[ -z "$names" ]]; then
            echo "test result: ok. 1 passed; 0 failed"
            exit 0
        else
            echo "test result: FAILED. 1 passed; $(echo "$names" | tr , '\n' | grep -c .) failed"
            exit 101
        fi
        ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$TMP/bin/cargo"

# Helper: invoke the wrapper from inside the fake repo with mocked cargo.
run_wrapper() {
    cd "$FAKE" || return 2
    PATH="$TMP/bin:$PATH" \
    TMP_STATE="$TMP/state-$$-${RANDOM}" \
    FAKE_FAIL_NAMES="${FAKE_FAIL_NAMES:-}" \
    FAKE_FAIL_NAMES_RERUN="${FAKE_FAIL_NAMES_RERUN:-}" \
    bash "$FAKE/scripts/ci/cargo-test-with-rerun.sh" -- cargo test 2>&1
    RC=$?
    cd - >/dev/null || true
    return "$RC"
}

# ── Test 1: pass-through ────────────────────────────────────────────────────
echo "--- Test 1: pass-through (no failures) → wrapper exits 0 ---"
OUT=$(FAKE_FAIL_NAMES="" run_wrapper)
RC=$?
if [[ "$RC" -eq 0 ]]; then
    ok "clean pass-through"
else
    fail "expected exit 0 (rc=$RC, out=$OUT)"
fi

# ── Test 2: unknown failure → no rerun, exit non-zero ───────────────────────
echo "--- Test 2: unknown failure → no rerun, exit non-zero ---"
OUT=$(FAKE_FAIL_NAMES="some::real::bug" run_wrapper)
RC=$?
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -q "not auto-rerunning"; then
    ok "unknown failure not auto-rerun"
else
    fail "expected non-zero + no-rerun message (rc=$RC)"
fi

# ── Test 3: catalog hit → auto-rerun → green ────────────────────────────────
echo "--- Test 3: catalog hit, rerun green → wrapper exits 0 (recovered) ---"
OUT=$(FAKE_FAIL_NAMES="known_module::tests::flaky_one" \
      FAKE_FAIL_NAMES_RERUN="" \
      run_wrapper)
RC=$?
if [[ "$RC" -eq 0 ]] \
   && echo "$OUT" | grep -q "flake_autorerun_initiated" \
   && echo "$OUT" | grep -q "flake_autorerun_recovered"; then
    ok "catalog hit auto-rerun recovered"
else
    fail "expected recover (rc=$RC, out=$OUT)"
fi

# ── Test 4: catalog hit → auto-rerun → still red ────────────────────────────
echo "--- Test 4: catalog hit, rerun still red → wrapper exits non-zero (persisted) ---"
OUT=$(FAKE_FAIL_NAMES="known_module::tests::flaky_one" \
      FAKE_FAIL_NAMES_RERUN="known_module::tests::flaky_one" \
      run_wrapper)
RC=$?
if [[ "$RC" -ne 0 ]] \
   && echo "$OUT" | grep -q "flake_autorerun_persisted"; then
    ok "catalog hit persisted failure surfaces"
else
    fail "expected persisted failure (rc=$RC, out=$OUT)"
fi

# ── Test 5: bypass env → no auto-rerun ──────────────────────────────────────
echo "--- Test 5: CHUMP_FLAKE_AUTORERUN=0 → no rerun, raw signal ---"
cd "$FAKE" || exit 2
PATH="$TMP/bin:$PATH" \
TMP_STATE="$TMP/state-bypass" \
FAKE_FAIL_NAMES="known_module::tests::flaky_one" \
CHUMP_FLAKE_AUTORERUN=0 \
bash "$FAKE/scripts/ci/cargo-test-with-rerun.sh" -- cargo test >/tmp/bypass.out 2>&1
RC=$?
cd - >/dev/null || true
if [[ "$RC" -ne 0 ]] && ! grep -q "flake_autorerun_initiated" /tmp/bypass.out; then
    ok "bypass returns raw signal without rerun"
else
    fail "bypass should not rerun (rc=$RC, log: $(cat /tmp/bypass.out))"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
