#!/usr/bin/env bash
# INFRA-2405: smoke test for `chump contract-scan`.
#
# Verifies:
#   1. Mismatch fixture: python writer writes {a, b}; Rust reader reads a + c (c missing)
#      → exit 1 + stderr mentions "c"
#   2. Aligned fixture: python writer writes {a, b}; Rust reader reads a + b
#      → exit 0
#
# CRITICAL: no `printf '%s' "$x" | grep -q PATTERN` (INFRA-critical pipefail gate).
# Use assign-then-check pattern throughout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Locate the chump binary
CHUMP_BIN="${REPO_ROOT}/target/debug/chump"
if [[ ! -x "${CHUMP_BIN}" ]]; then
    echo "[test-contract-scan] building chump binary..."
    cd "${REPO_ROOT}"
    PATH="$HOME/.cargo/bin:$PATH" cargo build --bin chump 2>&1 | tail -5
fi

PASS=0
FAIL=0

# ─── fixture helpers ──────────────────────────────────────────────────────────

make_mismatch_fixture() {
    local dir="$1"
    mkdir -p "${dir}/scripts" "${dir}/src"

    # Writer: python script writing via inline json.dumps({...}) to .chump/state.json
    cat > "${dir}/scripts/writer.py" <<'PYEOF'
import json, os
os.makedirs(".chump", exist_ok=True)
with open(".chump/state.json", "w") as f:
    f.write(json.dumps({"a": 1, "b": 2}))
PYEOF

    # Reader: Rust file reading keys "a" and "c" (c is missing from writer)
    cat > "${dir}/src/reader.rs" <<'RSEOF'
fn read_state(raw: &str) -> (String, String) {
    let a = extract_json_string(raw, "a");
    let c = extract_json_string(raw, "c");
    (a, c)
}
RSEOF

    # Need a Cargo.toml with [workspace] so repo_root() finds this fixture dir
    cat > "${dir}/Cargo.toml" <<'TOMLEOF'
[workspace]
members = []
TOMLEOF
}

make_aligned_fixture() {
    local dir="$1"
    mkdir -p "${dir}/scripts" "${dir}/src"

    # Writer: python script writing via inline json.dumps({...}) to .chump/state.json
    cat > "${dir}/scripts/writer.py" <<'PYEOF'
import json, os
os.makedirs(".chump", exist_ok=True)
with open(".chump/state.json", "w") as f:
    f.write(json.dumps({"a": 1, "b": 2}))
PYEOF

    # Reader: Rust file reading keys "a" and "b" (both present in writer)
    cat > "${dir}/src/reader.rs" <<'RSEOF'
fn read_state(raw: &str) -> (String, String) {
    let a = extract_json_string(raw, "a");
    let b = extract_json_string(raw, "b");
    (a, b)
}
RSEOF

    cat > "${dir}/Cargo.toml" <<'TOMLEOF'
[workspace]
members = []
TOMLEOF
}

check() {
    local label="$1"
    local expected_exit="$2"
    local actual_exit="$3"
    local stderr_content="$4"
    local expected_stderr_substr="$5"

    local exit_ok=0
    local stderr_ok=0

    if [[ "${actual_exit}" -eq "${expected_exit}" ]]; then
        exit_ok=1
    fi

    if [[ -n "${expected_stderr_substr}" ]]; then
        # Assign-then-check: no pipe into grep
        local match
        match=$(printf '%s' "${stderr_content}" | grep -c "${expected_stderr_substr}" 2>/dev/null || true)
        if [[ "${match}" -gt 0 ]]; then
            stderr_ok=1
        fi
    else
        stderr_ok=1
    fi

    if [[ "${exit_ok}" -eq 1 && "${stderr_ok}" -eq 1 ]]; then
        echo "[PASS] ${label}"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] ${label}"
        if [[ "${exit_ok}" -eq 0 ]]; then
            echo "       expected exit=${expected_exit}, got exit=${actual_exit}"
        fi
        if [[ "${stderr_ok}" -eq 0 ]]; then
            echo "       expected stderr to contain '${expected_stderr_substr}'"
            echo "       actual stderr: ${stderr_content}"
        fi
        FAIL=$((FAIL + 1))
    fi
}

# ─── test 1: mismatch fixture → exit 1, stderr mentions missing key "c" ──────

FIXTURE_MISMATCH="$(mktemp -d)"
make_mismatch_fixture "${FIXTURE_MISMATCH}"

STDERR_FILE="$(mktemp)"
ACTUAL_EXIT=0
CHUMP_REPO_ROOT="${FIXTURE_MISMATCH}" "${CHUMP_BIN}" contract-scan --against "${FIXTURE_MISMATCH}" \
    > /dev/null 2>"${STDERR_FILE}" || ACTUAL_EXIT=$?

STDERR_CONTENT="$(cat "${STDERR_FILE}")"
check "mismatch fixture: exit code 1" 1 "${ACTUAL_EXIT}" "" ""
check "mismatch fixture: stderr mentions missing key 'c'" 1 "${ACTUAL_EXIT}" "${STDERR_CONTENT}" "c"

rm -rf "${FIXTURE_MISMATCH}" "${STDERR_FILE}"

# ─── test 2: aligned fixture → exit 0 ────────────────────────────────────────

FIXTURE_ALIGNED="$(mktemp -d)"
make_aligned_fixture "${FIXTURE_ALIGNED}"

STDERR_FILE2="$(mktemp)"
ACTUAL_EXIT2=0
CHUMP_REPO_ROOT="${FIXTURE_ALIGNED}" "${CHUMP_BIN}" contract-scan --against "${FIXTURE_ALIGNED}" \
    > /dev/null 2>"${STDERR_FILE2}" || ACTUAL_EXIT2=$?

check "aligned fixture: exit code 0" 0 "${ACTUAL_EXIT2}" "" ""

rm -rf "${FIXTURE_ALIGNED}" "${STDERR_FILE2}"

# ─── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "[test-contract-scan] results: ${PASS} passed, ${FAIL} failed"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
