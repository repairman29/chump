#!/usr/bin/env bash
# scratch.sh — Bash-callable interface to the A2A scratchpad (INFRA-1121).
#
# Wraps the file-backed chump_coord::scratchpad get/set/cas API so
# non-Rust harnesses (shell scripts, CI hooks) can read and write
# scratchpad seed keys without a Rust build step.
#
# Usage:
#   scripts/coord/scratch.sh get <key>
#   scripts/coord/scratch.sh set <key> <value-json>
#   scripts/coord/scratch.sh cas <key> <expected-json> <new-json>
#   scripts/coord/scratch.sh list
#
# Key/value format: JSON values (strings must be quoted, numbers bare).
#   scratch.sh set fleet.size 3
#   scratch.sh set pillar.focus '"EFFECTIVE"'
#   scratch.sh cas main.head.sha null '"abc123"'
#
# Environment:
#   CHUMP_SCRATCH_DIR  — override default .chump-locks/scratch/ directory
#
# Exit codes:
#   0  success (or key absent for `get`)
#   1  usage error / missing argument
#   2  key not in seed key list (unknown key)
#   3  CAS conflict (expected != actual)
#   4  I/O or JSON parse error
#
# Seed keys (v1):
#   main.head.sha               CAS-required  86400s
#   fleet.size                  LWW            300s
#   pillar.focus                LWW           3600s
#   last_known_good.chump_binary CAS-required 86400s
#   red_letter.last_ts          LWW          86400s
#   ci.flake_classification     CAS-required  3600s  (not prompt-injected)
#
# Related: docs/design/A2A_SCRATCHPAD_KEYS.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Resolve scratch directory (mirrors Rust scratch_dir() logic).
_scratch_dir() {
    if [[ -n "${CHUMP_SCRATCH_DIR:-}" ]]; then
        mkdir -p "${CHUMP_SCRATCH_DIR}"
        echo "${CHUMP_SCRATCH_DIR}"
        return
    fi
    local root
    root="$(git -C "${REPO_ROOT}" rev-parse --show-toplevel 2>/dev/null || echo "${REPO_ROOT}")"
    local dir="${root}/.chump-locks/scratch"
    mkdir -p "${dir}"
    echo "${dir}"
}

# Convert a scratchpad key to a filename stem (mirrors Rust key_to_filename).
_key_to_filename() {
    local key="$1"
    local step1="${key//./__dot__}"
    echo "${step1////__slash__}"
}

# Validate that key is a known seed key.
_validate_key() {
    local key="$1"
    case "${key}" in
        main.head.sha|fleet.size|pillar.focus|last_known_good.chump_binary|red_letter.last_ts|ci.flake_classification)
            return 0
            ;;
        *)
            echo "error: unknown scratchpad key '${key}'" >&2
            echo "known keys: main.head.sha fleet.size pillar.focus last_known_good.chump_binary red_letter.last_ts ci.flake_classification" >&2
            return 2
            ;;
    esac
}

# Returns 0 if a key is CAS-required, 1 otherwise.
_is_cas_required() {
    local key="$1"
    case "${key}" in
        main.head.sha|last_known_good.chump_binary|ci.flake_classification)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Check if an envelope is expired. Returns 0 if NOT expired, 1 if expired.
_not_expired() {
    local ttl_expires_at="$1"
    if [[ -z "${ttl_expires_at}" ]]; then
        return 0  # no TTL = never expires
    fi
    local now
    now="$(date -u +%s 2>/dev/null || python3 -c 'import time; print(int(time.time()))')"
    # Parse RFC3339 to epoch; GNU date and BSD date differ.
    local expires
    expires="$(date -d "${ttl_expires_at}" +%s 2>/dev/null \
              || python3 -c "from datetime import datetime; import calendar; print(calendar.timegm(datetime.fromisoformat('${ttl_expires_at}'.replace('Z','+00:00')).timetuple()))")"
    [[ "${now}" -lt "${expires}" ]]
}

cmd_get() {
    local key="$1"
    _validate_key "${key}" || exit 2
    local dir
    dir="$(_scratch_dir)"
    local stem
    stem="$(_key_to_filename "${key}")"
    local path="${dir}/${stem}.json"
    if [[ ! -f "${path}" ]]; then
        # Absent key — print nothing, exit 0 (mirrors Rust Ok(None))
        exit 0
    fi
    local ttl_expires_at value
    ttl_expires_at="$(python3 -c "import json,sys; d=json.load(open('${path}')); print(d.get('ttl_expires_at',''))")"
    if ! _not_expired "${ttl_expires_at}"; then
        # Expired — print nothing, exit 0
        exit 0
    fi
    value="$(python3 -c "import json,sys; d=json.load(open('${path}')); print(json.dumps(d['value']))")"
    printf '%s\n' "${value}"
}

cmd_set() {
    local key="$1" value="$2"
    _validate_key "${key}" || exit 2
    if _is_cas_required "${key}"; then
        echo "error: key '${key}' is CAS-required — use cas instead of set" >&2
        exit 3
    fi
    local dir
    dir="$(_scratch_dir)"
    local stem
    stem="$(_key_to_filename "${key}")"
    local path="${dir}/${stem}.json"
    local tmp="${dir}/.___tmp_${stem}.json"

    # Determine TTL based on key.
    local ttl_seconds
    case "${key}" in
        fleet.size)              ttl_seconds=300   ;;
        pillar.focus)            ttl_seconds=3600  ;;
        red_letter.last_ts)      ttl_seconds=86400 ;;
        *)                       ttl_seconds=86400 ;;
    esac

    local now ttl_expires_at
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ttl_expires_at="$(python3 -c "
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc)
exp = now + timedelta(seconds=${ttl_seconds})
print(exp.strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

    python3 - <<EOF
import json
envelope = {
    "key": "${key}",
    "value": json.loads('${value}'),
    "written_at": "${now}",
    "ttl_expires_at": "${ttl_expires_at}"
}
with open("${tmp}", "w") as f:
    json.dump(envelope, f, indent=2)
EOF
    mv "${tmp}" "${path}"
}

cmd_cas() {
    local key="$1" expected="$2" new="$3"
    _validate_key "${key}" || exit 2
    local dir
    dir="$(_scratch_dir)"
    local stem
    stem="$(_key_to_filename "${key}")"
    local path="${dir}/${stem}.json"
    local tmp="${dir}/.___tmp_${stem}.json"

    # Read current value (absent/expired → null).
    local current="null"
    if [[ -f "${path}" ]]; then
        local ttl_expires_at
        ttl_expires_at="$(python3 -c "import json; d=json.load(open('${path}')); print(d.get('ttl_expires_at',''))")"
        if _not_expired "${ttl_expires_at}"; then
            current="$(python3 -c "import json; d=json.load(open('${path}')); print(json.dumps(d['value']))")"
        fi
    fi

    # Compare current with expected (normalised JSON comparison).
    local match
    match="$(python3 -c "
import json, sys
try:
    cur = json.loads('${current}')
    exp = json.loads('${expected}')
    print('yes' if cur == exp else 'no')
except Exception as e:
    print('err:' + str(e), file=sys.stderr)
    sys.exit(4)
")"
    if [[ "${match}" != "yes" ]]; then
        echo "error: CAS conflict on '${key}': expected ${expected}, got ${current}" >&2
        exit 3
    fi

    # Determine TTL.
    local ttl_seconds
    case "${key}" in
        ci.flake_classification) ttl_seconds=3600  ;;
        *)                       ttl_seconds=86400 ;;
    esac

    local now ttl_expires_at
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ttl_expires_at="$(python3 -c "
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc)
exp = now + timedelta(seconds=${ttl_seconds})
print(exp.strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

    python3 - <<EOF
import json
envelope = {
    "key": "${key}",
    "value": json.loads('${new}'),
    "written_at": "${now}",
    "ttl_expires_at": "${ttl_expires_at}"
}
with open("${tmp}", "w") as f:
    json.dump(envelope, f, indent=2)
EOF
    mv "${tmp}" "${path}"
}

cmd_list() {
    local dir
    dir="$(_scratch_dir)"
    echo "Scratchpad keys (${dir}):"
    for key in main.head.sha fleet.size pillar.focus last_known_good.chump_binary red_letter.last_ts ci.flake_classification; do
        local stem
        stem="$(_key_to_filename "${key}")"
        local path="${dir}/${stem}.json"
        if [[ ! -f "${path}" ]]; then
            printf '  %-40s (absent)\n' "${key}"
            continue
        fi
        local value ttl_expires_at
        ttl_expires_at="$(python3 -c "import json; d=json.load(open('${path}')); print(d.get('ttl_expires_at',''))")"
        if ! _not_expired "${ttl_expires_at}"; then
            printf '  %-40s (expired)\n' "${key}"
            continue
        fi
        value="$(python3 -c "import json; d=json.load(open('${path}')); print(json.dumps(d['value']))")"
        printf '  %-40s = %s\n' "${key}" "${value}"
    done
}

# ── Main dispatch ──────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 get <key>" >&2
    echo "       $0 set <key> <value-json>" >&2
    echo "       $0 cas <key> <expected-json> <new-json>" >&2
    echo "       $0 list" >&2
    exit 1
fi

CMD="$1"
shift

case "${CMD}" in
    get)
        [[ $# -ge 1 ]] || { echo "Usage: $0 get <key>" >&2; exit 1; }
        cmd_get "$1"
        ;;
    set)
        [[ $# -ge 2 ]] || { echo "Usage: $0 set <key> <value-json>" >&2; exit 1; }
        cmd_set "$1" "$2"
        ;;
    cas)
        [[ $# -ge 3 ]] || { echo "Usage: $0 cas <key> <expected-json> <new-json>" >&2; exit 1; }
        cmd_cas "$1" "$2" "$3"
        ;;
    list)
        cmd_list
        ;;
    *)
        echo "error: unknown command '${CMD}'" >&2
        echo "Usage: $0 get|set|cas|list ..." >&2
        exit 1
        ;;
esac
