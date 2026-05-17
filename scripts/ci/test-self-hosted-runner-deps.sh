#!/usr/bin/env bash
# test-self-hosted-runner-deps.sh — INFRA-1556
#
# Asserts that every chump runner plist on this machine declares a PATH that
# resolves: chump, cargo, jq, gh, git, python3, bash. Workflow steps under the
# self-hosted lane depend on every one of these.
#
# Why this gate exists: 2026-05-16 ACP migration shipped, fast-checks failed on
# M4 with exit 127 because `chump` wasn't on the runner's PATH (only system bins
# were). The runner plist's PATH is the *only* effective env those workflow
# steps see — $HOME shell config doesn't apply to launchd-bootstrapped processes.
#
# Scope: macOS only (launchd plists). On Linux/CI, skipped with exit 0.
#
# Usage:
#   scripts/ci/test-self-hosted-runner-deps.sh           # validate all chump runner plists
#   scripts/ci/test-self-hosted-runner-deps.sh --quiet   # exit code only, no output
#
# Exit 0 = all plists declare PATH that resolves every required CLI.
# Exit 1 = at least one plist has a PATH where required CLIs don't resolve.
# Exit 2 = no chump runner plists found (consider this an info, not failure,
#          since fleet members without runners are valid).

set -euo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

log() { [ "$QUIET" -eq 1 ] || echo "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# CI / Linux short-circuit
case "$(uname -s)" in
  Darwin) ;;
  *) log "skip: not macOS ($( uname -s ))"; exit 0 ;;
esac

REQUIRED_CLIS=(chump cargo jq gh git python3 bash)

shopt -s nullglob
PLISTS=( "$HOME/Library/LaunchAgents/com.chump.actions-runner"*.plist )
if [ "${#PLISTS[@]}" -eq 0 ]; then
  log "info: no chump runner plists at ~/Library/LaunchAgents/com.chump.actions-runner*.plist"
  log "info: this is OK if this machine isn't a runner host. Skipping."
  exit 0
fi

errors=0
for plist in "${PLISTS[@]}"; do
  log "--- $plist ---"
  # Extract the PATH string from the EnvironmentVariables block.
  # Format: <key>PATH</key>\n<string>VALUE</string>
  path_value=$(awk '
    /<key>PATH<\/key>/ { in_path=1; next }
    in_path && /<string>/ {
      sub(/.*<string>/, "");
      sub(/<\/string>.*/, "");
      print; exit
    }
  ' "$plist")

  if [ -z "$path_value" ]; then
    fail "$plist has no PATH key under EnvironmentVariables"
  fi

  log "  PATH=$path_value"

  # For each required CLI, simulate `command -v` under that PATH.
  # We can't actually exec under launchd's env here, but we can check each PATH
  # entry for the binary file. This matches what command -v does without $PATH
  # search caching.
  for cli in "${REQUIRED_CLIS[@]}"; do
    found=""
    IFS=':' read -ra DIRS <<< "$path_value"
    for d in "${DIRS[@]}"; do
      if [ -x "$d/$cli" ]; then
        found="$d/$cli"
        break
      fi
    done
    if [ -z "$found" ]; then
      log "  MISSING: $cli not found in PATH for this runner"
      errors=$((errors + 1))
    else
      log "  OK: $cli -> $found"
    fi
  done
done

if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors missing CLI(s) across ${#PLISTS[@]} plist(s). Run 'scripts/setup/install-self-hosted-runner.sh --upgrade' to patch." >&2
  exit 1
fi

log ""
log "OK: all ${#PLISTS[@]} chump runner plist(s) resolve all required CLIs (${REQUIRED_CLIS[*]})"
exit 0
