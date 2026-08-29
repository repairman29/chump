#!/usr/bin/env bash
# migrate-macos-runner-off-host.sh — INFRA-1566
#
# Migrates ONE existing com.chump.actions-runner* macOS ARM64 self-hosted
# runner off the current host (the operator daily-driver) onto a remote
# macOS ARM64 host reachable via SSH. Implements AC Option A: "detach
# runners from current host via gh api .../actions/runners/{id}, re-register
# on new host with same labels, preserve cache mount."
#
# Order of operations is REGISTER-THEN-REMOVE, not remove-then-register, so
# CI capacity never dips below today's count mid-migration:
#   1. Inventory the local runner (plist, labels, cache dir) — read-only.
#   2. Preflight the target host over SSH (git/gh/cargo present, disk headroom).
#   3. rsync the warm sccache/cargo-target cache dir to the target host
#      (skippable with --no-cache-sync; migration still works, just cold).
#   4. Register a NEW runner on the target host with the SAME labels
#      (scripts/setup/install-self-hosted-runner.sh does the actual install).
#   5. Once the new runner reports online, remove the OLD one from GitHub
#      (registration removal token, not a bare unregister) and bootout its
#      local launchd plist.
#
# Usage:
#   migrate-macos-runner-off-host.sh --check                       # local inventory only, no SSH, exit 0/1
#   migrate-macos-runner-off-host.sh --runner N --target-host H --dry-run
#   migrate-macos-runner-off-host.sh --runner N --target-host H    # do it
#
#   --runner N        Which com.chump.actions-runner suffix to migrate.
#                      N=1 means the bare "com.chump.actions-runner" (no
#                      suffix); N=2..4 means "com.chump.actions-runner-N".
#   --target-host H   SSH destination for the new host, e.g. user@mac-mini.local
#   --no-cache-sync   Skip step 3 (accept a cold first build on the new host)
#   --dry-run         Print every step; execute nothing remote or destructive
#   --check           Local-only inventory + readiness report; no SSH required
#
# Nothing here reads or transmits credentials. GH_TOKEN / registration
# tokens are fetched fresh via `gh api` (already-authenticated CLI) at
# migration time, never stored. SSH auth relies on the operator's existing
# `~/.ssh/` agent per CLAUDE.md → INFRA-AGENT-CREDS.
#
# Rust-First-Bypass: one-shot operator-invoked migration glue over
# gh/ssh/rsync/launchctl; no canonical state mutation (GitHub's runner
# registry and the target host's launchd are the only state touched, both
# external to state.db/.chump-locks); < 200 LOC. Per META-064 shell-OK
# criteria.

set -euo pipefail

REPO_OWNER="${CHUMP_REPO_OWNER:-repairman29}"
REPO_NAME="${CHUMP_REPO_NAME:-chump}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE_ROOT="${CHUMP_RUNNER_CACHE_ROOT:-$HOME/.cache/chump-runner}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

RUNNER_IDX=""
TARGET_HOST=""
DRY_RUN=0
CHECK_ONLY=0
SYNC_CACHE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --runner)        RUNNER_IDX="$2"; shift 2 ;;
    --target-host)   TARGET_HOST="$2"; shift 2 ;;
    --no-cache-sync) SYNC_CACHE=0; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --check)         CHECK_ONLY=1; shift ;;
    -h|--help)        sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 1 ;;
  esac
done

plist_name() {
  local idx="$1"
  if [ "$idx" = "1" ] || [ -z "$idx" ]; then
    echo "com.chump.actions-runner"
  else
    echo "com.chump.actions-runner-$idx"
  fi
}

runner_dir_name() {
  local idx="$1"
  if [ "$idx" = "1" ] || [ -z "$idx" ]; then
    echo "$HOME/actions-runner-chump"
  else
    echo "$HOME/actions-runner-chump$idx"
  fi
}

emit() {
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"runner_migration_attempt","runner":"%s","target_host":"%s","outcome":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$AMBIENT" 2>/dev/null || true
}

# ── --check: local-only inventory, no SSH ────────────────────────────
cmd_check() {
  echo "=== Local runner inventory (INFRA-1566) ==="
  local found=0
  for idx in 1 2 3 4; do
    local plist
    plist="$(plist_name "$idx")"
    if launchctl list 2>/dev/null | grep -q "$plist"; then
      found=$((found + 1))
      local dir
      dir="$(runner_dir_name "$idx")"
      local labels="(unknown — gh api needed)"
      if command -v gh >/dev/null 2>&1; then
        labels=$(gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
          --jq ".runners[] | select(.name==\"$(hostname -s | tr '[:upper:]' '[:lower:]')\") | .labels | map(.name) | join(\",\")" \
          2>/dev/null || echo "$labels")
      fi
      echo "  - $plist  dir=$dir  labels=$labels"
    fi
  done
  echo
  echo "Found $found runner(s) on this host."
  if [ -d "$CACHE_ROOT" ]; then
    echo "Cache dir present: $CACHE_ROOT ($(du -sh "$CACHE_ROOT" 2>/dev/null | cut -f1 || echo '?'))"
  else
    echo "No warm cache dir at $CACHE_ROOT — first CI run after migration will be cold either way."
  fi
  [ "$found" -gt 0 ]
}

if [ "$CHECK_ONLY" = "1" ]; then
  cmd_check
  exit $?
fi

[ -n "$RUNNER_IDX" ]  || { echo "ERROR: --runner N required (see --help)" >&2; exit 1; }
[ -n "$TARGET_HOST" ] || { echo "ERROR: --target-host H required (see --help)" >&2; exit 1; }

PLIST="$(plist_name "$RUNNER_IDX")"
RUNNER_DIR="$(runner_dir_name "$RUNNER_IDX")"

run() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] $*"
  else
    echo "+ $*"
    eval "$@"
  fi
}

echo "=== Migrating $PLIST -> $TARGET_HOST (INFRA-1566) ==="

# 1. Inventory + labels
if ! launchctl list 2>/dev/null | grep -q "$PLIST"; then
  echo "ERROR: $PLIST is not registered on this host." >&2
  exit 1
fi
LABELS=""
if command -v gh >/dev/null 2>&1; then
  LABELS=$(gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
    --jq ".runners[] | select(.name | test(\"$(hostname -s | tr '[:upper:]' '[:lower:]')\")) | .labels | map(.name) | join(\",\")" \
    2>/dev/null | head -1 || true)
fi
[ -n "$LABELS" ] || LABELS="self-hosted,macos-arm64,chump-fleet"
echo "Labels to preserve: $LABELS"

# 2. Preflight target host over SSH
echo
echo "-- Preflighting $TARGET_HOST --"
run "ssh -o ConnectTimeout=10 '$TARGET_HOST' 'command -v git && command -v gh && command -v cargo'" \
  || { echo "ERROR: target host missing git/gh/cargo — run scripts/setup/provision-chumpd-host.sh --check there first." >&2; exit 1; }

# 3. Sync warm cache (optional)
if [ "$SYNC_CACHE" = "1" ] && [ -d "$CACHE_ROOT" ]; then
  echo
  echo "-- Syncing warm cache ($CACHE_ROOT) to $TARGET_HOST --"
  run "rsync -az --info=progress2 '$CACHE_ROOT/' '$TARGET_HOST:$CACHE_ROOT/'"
else
  echo "Skipping cache sync (--no-cache-sync or no local cache present)."
fi

# 4. Register new runner on target host with same labels
echo
echo "-- Registering new runner on $TARGET_HOST (labels=$LABELS) --"
run "scp '$REPO_ROOT/scripts/setup/install-self-hosted-runner.sh' '$TARGET_HOST:/tmp/install-self-hosted-runner.sh'"
run "ssh '$TARGET_HOST' 'CHUMP_REPO_OWNER=$REPO_OWNER CHUMP_REPO_NAME=$REPO_NAME RUNNER_LABELS=\"$LABELS,migrated-from-laptop\" bash /tmp/install-self-hosted-runner.sh'"

# 5. Confirm new runner online, then detach the old one.
echo
echo "-- Confirming new runner is online before touching the old one --"
if [ "$DRY_RUN" != "1" ]; then
  ok=0
  for _ in 1 2 3 4 5 6; do
    online=$(gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
      --jq '.runners[] | select(.status=="online") | .name' 2>/dev/null | wc -l | tr -d ' ')
    [ "$online" -ge 1 ] && { ok=1; break; }
    sleep 10
  done
  if [ "$ok" != "1" ]; then
    echo "ERROR: no online runner detected after registration — NOT removing the old runner." >&2
    emit "$PLIST" "$TARGET_HOST" "new_runner_not_online"
    exit 1
  fi
fi

echo
echo "-- Detaching old runner ($PLIST) from this host --"
REMOVE_TOKEN=""
if command -v gh >/dev/null 2>&1; then
  REMOVE_TOKEN=$(gh api -X POST "/repos/$REPO_OWNER/$REPO_NAME/actions/runners/remove-token" \
    --jq '.token' 2>/dev/null || true)
fi
run "launchctl bootout 'gui/$UID' '$HOME/Library/LaunchAgents/$PLIST.plist' || true"
run "rm -f '$HOME/Library/LaunchAgents/$PLIST.plist'"
if [ -n "$REMOVE_TOKEN" ] && [ -x "$RUNNER_DIR/config.sh" ]; then
  run "(cd '$RUNNER_DIR' && ./config.sh remove --token '$REMOVE_TOKEN')"
fi
run "rm -rf '$RUNNER_DIR'"

emit "$PLIST" "$TARGET_HOST" "${DRY_RUN:+dry_run_ok}${DRY_RUN:-migrated}"
echo
echo "Migration complete (or previewed, if --dry-run). Verify with:"
echo "  scripts/setup/install-self-hosted-runner.sh --check"
