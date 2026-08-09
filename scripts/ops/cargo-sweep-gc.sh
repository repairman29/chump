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
set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-/Users/jeffadkins/Projects/Chump}"
CAP_MB="${CHUMP_CARGO_TARGET_CAP_MB:-20000}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY=""; [[ "${1:-}" == "--dry-run" ]] && DRY="--dry-run"

ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() { printf '{"ts":"%s",%s}\n' "$(ts)" "$1" >> "$AMB" 2>/dev/null || true; }
# Scanner anchors for the event-registry verify rule (emit() escapes quotes):
#   "kind":"cargo_sweep_gc_ran"
#   "kind":"cargo_sweep_gc_skipped"

export PATH="$HOME/.cargo/bin:$PATH"

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
cleaned="$(printf '%s' "$out" | grep -oiE '(Would clean|Cleaned):? *[0-9.]+ *[KMG]i?B' | head -1)"
cleaned="${cleaned:-nothing to clean}"

echo "[cargo-sweep-gc] cap=${CAP_MB}MB $([ -n "$DRY" ] && echo dry-run || echo execute) -> ${cleaned} (rc=$rc)"
emit "\"kind\":\"cargo_sweep_gc_ran\",\"cap_mb\":$CAP_MB,\"dry_run\":$([ -n "$DRY" ] && echo true || echo false),\"result\":\"$(printf '%s' "$cleaned" | tr '"' "'")\",\"rc\":$rc"
exit 0
