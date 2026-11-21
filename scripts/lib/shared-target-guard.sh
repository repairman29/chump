#!/usr/bin/env bash
# scripts/lib/shared-target-guard.sh — RESILIENT-1647
# Guard + receipt helpers for every organ that deletes inside a cargo target dir
# (~/.cargo/chump-shared-target). Source it; it defines functions only.
#
#   shared_target_live_build <dir>   rc 0 if a live cargo/rustc/rustdoc/nextest
#                                    process has CARGO_TARGET_DIR == <dir>
#   shared_target_size_bytes <path>  apparent bytes (du -sk * 1024; 0 if absent)
#   shared_target_emit_evicted <organ> <target> <bytes> <path>...
#                                    one kind=shared_target_evicted ambient line

_stg_canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "${1%/}"; }

shared_target_live_build() {
  local want; want="$(_stg_canon "$1")"
  local pid comm env_dir
  if [[ -d /proc/self ]]; then
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
      [[ "$pid" == "$$" ]] && continue
      comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || continue
      case "$comm" in cargo|rustc|rustdoc|cargo-nextest|cargo-clippy|clippy-driver) ;; *) continue ;; esac
      env_dir="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CARGO_TARGET_DIR=//p' | head -1)"
      [[ -n "$env_dir" ]] || continue
      [[ "$(_stg_canon "$env_dir")" == "$want" ]] && return 0
    done
    return 1
  fi
  # No /proc (macOS): ps -E appends each process's environment to its command line.
  ps -Ao pid=,comm=,command= -E 2>/dev/null | awk -v want="$want" '
    $2 ~ /(^|\/)(cargo|rustc|rustdoc|cargo-nextest|clippy-driver)$/ &&
    index($0, "CARGO_TARGET_DIR=" want) { found=1 }
    END { exit found ? 0 : 1 }'
}

shared_target_size_bytes() {
  [[ -e "$1" ]] || { echo 0; return 0; }
  local kb; kb="$(du -sk "$1" 2>/dev/null | awk '{print $1+0; exit}')"
  echo $(( ${kb:-0} * 1024 ))
}

shared_target_emit_evicted() {
  local organ="$1" target="$2" bytes="$3"; shift 3
  local amb="${CHUMP_AMBIENT_LOG:-${CHUMP_REPO_ROOT:-${CHUMP_REPO:-${CHUMP_HOME:-$(pwd)}}}/.chump-locks/ambient.jsonl}"
  [[ -d "$(dirname "$amb")" ]] || return 0
  local paths="" p
  for p in "$@"; do paths="${paths:+$paths,}\"${p//\"/\'}\""; done
  # scanner-anchor: "kind":"shared_target_evicted"
  printf '{"ts":"%s","kind":"shared_target_evicted","organ":"%s","target":"%s","bytes":%s,"paths":[%s]}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$organ" "${target//\"/\'}" "${bytes:-0}" "$paths" >> "$amb" 2>/dev/null || true
}
