#!/usr/bin/env bash
# flake-quarantine.sh — META-141 read library for test runners.
#
# Source this file before running tests to gain quarantine-aware helpers.
# No network calls. Reads only from the quarantined-flakes.json state file.
#
# Usage:
#   source scripts/coord/lib/flake-quarantine.sh
#
#   if is_flake_quarantined "$fingerprint"; then
#     record_flake_skip "$fingerprint" "$test_name"
#     continue   # skip this test
#   fi
#
# Environment:
#   CHUMP_FLAKE_QUARANTINE_FILE    path to quarantined-flakes.json
#                                   (default: .chump-locks/quarantined-flakes.json)
#   CHUMP_AMBIENT_LOG              path to ambient.jsonl
#                                   (default: .chump-locks/ambient.jsonl)
#   CHUMP_FLAKE_QUARANTINE=0       disable quarantine checks entirely

# Resolve repo root from this script's location or from git.
_flake_lib_repo_root() {
    if [[ -n "${REPO_ROOT:-}" ]]; then
        printf '%s' "$REPO_ROOT"
    elif git rev-parse --show-toplevel >/dev/null 2>&1; then
        git rev-parse --show-toplevel
    else
        pwd
    fi
}

_FLAKE_LIB_ROOT="$(_flake_lib_repo_root)"
_FLAKE_QUARANTINE_FILE="${CHUMP_FLAKE_QUARANTINE_FILE:-$_FLAKE_LIB_ROOT/.chump-locks/quarantined-flakes.json}"
_FLAKE_AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$_FLAKE_LIB_ROOT/.chump-locks/ambient.jsonl}"

# is_flake_quarantined <fingerprint>
# Returns 0 (true) if the fingerprint is in the quarantine list, 1 otherwise.
# Also returns 0 if CHUMP_FLAKE_QUARANTINE=0 is set (disabled = never quarantined).
is_flake_quarantined() {
    local fingerprint="$1"

    # Bypass: quarantine disabled
    if [[ "${CHUMP_FLAKE_QUARANTINE:-1}" == "0" ]]; then
        return 1
    fi

    # No quarantine file → nothing quarantined
    if [[ ! -f "$_FLAKE_QUARANTINE_FILE" ]]; then
        return 1
    fi

    # Check by fingerprint using python3 (preferred) or grep fallback
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$_FLAKE_QUARANTINE_FILE" "$fingerprint" <<'PYEOF'
import json, sys, datetime
path, fingerprint = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(1)
now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
for entry in data:
    if entry.get("fingerprint") == fingerprint:
        # Check not expired
        expires = entry.get("expires_at", "")
        if expires and expires > now:
            sys.exit(0)  # quarantined and not yet expired
sys.exit(1)
PYEOF
        return $?
    else
        # Grep fallback — less precise but works without python3
        if grep -q "\"fingerprint\":\"${fingerprint}\"" "$_FLAKE_QUARANTINE_FILE" 2>/dev/null; then
            return 0
        fi
        return 1
    fi
}

# is_test_path_quarantined <test_path>
# Returns 0 if the test path itself is quarantined (looks up by test_path field).
is_test_path_quarantined() {
    local test_path="$1"

    if [[ "${CHUMP_FLAKE_QUARANTINE:-1}" == "0" ]]; then
        return 1
    fi

    if [[ ! -f "$_FLAKE_QUARANTINE_FILE" ]]; then
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$_FLAKE_QUARANTINE_FILE" "$test_path" <<'PYEOF'
import json, sys, datetime
path, test_path = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(1)
now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
for entry in data:
    if entry.get("test_path") == test_path:
        expires = entry.get("expires_at", "")
        if expires and expires > now:
            sys.exit(0)
sys.exit(1)
PYEOF
        return $?
    else
        if grep -q "\"test_path\":\"${test_path}\"" "$_FLAKE_QUARANTINE_FILE" 2>/dev/null; then
            return 0
        fi
        return 1
    fi
}

# record_flake_skip <fingerprint> <test_name>
# Logs that a test was skipped due to quarantine. Emits kind=flake_skipped.
record_flake_skip() {
    local fingerprint="$1"
    local test_name="$2"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo "[flake-quarantine] SKIP $test_name (fingerprint=$fingerprint)"

    # Emit ambient event — scanner-anchor: "kind":"flake_skipped"
    local json_line
    json_line="$(printf '{"ts":"%s","kind":"flake_skipped","test_name":"%s","fingerprint":"%s"}' \
        "$ts" "$test_name" "$fingerprint")"

    mkdir -p "$(dirname "$_FLAKE_AMBIENT_LOG")"
    if command -v flock >/dev/null 2>&1; then
        ( flock -x 200; printf '%s\n' "$json_line" >> "$_FLAKE_AMBIENT_LOG" ) \
            200>"${_FLAKE_AMBIENT_LOG}.lock" 2>&1 \
            || printf '[WARN] %s flake-quarantine ambient write failed\n' "$ts" >&2
    else
        printf '%s\n' "$json_line" >> "$_FLAKE_AMBIENT_LOG" \
            || printf '[WARN] %s flake-quarantine ambient write failed\n' "$ts" >&2
    fi
}

# list_quarantined_tests
# Prints one test_path per line for currently active (non-expired) quarantines.
list_quarantined_tests() {
    if [[ ! -f "$_FLAKE_QUARANTINE_FILE" ]]; then
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$_FLAKE_QUARANTINE_FILE" <<'PYEOF'
import json, sys, datetime
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(0)
now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
for entry in data:
    expires = entry.get("expires_at", "")
    if expires and expires > now:
        print(entry.get("test_path", ""))
PYEOF
    fi
}
