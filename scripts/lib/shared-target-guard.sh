#!/usr/bin/env bash
# scripts/lib/shared-target-guard.sh — RESILIENT-1647
# Shared helpers for every organ that deletes inside the shared cargo target
# (~/.cargo/chump-shared-target): a live-build check and an eviction receipt.

# st_live_build <target-dir>: 0 if a cargo/rustc/cargo-nextest/rustdoc process
# whose CARGO_TARGET_DIR resolves to <target-dir> is alive. Without /proc
# (macOS) it fails closed on any such process.
st_live_build() {
  local want="$1" want_real pid comm env_dir
  want_real="$(cd "$want" 2>/dev/null && pwd -P || echo "$want")"
  if [[ ! -d /proc/self ]]; then
    local n
    for n in cargo rustc cargo-nextest rustdoc; do pgrep -x "$n" >/dev/null 2>&1 && return 0; done
    return 1
  fi
  for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || continue
    case "$comm" in cargo|rustc|cargo-nextest|rustdoc) ;; *) continue ;; esac
    env_dir="$({ tr "\0" "\n" < "/proc/$pid/environ"; } 2>/dev/null | sed -n 's/^CARGO_TARGET_DIR=//p' | head -1)"
    [[ -n "$env_dir" ]] || continue
    [[ "$env_dir" == "$want" || "$(cd "$env_dir" 2>/dev/null && pwd -P || echo "$env_dir")" == "$want_real" ]] && return 0
  done
  return 1
}

# st_emit_evicted <actor> <paths> <bytes> [ambient-file]: one receipt per eviction.
st_emit_evicted() {
  local actor="$1" paths="$2" bytes="${3:-0}" amb="${4:-${CHUMP_AMBIENT_LOG:-${CHUMP_REPO_ROOT:-$(pwd)}/.chump-locks/ambient.jsonl}}"
  [[ -d "$(dirname "$amb")" ]] || return 0
  paths="${paths//\\/\\\\}"; paths="${paths//\"/\\\"}"
  # scanner-anchor: "kind":"shared_target_evicted"
  printf '{"ts":"%s","kind":"shared_target_evicted","actor":"%s","paths":"%s","bytes":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$actor" "$paths" "$bytes" >> "$amb" 2>/dev/null || true
}
