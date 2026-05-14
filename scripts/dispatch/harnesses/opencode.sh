#!/usr/bin/env bash
# INFRA-1045: opencode harness — wraps opencode-bigpickle dispatch.
# Spawns via the 'opencode' CLI with FLEET_MODEL model arg and the
# inline briefing prompt. Git identity is set to bigpickle@chump.bot
# to match the existing CREDIBLE-040 attribution convention from atomic_claim.
HARNESS_SPAWN_PROGRAM="opencode"
HARNESS_SPAWN_MODE="opencode-prompt"
HARNESS_GIT_EMAIL="bigpickle@chump.bot"
HARNESS_GIT_NAME="opencode-bigpickle"
