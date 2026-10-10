#!/usr/bin/env bash
# auto-adopt.sh — MISSION-125 (MISSION-105 slice): auto-discovery & auto-adopt
# for new capabilities.
#
# A watchdog emits `kind=discover` to ambient.jsonl whenever it notices a new
# capability is available to the node (a binary dropped in PATH, a new MCP
# server registered, a new tool manifest, etc.) but not yet usable, e.g.:
#   {"ts":"...","kind":"discover","capability":"foo-linter","required_tools":["foo-lint"]}
#
# This script is the OTHER half: it reads those discover events, fetches any
# required binaries/tools that aren't already on PATH (AC2), records the
# capability as adopted so the node's runtime can pick it up without a human
# in the loop (AC3), and logs "auto-consume adopted <capability>" plus an
# ambient kind=capability_auto_adopted event (AC4) so the fleet can see it
# happened.
#
# Usage:
#   auto-adopt.sh            # process all unprocessed discover events once
#   auto-adopt.sh --watch    # loop forever, polling every CHUMP_AUTOADOPT_POLL_S
#   (sourced with CHUMP_AUTOADOPT_LIB_ONLY=1) — exposes the pure helpers below
#   for unit tests, no side effects.
set -uo pipefail

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
REPO="${CHUMP_REPO_ROOT:-$HOME/Projects/chump}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO/.chump-locks/ambient.jsonl}"
REGISTRY="${CHUMP_AUTOADOPT_REGISTRY:-$STATE_DIR/auto-adopt-capabilities.jsonl}"
CURSOR="${CHUMP_AUTOADOPT_CURSOR:-$STATE_DIR/auto-adopt-cursor}"
# Optional fetcher command. Given a missing tool name as $1, it should install
# it (apt/brew/cargo/curl, whatever fits the node). Left unset, a missing tool
# is logged and the capability is still adopted (best-effort fetch, AC2) —
# a human-free fleet can't block capability rollout on one missing extra.
FETCHER="${CHUMP_AUTOADOPT_FETCHER:-}"
POLL_S="${CHUMP_AUTOADOPT_POLL_S:-30}"

log() { printf '[%s] auto-adopt: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# extract_field LINE KEY — pull a scalar string field "key":"value" out of a
# single-line JSON event. Pure; no I/O.
extract_field() {
  local line="$1" key="$2"
  printf '%s' "$line" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
    | sed -E "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"/\\1/"
}

# extract_tools LINE — pull "required_tools":["a","b"] into "a b". Pure.
extract_tools() {
  local line="$1" arr
  arr="$(printf '%s' "$line" | grep -o '"required_tools"[[:space:]]*:[[:space:]]*\[[^]]*\]')"
  [ -z "$arr" ] && return 0
  printf '%s' "$arr" | grep -o '"[^"]*"' | tail -n +2 | tr -d '"' | tr '\n' ' '
}

# already_adopted CAPABILITY — true if CAPABILITY is already in the registry.
already_adopted() {
  local capability="$1"
  [ -f "$REGISTRY" ] || return 1
  grep -q "\"capability\":\"$capability\"" "$REGISTRY" 2>/dev/null
}

# fetch_tool TOOL — AC2: make sure TOOL is available. Returns 0 if already
# present or successfully fetched, 1 if a fetch was needed but unavailable
# (non-fatal to the caller — logged, adoption continues best-effort).
fetch_tool() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "$FETCHER" ]; then
    log "fetching missing tool: $tool"
    "$FETCHER" "$tool"
    return $?
  fi
  log "no fetcher configured, could not fetch missing tool: $tool"
  return 1
}

# scanner-anchor: "kind":"capability_auto_adopted"
emit_ambient() {
  local capability="$1" tools="$2"
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || return 0
  printf '{"ts":"%s","kind":"capability_auto_adopted","capability":"%s","required_tools":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$capability" "$tools" \
    >> "$AMBIENT" 2>/dev/null || true
}

# adopt_capability CAPABILITY TOOLS — AC2+AC3+AC4: fetch required tools,
# record the capability as adopted (integrates it into the node's runtime —
# any other node tooling that wants to know "is X usable here" reads
# $REGISTRY), log + emit the adoption.
adopt_capability() {
  local capability="$1" tools="$2" tool
  for tool in $tools; do
    fetch_tool "$tool" || log "capability $capability: proceeding without $tool (best-effort)"
  done
  mkdir -p "$(dirname "$REGISTRY")" 2>/dev/null || true
  printf '{"capability":"%s","required_tools":"%s","adopted_at":"%s"}\n' \
    "$capability" "$tools" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$REGISTRY"
  emit_ambient "$capability" "$tools"
  log "auto-consume adopted $capability"
}

# process_events — AC1: read discover events from $AMBIENT past the saved
# cursor, adopt any not-yet-adopted capability, advance the cursor past what
# was read (even if $AMBIENT doesn't exist yet, so a later run starts clean).
process_events() {
  local total_lines=0 start=0 capability tools
  [ -f "$AMBIENT" ] && total_lines="$(wc -l < "$AMBIENT" | tr -d ' ')"
  [ -f "$CURSOR" ] && start="$(cat "$CURSOR" 2>/dev/null || echo 0)"
  case "$start" in (''|*[!0-9]*) start=0 ;; esac
  if [ "$total_lines" -gt "$start" ]; then
    while IFS= read -r line; do
      [ "$(extract_field "$line" kind)" = "discover" ] || continue
      capability="$(extract_field "$line" capability)"
      [ -z "$capability" ] && continue
      if already_adopted "$capability"; then
        continue
      fi
      tools="$(extract_tools "$line")"
      adopt_capability "$capability" "$tools"
    done < <(tail -n "+$((start + 1))" "$AMBIENT")
  fi
  mkdir -p "$(dirname "$CURSOR")" 2>/dev/null || true
  printf '%s' "$total_lines" > "$CURSOR"
}

# ── entrypoint ───────────────────────────────────────────────────────────────
if [[ -z "${CHUMP_AUTOADOPT_LIB_ONLY:-}" && "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  case "${1:-}" in
    --watch)
      log "watch mode, polling every ${POLL_S}s"
      while true; do
        process_events
        sleep "$POLL_S"
      done
      ;;
    *)
      process_events
      ;;
  esac
fi
