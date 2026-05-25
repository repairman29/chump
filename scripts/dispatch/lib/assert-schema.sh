#!/usr/bin/env bash
# scripts/dispatch/lib/assert-schema.sh — INFRA-1978 (H9 critique fix)
#
# Shared helper: assert that a JSON blob carries the expected schema_version.
#
# Usage — source this file, then call the function:
#
#   source "$(dirname "$0")/lib/assert-schema.sh"
#   assert_schema "$some_json" 1
#
# Function signature:
#   assert_schema <json> <expected_version>
#
#   <json>             — the raw JSON string to inspect
#   <expected_version> — integer schema_version value the caller requires
#
# Exits non-zero with a clear stderr message on mismatch or missing field.
# Exits 0 on success (version matches).
#
# Why this exists:
#   INFRA-1548 added schema_version:1 to `chump --briefing` and `chump health`
#   JSON output so callers can detect breaking schema changes.  Without an
#   assertion at parse time, a schema bump to v2 would break every consumer
#   silently or crash in unpredictable spots.  This helper centralises the
#   check so each consumer adds a single line rather than reimplementing the
#   jq/python dance.
#
# Idempotent: safe to source multiple times.

# Guard against double-source.
if [[ "${_ASSERT_SCHEMA_LOADED:-0}" == "1" ]]; then
    return 0
fi
_ASSERT_SCHEMA_LOADED=1

# assert_schema <json> <expected_version>
#
# Parses .schema_version from the JSON, then fails clearly on mismatch.
# Requires either jq or python3 to be on PATH; jq is preferred.
assert_schema() {
    local json="$1"
    local expected="$2"

    if [[ -z "$json" ]]; then
        echo "[assert-schema] ERROR: empty JSON passed to assert_schema" >&2
        return 1
    fi

    local got
    if command -v jq >/dev/null 2>&1; then
        got=$(printf '%s' "$json" | jq -r '.schema_version // empty' 2>/dev/null || true)
    elif command -v python3 >/dev/null 2>&1; then
        got=$(printf '%s' "$json" \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['schema_version'])" \
            2>/dev/null || true)
    else
        echo "[assert-schema] ERROR: neither jq nor python3 found — cannot parse schema_version" >&2
        return 1
    fi

    if [[ -z "$got" ]]; then
        echo "[assert-schema] ERROR: schema_version field missing from JSON; consumer needs update" >&2
        echo "[assert-schema]        expected=${expected}" >&2
        echo "[assert-schema]        JSON preview: ${json:0:200}" >&2
        return 1
    fi

    if [[ "$got" != "$expected" ]]; then
        echo "[assert-schema] ERROR: schema mismatch: got=${got} expected=${expected}; consumer needs update" >&2
        return 1
    fi

    return 0
}
