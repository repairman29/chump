#!/usr/bin/env bash
# test-fleet-doctor-mcp-spawnable.sh — RESILIENT-1605
# fleet-doctor must go RED when an enabled MCP server's command cannot spawn,
# and when the retired helsinki IP is baked into a server env.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export FLEET_DOCTOR_SOURCED=1
# shellcheck disable=SC1091
source "$ROOT/scripts/coord/fleet-doctor-strict.sh"

cat >"$T/ok.json" <<J
{"mcpServers":{"a":{"command":"sh","env":{},"enabled":true},"off":{"command":"/nonexistent/x","enabled":false}}}
J
CHUMP_MCP_CONFIG="$T/ok.json" check_mcp_servers_spawnable
[[ "${STATUSES[-1]}" == "pass" ]] || fail "healthy config should pass: ${DETAILS[-1]}"

cat >"$T/dead.json" <<J
{"mcpServers":{"almanac":{"command":"\$HOME/nope/almanac-mcp","env":{},"enabled":true}}}
J
CHUMP_MCP_CONFIG="$T/dead.json" check_mcp_servers_spawnable
[[ "${STATUSES[-1]}" == "fail" && "${DETAILS[-1]}" == *almanac* ]] || fail "missing binary should fail: ${STATUSES[-1]}"

cat >"$T/ip.json" <<J
{"mcpServers":{"a":{"command":"sh","env":{"ALMANAC_EMBED_URL":"http://100.101.188.30:11434"},"enabled":true}}}
J
CHUMP_MCP_CONFIG="$T/ip.json" check_mcp_servers_spawnable
[[ "${STATUSES[-1]}" == "fail" && "${DETAILS[-1]}" == *100.101.188.30* ]] || fail "retired IP should fail"
echo "PASS: test-fleet-doctor-mcp-spawnable"
