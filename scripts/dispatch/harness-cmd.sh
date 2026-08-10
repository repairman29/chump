#!/usr/bin/env bash
# harness-cmd.sh — EFFECTIVE-323
#
# Canonical construction of the non-claude harness spawn command. Extracted
# from worker.sh's inline dispatch so the exact argv a worker would run is
# unit-testable (scripts/ci/test-opencode-harness-smoke.sh) instead of only
# discovered in production. Tonight's chain of unexercised-path bugs — $_TO
# unbound, missing `opencode run` subcommand — were both in this command and
# both invisible until a live opencode worker crashed on them. This is the
# single source of truth; test it and the fleet inherits a wired harness.
#
# Contract (all read from the environment, same as worker.sh):
#   HARNESS_SPAWN_MODE     opencode-prompt | codex-prompt   (required)
#   HARNESS_SPAWN_PROGRAM  the CLI binary (opencode | codex)
#   TO                     timeout-command prefix, word-split intentionally
#                          (e.g. "timeout 1800s" | "gtimeout 1800s" | "")
#   _model_arg             bash array, e.g. (--model opencode-go/kimi-k2.7-code)
#   prompt                 the briefing prompt (single argv element)
#
# Output: populates the global array `_HARNESS_CMD` with the full argv.
# Returns 2 for an unknown mode (caller logs + fails the cycle).
#
# Runs under `set -u`: a missing input variable is a hard error here, on
# purpose — that is exactly the failure a test must catch before production.

build_harness_cmd() {
    case "${HARNESS_SPAWN_MODE}" in
        opencode-prompt)
            # opencode's headless CLI is `opencode run [message]`. The `run`
            # subcommand is load-bearing — without it opencode reads the prompt
            # as a filepath and dies ENAMETOOLONG (fixed 2026-07-27).
            # shellcheck disable=SC2206  # $TO must word-split into argv
            _HARNESS_CMD=( $TO "${HARNESS_SPAWN_PROGRAM:-opencode}" run "${_model_arg[@]}" "$prompt" )
            ;;
        codex-prompt)
            # shellcheck disable=SC2206  # $TO must word-split into argv
            _HARNESS_CMD=( $TO "${HARNESS_SPAWN_PROGRAM:-codex}" --approval-mode auto-edit "${_model_arg[@]}" "$prompt" )
            ;;
        *)
            return 2
            ;;
    esac
}

# hard_rules_doc_name — RESILIENT-259
#
# The worker prompt tells the agent where to find the full operating-rules
# text if it needs more than the inline briefing. That doc differs by
# harness: CLAUDE.md is explicitly the Claude-Code-only overlay (its own
# header says so) — non-Claude harnesses (opencode, codex) never read it and
# should be pointed at AGENTS.md, the canonical harness-agnostic doc, instead.
#
# Input: HARNESS_SPAWN_MODE (claude-p | opencode-prompt | codex-prompt | ...)
# Output: prints the doc basename to point the agent at.
hard_rules_doc_name() {
    case "${1:-${HARNESS_SPAWN_MODE:-claude-p}}" in
        claude-p)
            echo "CLAUDE.md"
            ;;
        *)
            echo "AGENTS.md"
            ;;
    esac
}
