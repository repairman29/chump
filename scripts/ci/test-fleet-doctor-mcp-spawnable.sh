#!/usr/bin/env bash
# test-fleet-doctor-mcp-spawnable.sh — RESILIENT-1605
# fleet-doctor check_mcp_servers_spawnable: RED on missing command or retired host IP.
set -uo pipefail
REPO_ROOT_REAL="$(git rev-parse --show-toplevel)"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export FLEET_DOCTOR_SOURCED=1
# shellcheck disable=SC1090
source "$REPO_ROOT_REAL/scripts/coord/fleet-doctor-strict.sh"
last_status() { printf '%s' "${STATUSES[-1]:-}"; }
last_detail() { printf '%s' "${DETAILS[-1]:-}"; }

printf '#!/bin/sh\nexit 0\n' > "$T/ok-mcp"; chmod +x "$T/ok-mcp"

cat > "$T/good.json" <<J
{"mcpServers":{"almanac":{"command":"$T/ok-mcp","env":{"ALMANAC_EMBED_URL":"http://closetjunky:11434"},"enabled":true}}}
J
CHUMP_MCP_CONFIG="$T/good.json" check_mcp_servers_spawnable
[[ "$(last_status)" == pass ]] || fail "good config should pass: $(last_detail)"
pass "spawnable server passes"

cat > "$T/missing.json" <<J
{"mcpServers":{"almanac":{"command":"\$HOME/nonexistent/almanac-mcp","enabled":true}}}
J
CHUMP_MCP_CONFIG="$T/missing.json" check_mcp_servers_spawnable
[[ "$(last_status)" == fail && "$(last_detail)" == *"command not found"* ]] || fail "missing command should fail: $(last_detail)"
pass "missing command is RED"

cat > "$T/ip.json" <<J
{"mcpServers":{"almanac":{"command":"$T/ok-mcp","env":{"ALMANAC_EMBED_URL":"http://100.101.188.30:11434"},"enabled":true}}}
J
CHUMP_MCP_CONFIG="$T/ip.json" check_mcp_servers_spawnable
[[ "$(last_status)" == fail && "$(last_detail)" == *100.101.188.30* ]] || fail "retired IP should fail: $(last_detail)"
pass "retired helsinki IP is RED"

cat > "$T/off.json" <<J
{"mcpServers":{"almanac":{"command":"/nope","enabled":false}}}
J
CHUMP_MCP_CONFIG="$T/off.json" check_mcp_servers_spawnable
[[ "$(last_status)" == pass ]] || fail "disabled server should be ignored"
pass "disabled server ignored"
