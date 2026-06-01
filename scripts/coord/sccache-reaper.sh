#!/usr/bin/env bash
# scripts/coord/sccache-reaper.sh — INFRA-2303
#
# Checks ~/Library/Caches/Mozilla.sccache size. If >SCCACHE_CACHE_CAP_GB
# (default 10), stops sccache server, prunes oldest files by mtime until
# under cap, and emits kind=sccache_reaped to ambient.jsonl.
#
# sccache auto-restarts on next cargo invocation — no manual restart needed.
#
# Usage:
#   sccache-reaper.sh              # dry-run (default)
#   sccache-reaper.sh --execute    # actually delete
#   sccache-reaper.sh --cap-gb 5  # override cap (in GB)

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-${CHUMP_HOME:-/Users/jeffadkins/Projects/Chump}}"
SCCACHE_DIR="${SCCACHE_DIR:-$HOME/Library/Caches/Mozilla.sccache}"
SCCACHE_CACHE_CAP_GB="${SCCACHE_CACHE_CAP_GB:-10}"
DRY_RUN=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute)       DRY_RUN=0; shift ;;
    --cap-gb)        SCCACHE_CACHE_CAP_GB="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --help|-h)       sed -n '2,20p' "$0"; exit 0 ;;
    *)               echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

ok()   { printf '\033[0;32m✓\033[0m  %s\n' "$*"; }
warn() { printf '\033[0;33m⚠\033[0m  %s\n' "$*"; }
info() { printf '\033[0;36m→\033[0m  %s\n' "$*"; }

emit_ambient() {
  local payload="$1"
  if [[ -d "$REPO_ROOT/.chump-locks" ]]; then
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"ts":"%s",%s}\n' "$ts" "$payload" >> "$REPO_ROOT/.chump-locks/ambient.jsonl"
  fi
}

# ── Ensure sccache config cap is set (idempotent) ─────────────────────────
# Sets SCCACHE_CACHE_SIZE=10G in ~/.config/sccache/config so sccache self-prunes.
# Emits sccache_cap_drift if SCCACHE_CACHE_SIZE env var is set and conflicts.
SCCACHE_CONFIG_DIR="$HOME/.config/sccache"
SCCACHE_CONFIG_FILE="$SCCACHE_CONFIG_DIR/config"
DESIRED_CACHE_SIZE="${SCCACHE_CACHE_CAP_GB}G"

if [[ -n "${SCCACHE_CACHE_SIZE:-}" ]] && [[ "${SCCACHE_CACHE_SIZE}" != "$DESIRED_CACHE_SIZE" ]]; then
  warn "SCCACHE_CACHE_SIZE env var is '${SCCACHE_CACHE_SIZE}' but desired is '${DESIRED_CACHE_SIZE}'"
  emit_ambient "\"kind\":\"sccache_cap_drift\",\"env_var\":\"${SCCACHE_CACHE_SIZE}\",\"desired\":\"${DESIRED_CACHE_SIZE}\""
fi

if [[ ! -f "$SCCACHE_CONFIG_FILE" ]]; then
  mkdir -p "$SCCACHE_CONFIG_DIR"
  printf '[cache]\nsize = "%s"\n' "$DESIRED_CACHE_SIZE" > "$SCCACHE_CONFIG_FILE"
  ok "created sccache config: $SCCACHE_CONFIG_FILE (size=${DESIRED_CACHE_SIZE})"
elif ! grep -q "^size" "$SCCACHE_CONFIG_FILE" 2>/dev/null; then
  # Config exists but no size line — append it
  printf '\nsize = "%s"\n' "$DESIRED_CACHE_SIZE" >> "$SCCACHE_CONFIG_FILE"
  ok "appended size=${DESIRED_CACHE_SIZE} to existing $SCCACHE_CONFIG_FILE"
else
  ok "sccache config already has size entry — no change"
fi

# ── Check sccache dir exists ────────────────────────────────────────────────
if [[ ! -d "$SCCACHE_DIR" ]]; then
  ok "sccache dir $SCCACHE_DIR does not exist — nothing to reap"
  exit 0
fi

# ── Measure current size (du -sk returns KB) ───────────────────────────────
size_kb=$(du -sk "$SCCACHE_DIR" 2>/dev/null | awk '{print $1}')
size_gb=$(( size_kb / 1024 / 1024 ))
cap_kb=$(( SCCACHE_CACHE_CAP_GB * 1024 * 1024 ))

info "sccache dir: $SCCACHE_DIR"
info "current size: ${size_kb}KB (~${size_gb}GB), cap: ${SCCACHE_CACHE_CAP_GB}GB"

if [[ "$size_kb" -le "$cap_kb" ]]; then
  ok "sccache within cap (${size_kb}KB <= ${cap_kb}KB) — no reap needed"
  exit 0
fi

overage_kb=$(( size_kb - cap_kb ))
info "over cap by ${overage_kb}KB — will prune oldest files by mtime"

if [[ "$DRY_RUN" -eq 1 ]]; then
  warn "[DRY-RUN] would stop sccache server and prune ~${overage_kb}KB of oldest files"
  warn "[DRY-RUN] pass --execute to actually delete"
  exit 0
fi

# ── Stop sccache server (graceful, 30s timeout) ────────────────────────────
if command -v sccache >/dev/null 2>&1; then
  info "stopping sccache server (30s timeout)..."
  if ! timeout 30 sccache --stop-server 2>/dev/null; then
    warn "sccache --stop-server timed out or failed — continuing with deletion"
  else
    ok "sccache server stopped"
  fi
else
  warn "sccache not in PATH — skipping server stop"
fi

# ── Prune oldest files until under cap ────────────────────────────────────
# Sort all files by mtime (oldest first), delete until under cap.
bytes_freed_kb=0
remaining_kb="$size_kb"

while IFS= read -r -d '' fpath; do
  [[ -f "$fpath" ]] || continue
  fsize_kb=$(du -sk "$fpath" 2>/dev/null | awk '{print $1}')
  rm -f "$fpath" 2>/dev/null && {
    bytes_freed_kb=$(( bytes_freed_kb + fsize_kb ))
    remaining_kb=$(( remaining_kb - fsize_kb ))
  }
  if [[ "$remaining_kb" -le "$cap_kb" ]]; then
    break
  fi
done < <(find "$SCCACHE_DIR" -type f -print0 2>/dev/null | xargs -0 ls -tr 2>/dev/null | tr '\n' '\0')

# Remove empty directories left behind
find "$SCCACHE_DIR" -type d -empty -delete 2>/dev/null || true

bytes_freed_bytes=$(( bytes_freed_kb * 1024 ))
ok "sccache reap complete: freed ${bytes_freed_kb}KB (${bytes_freed_bytes} bytes)"
emit_ambient "\"kind\":\"sccache_reaped\",\"bytes_freed\":${bytes_freed_bytes},\"freed_kb\":${bytes_freed_kb},\"cap_gb\":${SCCACHE_CACHE_CAP_GB},\"dir\":\"${SCCACHE_DIR}\""

# ── Verify final size ──────────────────────────────────────────────────────
final_kb=$(du -sk "$SCCACHE_DIR" 2>/dev/null | awk '{print $1}')
final_gb=$(( final_kb / 1024 / 1024 ))
ok "sccache dir now ${final_kb}KB (~${final_gb}GB)"
