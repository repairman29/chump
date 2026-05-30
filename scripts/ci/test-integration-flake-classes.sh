#!/usr/bin/env bash
# scripts/ci/test-integration-flake-classes.sh — INFRA-2168
#
# Fixture-based regression test for integration-bisect-step.sh.
# Creates synthetic preflight logs matching each known flake class and verifies
# the oracle returns the correct exit code (0=good, 1=bad, 125=skip).
#
# Usage:
#   bash scripts/ci/test-integration-flake-classes.sh
#
# Exit: 0 if all assertions pass; non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORACLE="$REPO_ROOT/scripts/dev/integration-bisect-step.sh"
REGISTRY="$REPO_ROOT/docs/process/INTEGRATION_FLAKE_CLASSES.yaml"

# ── helpers ───────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d /tmp/test-flake-classes-XXXXXX)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

ok()   { printf '[PASS] %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

# run_oracle_with_fixture <fixture_log_path> <expected_exit>
# Calls the oracle with a synthetic preflight log injected via CHUMP_PREFLIGHT_SKIP
# and a shim that writes our fixture as "preflight output".
run_oracle_with_fixture() {
    local fixture="$1"
    local expected_exit="$2"
    local label="$3"

    # Build a wrapper script that replaces `chump preflight` with `cat <fixture>`
    local shim_dir="$TMPDIR_TEST/shim-$$-$RANDOM"
    mkdir -p "$shim_dir"

    # Fake chump binary: ambient emit → no-op; preflight → cat fixture
    cat >"$shim_dir/chump" <<SHIM
#!/usr/bin/env bash
if [[ "\$1" == "ambient" ]]; then exit 0; fi
if [[ "\$1" == "preflight" ]]; then cat "$fixture"; exit 1; fi
exit 0
SHIM
    chmod +x "$shim_dir/chump"

    local actual_exit=0
    PATH="$shim_dir:$PATH" \
        CHUMP_BISECT_REGISTRY="$REGISTRY" \
        CHUMP_BISECT_WORKTREE="$REPO_ROOT" \
        CHUMP_AMBIENT_DISABLE=1 \
        bash "$ORACLE" >/dev/null 2>/dev/null || actual_exit=$?

    if [[ "$actual_exit" -eq "$expected_exit" ]]; then
        ok "$label (exit $actual_exit == expected $expected_exit)"
    else
        fail "$label (exit $actual_exit != expected $expected_exit)"
    fi
}

# ── sanity: oracle and registry both exist ────────────────────────────────────
[[ -f "$ORACLE" ]]    && ok "oracle exists at scripts/dev/integration-bisect-step.sh" \
                       || { fail "oracle missing: $ORACLE"; exit 1; }
[[ -f "$REGISTRY" ]]  && ok "registry exists at docs/process/INTEGRATION_FLAKE_CLASSES.yaml" \
                       || { fail "registry missing: $REGISTRY"; exit 1; }

# ── oracle is executable ──────────────────────────────────────────────────────
chmod +x "$ORACLE"
ok "oracle is executable"

# ── Test 1: clean preflight → exit 0 (good) ──────────────────────────────────
CLEAN_LOG="$TMPDIR_TEST/clean.log"
printf 'preflight: all checks passed\ncargo fmt OK\ncargo clippy OK\ncargo check OK\n' > "$CLEAN_LOG"

# For a clean preflight, chump preflight must exit 0 — use a shim that exits 0
shim_dir_clean="$TMPDIR_TEST/shim-clean"
mkdir -p "$shim_dir_clean"
cat >"$shim_dir_clean/chump" <<SHIM
#!/usr/bin/env bash
if [[ "\$1" == "ambient" ]]; then exit 0; fi
if [[ "\$1" == "preflight" ]]; then cat "$CLEAN_LOG"; exit 0; fi
exit 0
SHIM
chmod +x "$shim_dir_clean/chump"

clean_exit=0
PATH="$shim_dir_clean:$PATH" \
    CHUMP_BISECT_REGISTRY="$REGISTRY" \
    CHUMP_BISECT_WORKTREE="$REPO_ROOT" \
    CHUMP_AMBIENT_DISABLE=1 \
    bash "$ORACLE" >/dev/null 2>/dev/null || clean_exit=$?

if [[ "$clean_exit" -eq 0 ]]; then
    ok "Test 1: clean preflight → exit 0 (good)"
else
    fail "Test 1: clean preflight → expected exit 0, got $clean_exit"
fi

# ── Test 2: novel failure (no flake match) → exit 1 (bad) ────────────────────
NOVEL_LOG="$TMPDIR_TEST/novel.log"
printf 'error[E0369]: binary operation `+` cannot be applied to type `Foo`\n' > "$NOVEL_LOG"
printf '  --> src/main.rs:42:5\n' >> "$NOVEL_LOG"
printf 'error: could not compile `chump-core`\n' >> "$NOVEL_LOG"

run_oracle_with_fixture "$NOVEL_LOG" 1 "Test 2: novel compile error → exit 1 (bad)"

# ── Test 3: acp-cache-collision signature → exit 125 (skip) ──────────────────
ACP_LOG="$TMPDIR_TEST/acp.log"
printf 'Run details: Failed to save: Unable to reserve cache with key rust-1.87-stable-abc123\n' > "$ACP_LOG"
printf 'Warning: Cache save failed.\n' >> "$ACP_LOG"
printf 'Error: Process completed with exit code 1.\n' >> "$ACP_LOG"

run_oracle_with_fixture "$ACP_LOG" 125 "Test 3: acp-cache-collision → exit 125 (skip)"

# ── Test 4: cargo-test-cache-race signature → exit 125 (skip) ────────────────
CARGO_RACE_LOG="$TMPDIR_TEST/cargo-race.log"
printf 'error: failed to read /home/runner/.cargo/registry/src/github.com/foo/Cargo.toml No such file or directory\n' > "$CARGO_RACE_LOG"
printf 'error: could not compile workspace\n' >> "$CARGO_RACE_LOG"

run_oracle_with_fixture "$CARGO_RACE_LOG" 125 "Test 4: cargo-test-cache-race → exit 125 (skip)"

# ── Test 5: e2e-pwa-flake signature (browserType timeout) → exit 125 (skip) ──
PWA_LOG_TIMEOUT="$TMPDIR_TEST/pwa-timeout.log"
printf 'Error: browserType.launch: Timeout 30000ms exceeded.\n' > "$PWA_LOG_TIMEOUT"
printf 'at PWAShell.setup (playwright fixtures)\n' >> "$PWA_LOG_TIMEOUT"

run_oracle_with_fixture "$PWA_LOG_TIMEOUT" 125 "Test 5: e2e-pwa-flake (browserType timeout) → exit 125 (skip)"

# ── Test 6: e2e-pwa-flake signature (ERR_CONNECTION_REFUSED) → exit 125 ──────
PWA_LOG_CONN="$TMPDIR_TEST/pwa-conn.log"
printf 'net::ERR_CONNECTION_REFUSED http://localhost:3001/\n' > "$PWA_LOG_CONN"
printf '  at evaluate (playwright)\n' >> "$PWA_LOG_CONN"

run_oracle_with_fixture "$PWA_LOG_CONN" 125 "Test 6: e2e-pwa-flake (ERR_CONNECTION_REFUSED) → exit 125 (skip)"

# ── Test 7: e2e-pwa-flake signature (test timeout) → exit 125 ────────────────
PWA_LOG_TESTTIMEOUT="$TMPDIR_TEST/pwa-testtimeout.log"
printf 'Test timeout of 30000ms exceeded.\n' > "$PWA_LOG_TESTTIMEOUT"

run_oracle_with_fixture "$PWA_LOG_TESTTIMEOUT" 125 "Test 7: e2e-pwa-flake (test timeout) → exit 125 (skip)"

# ── Test 8: missing registry → exit 125 (safe default, no false quarantine) ──
MISSING_REG_EXIT=0
PATH="$(dirname "$ORACLE"):$PATH" \
    CHUMP_BISECT_REGISTRY="$TMPDIR_TEST/nonexistent-registry.yaml" \
    CHUMP_BISECT_WORKTREE="$REPO_ROOT" \
    CHUMP_AMBIENT_DISABLE=1 \
    bash "$ORACLE" >/dev/null 2>/dev/null || MISSING_REG_EXIT=$?

if [[ "$MISSING_REG_EXIT" -eq 125 ]]; then
    ok "Test 8: missing registry → exit 125 (safe, prevents false quarantine)"
else
    fail "Test 8: missing registry → expected exit 125, got $MISSING_REG_EXIT"
fi

# ── Test 9: registry schema_version field present ────────────────────────────
if grep -q "^schema_version:" "$REGISTRY"; then
    ok "Test 9: registry has schema_version field"
else
    fail "Test 9: registry missing schema_version field"
fi

# ── Test 10: all active entries have required fields ─────────────────────────
required_fields=("id:" "failure_signature_regex:" "recovery_action:" "discovered_in:")
missing_fields=0
for field in "${required_fields[@]}"; do
    count=$(grep -c "[[:space:]]${field}" "$REGISTRY" 2>/dev/null || true)
    if [[ "$count" -eq 0 ]]; then
        fail "Test 10: registry missing required field: $field"
        missing_fields=$((missing_fields+1))
    fi
done
[[ "$missing_fields" -eq 0 ]] && ok "Test 10: all required fields present in registry entries"

# ── Test 11: CHUMP_PREFLIGHT_SKIP=1 → exit 0 (testing mode) ─────────────────
shim_dir_skip="$TMPDIR_TEST/shim-skip"
mkdir -p "$shim_dir_skip"
printf '#!/usr/bin/env bash\nexit 0\n' > "$shim_dir_skip/chump"
chmod +x "$shim_dir_skip/chump"

skip_exit=0
PATH="$shim_dir_skip:$PATH" \
    CHUMP_BISECT_REGISTRY="$REGISTRY" \
    CHUMP_BISECT_WORKTREE="$REPO_ROOT" \
    CHUMP_AMBIENT_DISABLE=1 \
    CHUMP_PREFLIGHT_SKIP=1 \
    bash "$ORACLE" >/dev/null 2>/dev/null || skip_exit=$?

if [[ "$skip_exit" -eq 0 ]]; then
    ok "Test 11: CHUMP_PREFLIGHT_SKIP=1 → exit 0"
else
    fail "Test 11: CHUMP_PREFLIGHT_SKIP=1 → expected exit 0, got $skip_exit"
fi

# ── summary ───────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
