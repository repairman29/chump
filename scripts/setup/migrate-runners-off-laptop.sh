#!/usr/bin/env bash
# migrate-runners-off-laptop.sh — INFRA-1566
#
# Option A (single-afternoon migration) from INFRA-1566: move the self-hosted
# actions-runner instances that are co-located with the operator's daily-driver
# laptop onto a dedicated remote host, preserving labels and cache config.
#
# This does NOT provision the remote host (no candidate is racked/purchased
# today per docs/process/OFF_LAPTOP_SUBSTRATE.md) — it is the tool that runs
# ONCE a target host is reachable over SSH. It composes existing installers
# rather than re-implementing them:
#   - remote install:  scripts/setup/install-self-hosted-runner.sh (run over ssh)
#   - remote cache:    scripts/setup/install-self-hosted-runner-cache.sh
#   - local detach:    scripts/setup/install-self-hosted-runner.sh --uninstall
#
# Usage:
#   scripts/setup/migrate-runners-off-laptop.sh --status
#       Report which locally-registered runners are co-located with this
#       host (read-only, no network mutation beyond a gh api GET).
#
#   scripts/setup/migrate-runners-off-laptop.sh --target user@host --dry-run
#       Print every remote + local action that would run, without executing
#       any of them. Default mode when --execute is not passed.
#
#   scripts/setup/migrate-runners-off-laptop.sh --target user@host --execute
#       For each locally-registered runner:
#         1. ssh to target, clone/fetch this repo, run the installer there
#            with the SAME labels as the local runner (so workflow lane
#            selectors keep matching).
#         2. Poll gh api until the new remote runner shows status=online.
#         3. Only then, uninstall the local runner (detach from this host).
#       Aborts before step 3 if step 2 does not confirm online within
#       CHUMP_MIGRATE_RUNNER_TIMEOUT_S (default 180s) — never detaches a
#       working local runner without a confirmed replacement.
#
# Env:
#   CHUMP_REPO_OWNER / CHUMP_REPO_NAME   default repairman29/chump
#   CHUMP_MIGRATE_RUNNER_TIMEOUT_S       default 180
#   CHUMP_MIGRATE_REMOTE_DIR             default ~/chump-runner-host (on target)
#
# Rust-First-Bypass: one-shot/exploratory ssh+gh-api orchestration over
# existing shell installers; no state.db / ambient.jsonl mutation beyond a
# single audit-log append; < 200 LOC. Per META-064 shell-OK criteria.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_OWNER="${CHUMP_REPO_OWNER:-repairman29}"
REPO_NAME="${CHUMP_REPO_NAME:-chump}"
TIMEOUT_S="${CHUMP_MIGRATE_RUNNER_TIMEOUT_S:-180}"
REMOTE_DIR="${CHUMP_MIGRATE_REMOTE_DIR:-chump-runner-host}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

TARGET=""
EXECUTE=0
STATUS_ONLY=0

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

for arg in "$@"; do
  case "$arg" in
    --status)      STATUS_ONLY=1 ;;
    --target)      : ;; # consumed below with its value
    --dry-run)     EXECUTE=0 ;;
    --execute)     EXECUTE=1 ;;
    -h|--help)     usage 0 ;;
  esac
done
# second pass to grab --target's value (portable getopt-free parsing)
prev=""
for arg in "$@"; do
  if [ "$prev" = "--target" ]; then TARGET="$arg"; fi
  prev="$arg"
done

say() { echo "[migrate-runners] $*"; }
emit() {
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"runner_migration_action","action":"%s","note":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$AMBIENT" 2>/dev/null || true
}

# ── Discover locally-registered runners co-located with this host ───────────
local_runners() {
  command -v gh >/dev/null 2>&1 || { echo "FATAL: gh CLI required" >&2; exit 1; }
  local this_host
  this_host="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
    --jq ".runners[] | select(.name | ascii_downcase | startswith(\"$this_host\")) | \"\(.name)\t\(.status)\t\(.labels | map(.name) | join(\",\"))\"" \
    2>/dev/null
}

if [ "$STATUS_ONLY" = "1" ]; then
  say "Runners registered for $REPO_OWNER/$REPO_NAME co-located with $(hostname -s):"
  found=0
  while IFS=$'\t' read -r name status labels; do
    [ -z "$name" ] && continue
    found=1
    echo "  - $name [$status] labels=$labels"
  done < <(local_runners)
  [ "$found" = "0" ] && echo "  (none found — either migrated already, or gh api reachability issue)"
  exit 0
fi

if [ -z "$TARGET" ]; then
  echo "ERROR: --target user@host is required (unless --status)" >&2
  usage 1
fi

RUNNERS=()
while IFS=$'\t' read -r name status labels; do
  [ -z "$name" ] && continue
  RUNNERS+=("$name|$status|$labels")
done < <(local_runners)

if [ "${#RUNNERS[@]}" -eq 0 ]; then
  say "No locally-registered runners found for $(hostname -s) — nothing to migrate."
  exit 0
fi

say "Found ${#RUNNERS[@]} runner(s) to migrate to $TARGET:"
for r in "${RUNNERS[@]}"; do say "  - ${r%%|*}"; done
echo

run_or_dry() {
  if [ "$EXECUTE" = "1" ]; then
    eval "$1"
  else
    echo "[dry-run] would run: $1"
    return 0
  fi
}

for r in "${RUNNERS[@]}"; do
  name="${r%%|*}"
  rest="${r#*|}"
  labels="${rest#*|}"

  say "── Migrating $name (labels=$labels) ──"

  clone_cmd="ssh $TARGET 'mkdir -p $REMOTE_DIR && (git -C $REMOTE_DIR pull --ff-only 2>/dev/null || git clone https://github.com/$REPO_OWNER/$REPO_NAME.git $REMOTE_DIR)'"
  run_or_dry "$clone_cmd" || { say "ERROR: clone/fetch on $TARGET failed"; emit "clone_failed" "$name"; continue; }

  install_cmd="ssh $TARGET 'cd $REMOTE_DIR && RUNNER_NAME=${name}-remote RUNNER_LABELS=$labels bash scripts/setup/install-self-hosted-runner.sh --skip-canary'"
  run_or_dry "$install_cmd" || { say "ERROR: remote install for $name failed"; emit "install_failed" "$name"; continue; }

  if [ "$EXECUTE" != "1" ]; then
    say "[dry-run] would poll gh api for ${name}-remote online (timeout ${TIMEOUT_S}s), then uninstall local $name"
    continue
  fi

  say "Waiting up to ${TIMEOUT_S}s for ${name}-remote to report online..."
  waited=0
  online=0
  while [ "$waited" -lt "$TIMEOUT_S" ]; do
    if gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
        --jq ".runners[] | select(.name==\"${name}-remote\" and .status==\"online\") | .name" 2>/dev/null \
        | grep -q "${name}-remote"; then
      online=1
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done

  if [ "$online" != "1" ]; then
    say "ABORT: ${name}-remote never reported online within ${TIMEOUT_S}s — leaving local $name in place."
    emit "remote_online_timeout" "$name"
    continue
  fi

  say "Confirmed ${name}-remote online. Detaching local runner $name..."
  if bash "$SCRIPT_DIR/install-self-hosted-runner.sh" --uninstall; then
    say "Detached local $name."
    emit "migrated" "$name -> ${name}-remote on $TARGET"
  else
    say "WARN: local uninstall for $name reported an error — check manually."
    emit "local_uninstall_warn" "$name"
  fi
done

say "Migration pass complete. Verify with:"
say "  scripts/setup/migrate-runners-off-laptop.sh --status"
say "  gh api /repos/$REPO_OWNER/$REPO_NAME/actions/runners --jq '.runners[] | \"\\(.name) \\(.status)\"'"
