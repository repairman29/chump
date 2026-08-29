#!/usr/bin/env bash
# migrate-actions-runner-host.sh — INFRA-1566
#
# Migrates a self-hosted GitHub Actions runner from THIS host (typically the
# operator's daily-driver laptop) to a TARGET host reachable over SSH,
# preserving labels and the runner's work-directory cache.
#
# Problem: 4 macOS-ARM64 runners co-located with the operator's daily driver
# saturate all performance cores under concurrent cargo builds, degrading
# interactive work. This is Option A from INFRA-1566 — move the runner(s) to
# dedicated hardware instead of leaving the laptop as the CI substrate.
#
# What it does, per runner:
#   1. Looks up the runner's id/name/labels via `gh api .../actions/runners`
#      (source of truth is GitHub, not the local plist).
#   2. rsyncs the runner's `_work` cache directory to the target host so the
#      first post-migration build isn't a cold cargo build.
#   3. SSHes to the target host and runs install-self-hosted-runner.sh there
#      with matching RUNNER_NAME/RUNNER_LABELS (idempotent — safe to re-run).
#   4. Deregisters the runner on THIS host via
#      `gh api -X DELETE repos/.../actions/runners/{id}` and removes the
#      local launchd plist + runner directory.
#
# Usage:
#   scripts/setup/migrate-actions-runner-host.sh --target-host <ssh-alias> \
#     [--runner-name NAME] [--dry-run]
#
#   # Migrate every locally-registered chump runner to the same target host:
#   scripts/setup/migrate-actions-runner-host.sh --target-host mac-mini --all
#
# Required:
#   --target-host <ssh-alias>   SSH-reachable host (must have git/gh/cargo/claude
#                                already provisioned — see docs/process/OFF_LAPTOP_SUBSTRATE.md
#                                and scripts/setup/provision-chumpd-host.sh --check)
#
# One of:
#   --runner-name <name>        migrate a single runner by its registered name
#   --all                       migrate every com.chump.actions-runner*.plist on this host
#
# Options:
#   --dry-run                   print every action; touch nothing local, remote, or on GitHub
#   --keep-source                skip step 4 (deregister); leaves both copies registered
#                                (useful for a soak-test window before cutover)
#
# Rust-First-Bypass: one-shot host-migration wrapper around gh api + rsync + ssh;
#   no state.db/ambient.jsonl mutation beyond an audit log line; < 200 LOC of
#   novel logic. Per META-064 shell-OK criteria.

set -euo pipefail

REPO_OWNER="${CHUMP_REPO_OWNER:-repairman29}"
REPO_NAME="${CHUMP_REPO_NAME:-chump}"
REPO_ROOT="$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

TARGET_HOST=""
RUNNER_NAME_ARG=""
MIGRATE_ALL=0
DRY_RUN=0
KEEP_SOURCE=0

log()  { printf '[migrate-runner-host] %s\n' "$*"; }
warn() { printf '[migrate-runner-host] WARN: %s\n' "$*" >&2; }
die()  { printf '[migrate-runner-host] ERROR: %s\n' "$*" >&2; exit 1; }

emit_ambient() {
  local kind="$1" extra="${2:-}"
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"%s","target_host":"%s"%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$TARGET_HOST" "${extra:+,$extra}" \
    >> "$AMBIENT" 2>/dev/null || true
}

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//' | sed '$d'
  exit "${1:-0}"
}

run() {
  # Wrapper so --dry-run prints instead of executes.
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target-host) TARGET_HOST="${2:?--target-host requires a value}"; shift 2 ;;
    --runner-name) RUNNER_NAME_ARG="${2:?--runner-name requires a value}"; shift 2 ;;
    --all)         MIGRATE_ALL=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --keep-source) KEEP_SOURCE=1; shift ;;
    -h|--help)     usage 0 ;;
    *)             die "Unknown arg: $1 (see --help)" ;;
  esac
done

[ -n "$TARGET_HOST" ] || die "--target-host is required (see --help)"
[ "$MIGRATE_ALL" = "1" ] || [ -n "$RUNNER_NAME_ARG" ] || \
  die "one of --runner-name <name> or --all is required (see --help)"

command -v gh >/dev/null 2>&1 || die "gh CLI is required"
command -v ssh >/dev/null 2>&1 || die "ssh is required"

# ── Step 0: preflight target host reachability + toolchain ────────────────
log "checking target host reachability + toolchain ($TARGET_HOST)..."
if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] ssh $TARGET_HOST 'command -v git gh cargo'"
else
  ssh "$TARGET_HOST" 'command -v git >/dev/null && command -v gh >/dev/null && command -v cargo >/dev/null' \
    || die "target host $TARGET_HOST is missing git/gh/cargo — provision it first (see scripts/setup/provision-chumpd-host.sh --check)"
fi

# ── Step 1: resolve which runners to migrate ───────────────────────────────
declare -a RUNNER_NAMES=()
if [ "$MIGRATE_ALL" = "1" ]; then
  shopt -s nullglob
  for plist in "$HOME/Library/LaunchAgents/com.chump.actions-runner"*.plist; do
    dir=$(/usr/libexec/PlistBuddy -c "Print :WorkingDirectory" "$plist" 2>/dev/null || true)
    [ -n "$dir" ] || continue
    name=$(gh api "repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
      --jq ".runners[] | select(.name != null) | .name" 2>/dev/null | \
      while read -r n; do
        # Match by runner dir's saved .runner file if present.
        if [ -f "$dir/.runner" ] && grep -q "\"agentName\": \"$n\"" "$dir/.runner" 2>/dev/null; then
          echo "$n"
        fi
      done)
    [ -n "$name" ] && RUNNER_NAMES+=("$name")
  done
  [ "${#RUNNER_NAMES[@]}" -gt 0 ] || die "no local com.chump.actions-runner* plists resolved to a registered runner name"
else
  RUNNER_NAMES=("$RUNNER_NAME_ARG")
fi

log "runners to migrate: ${RUNNER_NAMES[*]}"

# ── Per-runner migration ────────────────────────────────────────────────────
for RUNNER_NAME in "${RUNNER_NAMES[@]}"; do
  log "── migrating runner: $RUNNER_NAME ──"

  runner_json=$(gh api "repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
    --jq ".runners[] | select(.name==\"$RUNNER_NAME\")")
  [ -n "$runner_json" ] || { warn "runner $RUNNER_NAME not found via gh api — skipping"; continue; }

  runner_id=$(echo "$runner_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  labels=$(echo "$runner_json" | python3 -c 'import json,sys; print(",".join(l["name"] for l in json.load(sys.stdin)["labels"]))')
  log "  id=$runner_id labels=$labels"

  local_dir="$HOME/actions-runner-chump"
  [ "$RUNNER_NAME" = "$(hostname -s | tr '[:upper:]' '[:lower:]')" ] || {
    # Multi-runner hosts append -N to the dir name; best-effort discovery.
    for d in "$HOME"/actions-runner-chump*; do
      [ -f "$d/.runner" ] && grep -q "\"agentName\": \"$RUNNER_NAME\"" "$d/.runner" 2>/dev/null && local_dir="$d" && break
    done
  }

  # Step 2: sync work-dir cache (best effort — a cold cache is not fatal).
  if [ -d "$local_dir/_work" ]; then
    log "  syncing cache $local_dir/_work -> $TARGET_HOST:actions-runner-chump-$RUNNER_NAME/_work"
    run rsync -az --delete "$local_dir/_work/" "$TARGET_HOST:actions-runner-chump-$RUNNER_NAME/_work/" \
      || warn "cache rsync failed for $RUNNER_NAME — target will do a cold build on first job"
  else
    warn "  no _work dir at $local_dir — skipping cache sync"
  fi

  # Step 3: install + register on target host with matching name/labels.
  log "  registering $RUNNER_NAME on $TARGET_HOST (labels=$labels)"
  run ssh "$TARGET_HOST" \
    "RUNNER_NAME='$RUNNER_NAME' RUNNER_LABELS='$labels' RUNNER_DIR=\"\$HOME/actions-runner-chump-$RUNNER_NAME\" \
       bash -s" < "$REPO_ROOT/scripts/setup/install-self-hosted-runner.sh"

  # Step 4: deregister on this host (unless --keep-source for a soak window).
  if [ "$KEEP_SOURCE" = "1" ]; then
    log "  --keep-source set: leaving $RUNNER_NAME registered on this host too"
  else
    log "  deregistering $RUNNER_NAME (id=$runner_id) from this host"
    run gh api -X DELETE "repos/$REPO_OWNER/$REPO_NAME/actions/runners/$runner_id"
    if [ -f "$HOME/Library/LaunchAgents/com.chump.actions-runner.plist" ] && [ "$local_dir" = "$HOME/actions-runner-chump" ]; then
      run launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/com.chump.actions-runner.plist" || true
      run rm -f "$HOME/Library/LaunchAgents/com.chump.actions-runner.plist"
    fi
    run rm -rf "$local_dir"
  fi

  emit_ambient "runner_host_migrated" "\"runner_name\":\"$RUNNER_NAME\",\"runner_id\":$runner_id,\"kept_source\":$([ "$KEEP_SOURCE" = "1" ] && echo true || echo false)"
  log "  done: $RUNNER_NAME"
done

echo
echo "Migration complete. Verify on target host:"
echo "  ssh $TARGET_HOST 'scripts/setup/install-self-hosted-runner.sh --check'"
echo "Or from here:"
echo "  scripts/setup/install-self-hosted-runner.sh --check"
