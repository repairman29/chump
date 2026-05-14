#!/usr/bin/env bash
# INFRA-1045: codex harness — wraps OpenAI Codex CLI dispatch.
# Spawns via 'codex --approval-mode auto-edit' with the inline briefing prompt.
HARNESS_SPAWN_PROGRAM="codex"
HARNESS_SPAWN_MODE="codex-prompt"
HARNESS_GIT_EMAIL="codex@chump.bot"
HARNESS_GIT_NAME="codex-agent"
