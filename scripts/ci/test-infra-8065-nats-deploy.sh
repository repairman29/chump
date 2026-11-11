#!/usr/bin/env bash
# INFRA-8065: nats-deploy.sh installs, de-pins the cap, verifies receipt, detects drift.
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/s/dispatch" "$T/d"
for f in dispatch/fleet_dispatch.py nats_bus_mcp.py nats_agents.py; do echo "# $f" > "$T/s/$f"; done
printf '[Service]\nEnvironment=DISPATCH_MAX_PER_DAY=4\n' > "$T/u.service"
run() { NATS_DEPLOY_SRC_DIR="$T/s" NATS_AGENTS_HOME="$T/d" NATS_DEPLOY_UNIT_FILE="$T/u.service" NATS_DEPLOY_NO_SYSTEMCTL=1 CHUMP_REPO_ROOT="$T" bash "$R/scripts/ops/nats-deploy.sh" "$@"; }
run >/dev/null
cmp "$T/s/nats_agents.py" "$T/d/nats_agents.py" || { echo FAIL install; exit 1; }
! grep -q DISPATCH_MAX_PER_DAY "$T/u.service" || { echo FAIL pin; exit 1; }
run --check >/dev/null || { echo FAIL check-clean; exit 1; }
echo x >> "$T/s/nats_bus_mcp.py"
! run --check >/dev/null 2>&1 || { echo FAIL drift-undetected; exit 1; }
echo "PASS test-infra-8065-nats-deploy"
