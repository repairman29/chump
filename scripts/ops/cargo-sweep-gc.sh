#!/usr/bin/env bash
# scripts/ops/cargo-sweep-gc.sh — ZERO-WASTE-053
#
# Steady-state GC for the shared cargo target so chump runs for DAYS without a
# disk wedge. Uses `cargo-sweep --maxsize` (LRU eviction by access time) to hold
# the shared target under a hard cap, turning cargo's unbounded monotonic growth
# into a bounded plateau.
#
# Why this and not the existing reapers: the three mtime-based target-reapers
# froze 0 bytes under an active fleet (everything looked "hot"). cargo-sweep
# understands cargo's fingerprint structure and removes the OLDEST-ACCESSED
# artifacts first — so it is SAFE to run mid-build (it never evicts what a live
# build just touched). On this single-disk Mac (no volume to relocate onto), this
# bounding is the load-bearing days-and-days fix; the RESILIENT-273 self-heal is
# only the emergency backstop.
#
# Usage: cargo-sweep-gc.sh [--dry-run]
# Env:
#   CHUMP_REPO                 repo root (default /Users/jeffadkins/Projects/Chump)
#   CHUMP_CARGO_TARGET_CAP_MB  hard cap in MB (default 20000 = 20 GB)
#   CHUMP_CARGO_SWEEP_TIME_DAYS  age-based prune horizon in days (default 14; RESILIENT-239)
set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo $HOME/Projects/chump)}}"

# RESILIENT-323: the adaptive optimizer computes a disk-aware, growth-aware
# cap and writes it here via `:=`-style assignment, so an explicit caller env
# var still wins and an absent/stale budget file is a harmless no-op (we keep
# our own hardcoded defaults below either way).
CHUMP_STORAGE_BUDGET_FILE="${CHUMP_STORAGE_BUDGET_FILE:-${CHUMP_STATE_DIR:-$HOME/.chump}/storage-footprint-budget.env}"
[[ -f "$CHUMP_STORAGE_BUDGET_FILE" ]] && source "$CHUMP_STORAGE_BUDGET_FILE"

CAP_MB="${CHUMP_CARGO_TARGET_CAP_MB:-20000}"
TIME_DAYS="${CHUMP_CARGO_SWEEP_TIME_DAYS:-14}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY=""; [[ "${1:-}" == "--dry-run" ]] && DRY="--dry-run"

ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() { printf '{"ts":"%s",%s}\n' "$(ts)" "$1" >> "$AMB" 2>/dev/null || true; }
# Scanner anchors for the event-registry verify rule (emit() escapes quotes):
#   "kind":"cargo_sweep_gc_ran"
#   "kind":"cargo_sweep_gc_skipped"
#   "kind":"cargo_sweep_gc_errored"
#   "kind":"cargo_sweep_gc_time_pruned"

# ZERO-WASTE-054: locate the REAL cargo. On this host cargo is $HOME/bin/cargo;
# ~/.cargo/bin/cargo is only a symlink to the rustup shim, which resolves under
# launchd's minimal env but then fails `cargo metadata` (cargo-not-found) — so the
# GC silently no-op'd every 30 min while looking alive. Prepend the real dirs.
export PATH="$HOME/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "[cargo-sweep-gc] cargo not on PATH — cargo-sweep needs it for metadata; skipping" >&2
  emit "\"kind\":\"cargo_sweep_gc_skipped\",\"reason\":\"cargo-not-found\""
  exit 0
fi
if ! command -v cargo-sweep >/dev/null 2>&1; then
  echo "[cargo-sweep-gc] cargo-sweep not installed — skipping (install: cargo install cargo-sweep)" >&2
  emit "\"kind\":\"cargo_sweep_gc_skipped\",\"reason\":\"cargo-sweep-not-installed\""
  exit 0
fi
if [[ ! -f "$REPO_ROOT/Cargo.toml" ]]; then
  echo "[cargo-sweep-gc] no Cargo.toml at $REPO_ROOT — skipping" >&2
  emit "\"kind\":\"cargo_sweep_gc_skipped\",\"reason\":\"no-cargo-toml\",\"repo\":\"$REPO_ROOT\""
  exit 0
fi

# cargo-sweep resolves the target via `cargo metadata`, which honors the repo's
# .cargo/config target-dir (the shared target). So run it from the repo root.
out="$(cd "$REPO_ROOT" && cargo-sweep sweep --maxsize "$CAP_MB" $DRY . 2>&1)"
rc=$?

# ZERO-WASTE-054 HONEST SIGNAL: a GC that ERRORED must never report "nothing to
# clean" — that silent no-op is worse than no GC (the disk safety net looks alive
# while it's dead). Surface the real error and exit non-zero so launchd/observers
# see the failure.
if [[ $rc -ne 0 ]]; then
  err="$(printf '%s' "$out" | grep -iE 'error|failed|no such|not found' | head -2 | tr '\n' ' ')"
  echo "[cargo-sweep-gc] ERROR rc=$rc: ${err:-$out}" >&2
  emit "\"kind\":\"cargo_sweep_gc_errored\",\"cap_mb\":$CAP_MB,\"rc\":$rc,\"error\":\"$(printf '%s' "${err:-see-log}" | tr '"' "'" | cut -c1-200)\""
  exit "$rc"
fi

cleaned="$(printf '%s' "$out" | grep -oiE '(Would clean|Cleaned):? *[0-9.]+ *[KMG]i?B' | head -1)"
cleaned="${cleaned:-nothing to clean}"

echo "[cargo-sweep-gc] cap=${CAP_MB}MB $([ -n "$DRY" ] && echo dry-run || echo execute) -> ${cleaned} (rc=$rc)"
emit "\"kind\":\"cargo_sweep_gc_ran\",\"cap_mb\":$CAP_MB,\"dry_run\":$([ -n "$DRY" ] && echo true || echo false),\"result\":\"$(printf '%s' "$cleaned" | tr '"' "'")\",\"rc\":$rc"

# RESILIENT-239: age-based prune complements the maxsize LRU pass above. --maxsize
# only fires once the cap is hit; --time --recursive walks the fingerprint tree and
# drops anything untouched in $TIME_DAYS days regardless of total size, which is what
# actually bounds file COUNT (the 363k-file stat-walk tax) rather than just bytes.
# Non-fatal: a failure here doesn't invalidate the maxsize pass that already ran.
time_out="$(cd "$REPO_ROOT" && cargo-sweep sweep --time "$TIME_DAYS" --recursive $DRY . 2>&1)"
time_rc=$?
time_cleaned="$(printf '%s' "$time_out" | grep -oiE '(Would clean|Cleaned):? *[0-9.]+ *[KMG]i?B' | head -1)"
time_cleaned="${time_cleaned:-nothing to clean}"
echo "[cargo-sweep-gc] time-prune days=${TIME_DAYS} recursive $([ -n "$DRY" ] && echo dry-run || echo execute) -> ${time_cleaned} (rc=$time_rc)"
emit "\"kind\":\"cargo_sweep_gc_time_pruned\",\"time_days\":$TIME_DAYS,\"dry_run\":$([ -n "$DRY" ] && echo true || echo false),\"result\":\"$(printf '%s' "$time_cleaned" | tr '"' "'")\",\"rc\":$time_rc"

exit 0
