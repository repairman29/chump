#!/usr/bin/env bash
# chump-preflight.sh — INFRA-379 — heal a wedged chump binary before any
# coord-script CLI call.
#
# Source this from coord scripts that invoke `chump gap …`:
#
#     # near top of script, after `set -euo pipefail`:
#     # shellcheck source=../lib/chump-preflight.sh
#     source "$(dirname "${BASH_SOURCE[0]}")/../lib/chump-preflight.sh"
#
# Why: the macOS Sequoia syspolicyd / dynamic-linker wedge documented in
# INFRA-275 stalls every `chump gap …` call to *_dyld_start* — bot-merge.sh
# (and any other coord script) sits silently for 30+ minutes before the
# operator notices and runs the doctor by hand. Observed 3+ times in the
# 2026-05-02/03 sessions; each wedge ate 30 min of stalled bot-merge.
# chump-binary-unwedge.sh's probe path is ~50ms on healthy binaries (negligible),
# so always-running it as a coord-script preflight is a one-way performance
# win.
#
# Behavior:
#   - If chump-binary-unwedge.sh is missing, executable, or chump itself isn't on
#     PATH: silently no-op (don't break fresh clones / CI environments).
#   - If chump is wedged: the doctor heals it (3-5s) and prints to stderr
#     for visibility.
#   - If chump is healthy: probe takes ~50ms and stays silent
#     (CHUMP_DOCTOR_QUIET=1).
#
# INFRA-2422: CHUMP_PREFLIGHT_SKIP deleted. The binary-unwedge doctor
# runs unconditionally (it is best-effort and takes ~50ms on healthy binaries).

# Resolve the doctor relative to this lib script's location, regardless
# of where the sourcing script lives or what the caller's CWD is.
_chump_pf_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_chump_pf_doctor="$_chump_pf_dir/../dev/chump-binary-unwedge.sh"

# Skip if chump CLI not on PATH at all (e.g., fresh checkout, no build yet).
if ! command -v chump >/dev/null 2>&1; then
    unset _chump_pf_dir _chump_pf_doctor
    return 0 2>/dev/null || true
fi

# Skip if doctor not present / not executable (tooling out of sync).
if [ ! -x "$_chump_pf_doctor" ]; then
    unset _chump_pf_dir _chump_pf_doctor
    return 0 2>/dev/null || true
fi

# Run the doctor. CHUMP_DOCTOR_QUIET=1 keeps the happy path silent.
# Errors go to stderr but never abort the calling script — preflight is
# best-effort, never load-bearing.
CHUMP_DOCTOR_QUIET=1 "$_chump_pf_doctor" 2>/dev/null || true

unset _chump_pf_dir _chump_pf_doctor
