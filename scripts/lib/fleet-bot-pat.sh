#!/usr/bin/env bash
# fleet-bot-pat.sh — META-211 utility library
#
# Provides functions for retrieving the chump-fleet-bot PAT from macOS
# Keychain for use by daemons and coordination scripts.
#
# Usage in another script:
#   source "$(dirname "$0")/lib/fleet-bot-pat.sh"
#
#   PAT="$(get_fleet_bot_pat)" || exit 1
#   export GH_TOKEN="$PAT"
#   gh pr merge <number> --admin --squash

CHUMP_FLEET_BOT_KEYCHAIN_SERVICE="chump-fleet-bot-pat"

# get_fleet_bot_pat
#   Retrieves the chump-fleet-bot PAT from macOS Keychain.
#   Returns the PAT on stdout (starts with "ghp_").
#   Exits 1 if:
#     - Not on macOS or 'security' command not available
#     - Keychain entry not found
#     - Retrieval fails
#
#   The token is NOT logged or echoed to stderr. Debug output goes to stderr
#   only on error.
#
#   Example:
#     PAT="$(get_fleet_bot_pat)" || {
#       echo "Failed to get fleet-bot PAT" >&2
#       exit 1
#     }
#     export GH_TOKEN="$PAT"

get_fleet_bot_pat() {
  local pat

  # Verify we're on macOS with security command
  if ! command -v security &>/dev/null; then
    echo "[fleet-bot-pat] ERROR: 'security' command not found (macOS only)" >&2
    return 1
  fi

  # Retrieve from Keychain
  if ! pat="$(security find-generic-password -s "$CHUMP_FLEET_BOT_KEYCHAIN_SERVICE" -w 2>&1)"; then
    echo "[fleet-bot-pat] ERROR: Failed to retrieve PAT from Keychain service '$CHUMP_FLEET_BOT_KEYCHAIN_SERVICE'" >&2
    echo "[fleet-bot-pat] Hint: Run 'bash scripts/setup/chump-fleet-bot-setup.sh' to provision the PAT" >&2
    return 1
  fi

  # Validate token format (basic check)
  if [[ ! "$pat" =~ ^ghp_ ]]; then
    echo "[fleet-bot-pat] ERROR: Retrieved token doesn't start with 'ghp_' (invalid GitHub token)" >&2
    return 1
  fi

  # Return the token on stdout (caller captures it)
  echo "$pat"
  return 0
}

# get_fleet_bot_pat_or_fail
#   Convenience wrapper that exits the script on failure.
#   Use when you want to fail fast if the PAT is unavailable.
#
#   Example:
#     PAT="$(get_fleet_bot_pat_or_fail)"
#     # If we get here, PAT is valid
#
#   This is equivalent to:
#     PAT="$(get_fleet_bot_pat)" || exit 1

get_fleet_bot_pat_or_fail() {
  get_fleet_bot_pat || exit 1
}

# emit_fleet_bot_access_event
#   Emits an ambient event to track fleet-bot PAT access.
#   Useful for audit and observability.
#
#   Parameters:
#     $1 - operation (e.g., "admin_merge", "pr_check", "rebase")
#     $2 - context (e.g., PR number, gap ID, script name)
#
#   Example:
#     emit_fleet_bot_access_event "admin_merge" "PR-2847"
#
#   Emits to ambient.jsonl:
#     {
#       "ts": "2026-06-08T18:45:12Z",
#       "kind": "fleet_bot_pat_access",
#       "operation": "admin_merge",
#       "context": "PR-2847",
#       "source_script": "bot-merge.sh"
#     }

emit_fleet_bot_access_event() {
  local operation="${1:-unknown}"
  local context="${2:-}"
  local source_script="${0##*/}"
  local ts

  # Safely emit to ambient.jsonl if available
  if [[ -w ".chump-locks/ambient.jsonl" ]]; then
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"fleet_bot_pat_access","operation":"%s","context":"%s","source_script":"%s"}\n' \
      "$ts" "$operation" "$context" "$source_script" >> ".chump-locks/ambient.jsonl"
  fi
}
