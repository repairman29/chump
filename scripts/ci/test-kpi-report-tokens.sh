#!/usr/bin/env bash
# INFRA-729: test kpi report --tokens-per-ship functionality
# Tests that the subcommand produces a valid structured table with:
# - PR #, gap_id, backend, model, calls, input_tk, output_tk, cache_tk, cost_USD
# - P50/P90/Max for overall and per-backend stats
# - Both text and JSON output formats

set -euo pipefail

# Get the main repo root, not the worktree
worktree_root="$(git rev-parse --show-toplevel)"
repo_root="$(cd "$worktree_root" && git rev-parse --git-common-dir | xargs dirname)"
[[ ! -f "$repo_root/Cargo.toml" ]] && repo_root="$worktree_root"
cd "$worktree_root"

# Create a temporary test directory with fixture ambient.jsonl
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/.chump-locks"

# Helper: write ambient event
write_event() {
    echo "$1" >> "$test_dir/.chump-locks/ambient.jsonl"
}

# Get a timestamp from 2 days ago (within 7-day window)
ts_2d_ago() {
    local ts=$(($(date +%s) - 2*86400))
    local d=$((ts / 86400))
    local j=$((d + 2440588))
    local f=$((j + 1401 + ((((4 * j + 274277) / 146097) * 3) / 4) - 38))
    local e=$((4 * f + 3))
    local g=$(((e % 1461) / 4))
    local h=$((5 * g + 2))
    local day=$(((h % 153) / 5 + 1))
    local month=$(((h / 153 + 2) % 12 + 1))
    local year=$((e / 1461 - 4716 + ((14 - month) / 12)))
    local hh=$(((ts % 86400) / 3600))
    local mm=$(((ts % 3600) / 60))
    local ss=$((ts % 60))
    printf "%04d-%02d-%02dT%02d:%02d:%02dZ" "$year" "$month" "$day" "$hh" "$mm" "$ss"
}

TS=$(ts_2d_ago)

# Write 5 shipped gaps with different token counts
write_event "{\"kind\":\"session_end\",\"ts\":\"$TS\",\"session_id\":\"s1\",\"gap_id\":\"INFRA-1\",\"outcome\":\"shipped\",\"elapsed_seconds\":60,\"input_tokens\":10000,\"output_tokens\":2000,\"cache_read_tokens\":500}"
write_event "{\"kind\":\"session_end\",\"ts\":\"$TS\",\"session_id\":\"s2\",\"gap_id\":\"INFRA-2\",\"outcome\":\"shipped\",\"elapsed_seconds\":60,\"input_tokens\":20000,\"output_tokens\":4000,\"cache_read_tokens\":1000}"
write_event "{\"kind\":\"session_end\",\"ts\":\"$TS\",\"session_id\":\"s3\",\"gap_id\":\"INFRA-3\",\"outcome\":\"shipped\",\"elapsed_seconds\":60,\"input_tokens\":30000,\"output_tokens\":6000,\"cache_read_tokens\":1500}"
write_event "{\"kind\":\"session_end\",\"ts\":\"$TS\",\"session_id\":\"s4\",\"gap_id\":\"INFRA-4\",\"outcome\":\"shipped\",\"elapsed_seconds\":60,\"input_tokens\":40000,\"output_tokens\":8000,\"cache_read_tokens\":2000}"
write_event "{\"kind\":\"session_end\",\"ts\":\"$TS\",\"session_id\":\"s5\",\"gap_id\":\"INFRA-5\",\"outcome\":\"shipped\",\"elapsed_seconds\":60,\"input_tokens\":50000,\"output_tokens\":10000,\"cache_read_tokens\":2500}"

# Also add a non-shipped gap to test filtering
write_event "{\"kind\":\"session_end\",\"ts\":\"$TS\",\"session_id\":\"s6\",\"gap_id\":\"INFRA-100\",\"outcome\":\"abandoned\",\"elapsed_seconds\":60,\"input_tokens\":5000,\"output_tokens\":1000,\"cache_read_tokens\":0}"

# Chump binary is in the shared target directory
chump_bin="$repo_root/target/debug/chump"
if [[ ! -f "$chump_bin" ]]; then
    echo "FAIL: chump binary not found at $chump_bin"
    exit 1
fi

# Test text output
echo "Testing text output..."
output=$(cd "$test_dir" && CHUMP_REPO="$test_dir" "$chump_bin" kpi report --tokens-per-ship 7)
if ! echo "$output" | grep -q "Per-Ship Details"; then
    echo "FAIL: text output missing 'Per-Ship Details' header"
    exit 1
fi
if ! echo "$output" | grep -q "gap_id"; then
    echo "FAIL: text output missing gap_id column"
    exit 1
fi
if ! echo "$output" | grep -q "INFRA-1"; then
    echo "FAIL: text output missing INFRA-1"
    exit 1
fi
if ! echo "$output" | grep -q "backend"; then
    echo "FAIL: text output missing backend column"
    exit 1
fi
if ! echo "$output" | grep -q "model"; then
    echo "FAIL: text output missing model column"
    exit 1
fi
if ! echo "$output" | grep -q "calls"; then
    echo "FAIL: text output missing calls column"
    exit 1
fi
if echo "$output" | grep -q "INFRA-100"; then
    echo "FAIL: text output should not include non-shipped gap INFRA-100"
    exit 1
fi
if ! echo "$output" | grep -q "Per-Backend Stats"; then
    echo "FAIL: text output missing 'Per-Backend Stats' section"
    exit 1
fi
if ! echo "$output" | grep -q "P50:\|P90:\|Max:"; then
    echo "FAIL: text output missing percentile stats"
    exit 1
fi

# Test JSON output
echo "Testing JSON output..."
json=$(cd "$test_dir" && CHUMP_REPO="$test_dir" "$chump_bin" kpi report --tokens-per-ship 7 --json)
if ! echo "$json" | grep -q '"ships"'; then
    echo "FAIL: JSON output missing 'ships' array"
    exit 1
fi
if ! echo "$json" | grep -q '"gap_id"'; then
    echo "FAIL: JSON output missing 'gap_id' field"
    exit 1
fi
if ! echo "$json" | grep -q '"backend"'; then
    echo "FAIL: JSON output missing 'backend' field"
    exit 1
fi
if ! echo "$json" | grep -q '"model"'; then
    echo "FAIL: JSON output missing 'model' field"
    exit 1
fi
if ! echo "$json" | grep -q '"calls"'; then
    echo "FAIL: JSON output missing 'calls' field"
    exit 1
fi
if ! echo "$json" | grep -q '"cost_usd"'; then
    echo "FAIL: JSON output missing 'cost_usd' field"
    exit 1
fi
if ! echo "$json" | grep -q '"shipped"'; then
    echo "FAIL: JSON output missing 'shipped' field"
    exit 1
fi
if ! echo "$json" | grep -q '"p50_tokens"'; then
    echo "FAIL: JSON output missing 'p50_tokens' field"
    exit 1
fi
if ! echo "$json" | grep -q '"p90_tokens"'; then
    echo "FAIL: JSON output missing 'p90_tokens' field"
    exit 1
fi

# Validate ship counts
ship_count=$(echo "$json" | grep -o '"ship_count":[0-9]*' | cut -d: -f2)
if [ "$ship_count" != "5" ]; then
    echo "FAIL: expected 5 shipped gaps, got $ship_count"
    exit 1
fi

# Validate that abandoned gap is not in ships
if echo "$json" | grep -q '"gap_id":"INFRA-100"'; then
    echo "FAIL: abandoned gap INFRA-100 should not be in ships"
    exit 1
fi

echo "✓ All kpi report tests passed"
exit 0
