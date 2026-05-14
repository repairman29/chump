#!/usr/bin/env bash
# INFRA-1045: claude harness — default, wraps 'claude -p' invocation.
# Zero behavior change for existing fleet: all watchdog/retry/token-parser
# machinery in worker.sh runs as before when CHUMP_AGENT_HARNESS=claude.
HARNESS_SPAWN_PROGRAM="claude"
HARNESS_SPAWN_MODE="claude-p"
HARNESS_GIT_EMAIL=""    # inherit repo default identity
HARNESS_GIT_NAME=""
