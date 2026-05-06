#!/usr/bin/env bash
# chump-doctor.sh — INFRA-275 — heal a wedged chump binary
#
# Symptom this fixes: every `chump gap …` invocation hangs (no output, no
# CPU). 30+ chump processes accumulate in `ps` showing state `UE`
# (uninterruptible exit). `git stash list` is fine; `sqlite3 .chump/state.db`
# direct queries work instantly. The hang is in `_dyld_start` — i.e. the
# Mach-O dynamic linker, BEFORE `main()` runs.
#
# Root cause (macOS Sequoia, observed 2026-05-02): `syspolicyd` (Gatekeeper /
# code-signing arbiter) gets a particular binary's *inode* into a wedged
# pending-decision state. Every subsequent launch of the same inode queues
# behind the wedged decision and never completes. Fresh inodes — via
# `cp` to a different path or `mv`-replacing the file — bypass the wedged
# entry entirely. The provenance xattr (`com.apple.provenance`) is the
# trigger but cannot be removed without root.
#
# What this script does (idempotent, safe to re-run):
#   1. Probes: does `chump --version` return within 5s? If yes, no fix needed.
#   2. If hung: locates the canonical binary at `~/.cargo/bin/chump`,
#      moves it aside as `chump.wedged-inode-<inode>`, and copies the
#      same content back through a fresh inode. Verifies the copy works.
#   3. Best-effort kills any state-`UE` chump zombies (mostly cosmetic;
#      kernel reaps them eventually but they pollute `ps`).
#
# What this does NOT do:
#   - Drain `syspolicyd`'s pending queue (requires `sudo kill syspolicyd`;
#     left to the operator if even the fresh inode hangs).
#   - Rebuild the binary. If the on-disk binary is itself broken, run
#     `cargo build --release --bin chump && cp target/release/chump
#     ~/.cargo/bin/chump` first.
#
# Bypass / overrides:
#   CHUMP_DOCTOR_FORCE=1   skip the probe and replace the inode unconditionally
#   CHUMP_DOCTOR_TIMEOUT=N override probe timeout in seconds (default 5)
#   CHUMP_DOCTOR_QUIET=1   suppress non-error output

set -euo pipefail

TIMEOUT="${CHUMP_DOCTOR_TIMEOUT:-5}"
QUIET="${CHUMP_DOCTOR_QUIET:-0}"
FORCE="${CHUMP_DOCTOR_FORCE:-0}"
PROBE_CASCADE=0
for arg in "$@"; do
  case "$arg" in
    --probe-cascade) PROBE_CASCADE=1 ;;
  esac
done

log() {
  [ "$QUIET" = "1" ] || printf 'chump-doctor: %s\n' "$*" >&2
}

err() {
  printf 'chump-doctor: ERROR: %s\n' "$*" >&2
}

# Locate the chump binary by following the typical PATH lookups.
locate_binary() {
  local resolved
  if resolved=$(command -v chump 2>/dev/null); then
    # Resolve symlinks to find the real inode owner.
    if [ -L "$resolved" ]; then
      resolved=$(readlink -f "$resolved" 2>/dev/null || readlink "$resolved")
    fi
    printf '%s' "$resolved"
    return 0
  fi
  return 1
}

probe() {
  local bin="$1"
  # We want a launch that exercises dyld but does the minimum useful work.
  # `--version` is fastest (INFRA-148); fall back to `gap list --status open`
  # if --version isn't supported by an old binary.
  if gtimeout "$TIMEOUT" "$bin" --version >/dev/null 2>&1; then
    return 0
  fi
  if gtimeout "$TIMEOUT" "$bin" gap list --status open --json >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

heal() {
  local bin="$1"
  local inode
  inode=$(stat -f '%i' "$bin" 2>/dev/null || echo unknown)
  local wedged="${bin}.wedged-inode-${inode}"

  log "binary at $bin (inode $inode) appears wedged at _dyld_start"
  log "moving aside as $wedged and replacing with fresh-inode copy"

  # Copy first, mv last — so we never have a window where chump is missing.
  local tmp
  tmp=$(mktemp -t chump-doctor-fresh-XXXXXX)
  cp "$bin" "$tmp"
  chmod +x "$tmp"

  # Atomic-ish replace: mv old aside, then mv fresh into place.
  if [ -e "$wedged" ]; then
    log "(prior wedge already archived at $wedged — overwriting)"
    rm -f "$wedged"
  fi
  mv "$bin" "$wedged"
  mv "$tmp" "$bin"
  log "replaced; new inode=$(stat -f '%i' "$bin" 2>/dev/null || echo ?)"
}

reap_zombies() {
  local zombies
  # grep exits 1 when no matches; || true prevents set -e from aborting (INFRA-585)
  zombies=$(ps -eo pid,state,command 2>/dev/null \
    | awk '$2 == "UE" || $2 == "UE+" { for (i = 3; i <= NF; i++) printf "%s ", $i; print $1 }' \
    | grep -E ' chump (gap|reserve|ship|set|preflight|import|dump)' \
    | awk '{print $NF}') || true
  if [ -z "$zombies" ]; then
    return 0
  fi
  local count
  count=$(printf '%s\n' "$zombies" | wc -l | tr -d ' ')
  log "best-effort kill on $count UE-state chump zombies"
  printf '%s\n' "$zombies" | xargs -r kill -9 2>/dev/null || true
}

probe_cascade() {
  # INFRA-352 (c): probe each enabled cascade slot with a 1-token request.
  # Reports per-slot: alive | rate-limited | auth-fail | unreachable |
  # billing-exhausted | unknown. Fast (~1s/slot, ~10s total for full stack).
  # Reads .env from repo root for CHUMP_PROVIDER_<N>_* env. Operator runs
  # this BEFORE launching a fleet to know if cascade is healthy.
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  local env_file="$repo_root/.env"

  if [ ! -f "$env_file" ]; then
    err "no .env at $env_file; cascade slots come from there"
    return 1
  fi

  log "probing cascade slots (1-token request per slot)…"

  # Source .env into a subshell so we don't leak vars; emit one line per slot.
  ( set -a; source "$env_file"; set +a
    local n status_table=""
    for n in $(seq 1 10); do
      local enabled_var="CHUMP_PROVIDER_${n}_ENABLED"
      local enabled="${!enabled_var:-0}"
      [ "$enabled" = "1" ] || continue

      local base_var="CHUMP_PROVIDER_${n}_BASE"
      local key_var="CHUMP_PROVIDER_${n}_KEY"
      local model_var="CHUMP_PROVIDER_${n}_MODEL"
      local name_var="CHUMP_PROVIDER_${n}_NAME"
      local base="${!base_var}"
      local key="${!key_var}"
      local model="${!model_var:-llama3-8b}"
      local name="${!name_var:-slot-${n}}"

      [ -z "$base" ] && continue

      # Send a 1-token completion request, capture HTTP status only.
      local payload
      payload=$(printf '{"model":"%s","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' "$model")
      local code
      code=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 5 \
        -H "Authorization: Bearer ${key}" \
        -H 'Content-Type: application/json' \
        -X POST "${base%/}/chat/completions" \
        -d "$payload" 2>/dev/null || echo "000")

      local status
      case "$code" in
        200|201) status="✅ alive" ;;
        401|403) status="🔒 auth-fail" ;;
        402)     status="💸 billing-exhausted" ;;
        429|413) status="⏱️  rate-limited" ;;
        404)     status="❓ model-not-found" ;;
        000)     status="🚫 unreachable (timeout/connection)" ;;
        5*)      status="⚠️  server-error (${code})" ;;
        *)       status="❔ unknown (${code})" ;;
      esac
      printf '  slot %d %s [%s] %s → %s\n' "$n" "$name" "$model" "$base" "$status"
    done
  )

  # Also probe the local OPENAI_API_BASE if set.
  ( set -a; source "$env_file"; set +a
    if [ -n "${OPENAI_API_BASE:-}" ]; then
      local code
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
        "${OPENAI_API_BASE%/}/models" 2>/dev/null || echo "000")
      local status
      case "$code" in
        200) status="✅ alive" ;;
        000) status="🚫 unreachable (timeout/connection)" ;;
        *)   status="❔ ${code}" ;;
      esac
      printf '  local OPENAI_API_BASE [%s] %s → %s\n' "${OPENAI_MODEL:-?}" "$OPENAI_API_BASE" "$status"
    fi
  )
}

main() {
  if [ "$PROBE_CASCADE" = "1" ]; then
    probe_cascade
    exit $?
  fi

  local bin
  if ! bin=$(locate_binary); then
    err "chump binary not on PATH; install it first (cargo build --release --bin chump && cp target/release/chump ~/.cargo/bin/)"
    exit 2
  fi

  if [ "$FORCE" != "1" ]; then
    if probe "$bin"; then
      log "$bin probe OK in <${TIMEOUT}s — no heal needed"
      reap_zombies
      exit 0
    fi
    log "$bin probe timed out (>${TIMEOUT}s) — proceeding to heal"
  else
    log "CHUMP_DOCTOR_FORCE=1 — skipping probe"
  fi

  heal "$bin"

  # Verify the fix worked.
  if probe "$bin"; then
    log "post-heal probe OK — chump is responsive again"
    reap_zombies
    exit 0
  fi

  err "post-heal probe still timing out"
  err "next steps to try (require operator action):"
  err "  1. sudo kill -TERM \$(pgrep syspolicyd)   # drain syspolicyd queue"
  err "  2. cargo build --release --bin chump && cp target/release/chump ~/.cargo/bin/  # rebuild"
  err "  3. reboot                                  # last resort; UE zombies need this anyway"
  exit 1
}

main "$@"
