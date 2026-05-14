#!/usr/bin/env bash
# INFRA-1045: manual harness — prints the briefing prompt to stdout, then
# waits for $CHUMP_MANUAL_RESULT file (default /tmp/chump-manual-<GAP_ID>.result).
# Useful for operator-driven loops: the fleet picks + claims the gap, prints
# what it would tell an AI, and waits for a human to ship via their own tool.
HARNESS_SPAWN_PROGRAM=""
HARNESS_SPAWN_MODE="manual-result-file"
HARNESS_GIT_EMAIL=""    # inherit repo default identity
HARNESS_GIT_NAME=""
