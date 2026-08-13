#!/usr/bin/env bash
cd /root/Projects/chump
set -a; source /root/.chump/providers.env; set +a
export CHUMP_REPO=/root/Projects/chump
exec /usr/bin/python3 /root/Projects/chump/scripts/ops/discord-gateway.py
