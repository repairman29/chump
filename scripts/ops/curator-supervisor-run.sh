#!/usr/bin/env bash
# curator-supervisor-run.sh — RESILIENT-246
#
# Launchd entry point for the curator supervisor. Replaces the old plist that
# invoked the release binary DIRECTLY.
#
# WHY THIS SCRIPT EXISTS (the RESILIENT-246 root cause):
#
#   The old com.chump.curator-supervisor.plist put a build artifact in
#   ProgramArguments:
#       /Users/jeffadkins/Projects/Chump/target/release/chump-curator-supervisor
#
#   `target/release/` is disposable — cargo clean, the cargo-target-reaper, a
#   disk-pressure reap, or a branch switch can all remove it. When that binary
#   vanished (~2026-08-01) launchd could no longer spawn the job and reported
#   exit status 78 (EX_CONFIG) on every StartInterval.
#
#   The killer detail: launchd fails BEFORE the process exists, so it never
#   opens StandardOutPath or StandardErrorPath. Not one byte is written to
#   either log. The logs do not show an error — they simply STOP. There is no
#   alert, no stack trace, nothing to grep. Silence is the entire symptom.
#   That is why the curator was dead for twelve days and nothing noticed.
#
#   Reproduce it (verified 2026-08-09):
#       a plist whose ProgramArguments[0] does not exist yields
#       `-  78  com.chump.<label>` in `launchctl list`, with both log files
#       created but EMPTY.
#
# THE FIX, three parts:
#   1. The plist now invokes /bin/bash with THIS script as an argument —
#      exactly how dev.chump.reaper-watchdog is wired. /bin/bash always
#      exists and this script is version-controlled, so launchd can always
#      spawn the job. A missing supervisor binary becomes a LOUD, LOGGED,
#      ALERTing failure inside a running process instead of a silent
#      pre-spawn 78.
#   2. Every run stamps a heartbeat via the standard reaper instrumentation
#      (/tmp/chump-reaper-curator-supervisor.heartbeat), so the EXISTING
#      reaper-heartbeat-watchdog grades the curator with the same mechanism
#      it already uses for the reapers. No new watchdog was invented.
#   3. Every run writes .chump-locks/curator-supervisor-last-pass.json so
#      `fleet-brief` can print the last-curator-action age.
#
# Usage:
#   scripts/ops/curator-supervisor-run.sh            # one supervisor pass
#   CHUMP_CURATOR_SUPERVISOR_BIN=/path/to/bin  ...   # override binary
#
# Exit codes:
#   0  supervisor ran and exited 0
#   1  supervisor could not START (binary missing/not executable) — ALERTed
#   2  supervisor ran but exited non-zero — ALERTed

set -uo pipefail

# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"

reaper_setup curator-supervisor
reaper_check_disk_headroom  # INFRA-453: ALERT + exit 0 if <5% free

LOCK_DIR="$REAPER_LOCK_DIR"
AMBIENT="$LOCK_DIR/ambient.jsonl"
LAST_PASS="$LOCK_DIR/curator-supervisor-last-pass.json"
mkdir -p "$LOCK_DIR" 2>/dev/null || true

_json_str() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null \
        || printf '"%s"' "$(printf '%s' "$1" | tr -d '"\\')"
}

# write_last_pass STATUS EXIT_CODE DETAIL
# The `.chump-locks/curator-*` artifact that proves a pass happened. Written on
# EVERY outcome — success, cannot_start, and non-zero exit — because an
# artifact that only appears on success cannot distinguish "healthy" from
# "never ran", which is the exact ambiguity that hid this outage.
write_last_pass() {
    local status="$1" code="$2" detail="$3"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat > "$LAST_PASS" <<EOF 2>/dev/null || true
{"kind":"curator_supervisor_pass","status":"$status","exit_code":$code,"ts":"$ts","binary":$(_json_str "${BIN:-none}"),"detail":$(_json_str "$detail")}
EOF
}

# alert KIND MESSAGE — emit an ALERT into the ambient stream + stderr.
# Raw JSON append (no broadcast.sh dependency) mirrors reaper-heartbeat-watchdog.sh.
# The kind arrives as an argument, so the registry scanner needs explicit anchors:
# scanner-anchor: "kind":"curator_cannot_start"
# scanner-anchor: "kind":"curator_pass_failed"
# scanner-anchor: "kind":"curator_bin_disposable"
alert() {
    local kind="$1" msg="$2"
    printf 'ALERT [%s] %s\n' "$kind" "$msg" >&2
    printf '{"event":"ALERT","kind":"%s","reaper":"curator-supervisor","ts":"%s","reason":%s}\n' \
        "$kind" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(_json_str "$msg")" \
        >> "$AMBIENT" 2>/dev/null || true
}

# ── Resolve the supervisor binary ─────────────────────────────────────────
# Preference order matters: ~/.cargo/bin is STABLE (that is where the fleet's
# other six daemons live and nothing reaps it); target/release is disposable
# and is only a fallback so a dev box without an install still works.
BIN="${CHUMP_CURATOR_SUPERVISOR_BIN:-}"
if [[ -z "$BIN" ]]; then
    for _cand in \
        "$HOME/.cargo/bin/chump-curator-supervisor" \
        "$REAPER_REPO_ROOT/target/release/chump-curator-supervisor"
    do
        if [[ -x "$_cand" ]]; then BIN="$_cand"; break; fi
    done
fi

if [[ -z "$BIN" || ! -x "$BIN" ]]; then
    # AC5: a curator that CANNOT START is reported, never silently skipped.
    # Under the old plist this was launchd exit 78 with zero log output.
    msg="curator-supervisor cannot start — no executable found at \$CHUMP_CURATOR_SUPERVISOR_BIN, $HOME/.cargo/bin/chump-curator-supervisor, or $REAPER_REPO_ROOT/target/release/chump-curator-supervisor. This is the RESILIENT-246 exit-78 failure mode. Reinstall with: bash scripts/setup/install-curator-supervisor.sh"
    alert curator_cannot_start "$msg"
    write_last_pass cannot_start 1 "$msg"
    reaper_finish fail '{"cannot_start":1}'
    exit 1
fi

# Do not let a stale binary path silently persist: record which one we used.
printf '[curator-supervisor-run] using binary: %s\n' "$BIN"
if [[ "$BIN" == *"/target/release/"* ]]; then
    # Not fatal — but this is precisely the fragile configuration that caused
    # the twelve-day outage, so say so every run.
    alert curator_bin_disposable \
        "curator-supervisor is running from a disposable build path ($BIN). target/release is reaped by cargo-target-reaper / cargo clean; when it disappears launchd fails to spawn. Install to a stable path: bash scripts/setup/install-curator-supervisor.sh"
fi

# ── Run one supervisor pass ───────────────────────────────────────────────
START=$(date +%s)
set +e
"$BIN"
RC=$?
set -e
ELAPSED=$(( $(date +%s) - START ))

if [[ $RC -eq 0 ]]; then
    write_last_pass ok 0 "supervisor pass completed in ${ELAPSED}s"
    reaper_finish ok "{\"exit_code\":0,\"elapsed_secs\":$ELAPSED}"
    printf '[curator-supervisor-run] pass ok in %ds\n' "$ELAPSED"
    exit 0
fi

msg="curator-supervisor exited $RC after ${ELAPSED}s (binary: $BIN). Check ~/Library/Logs/Chump/curator-supervisor.err.log"
alert curator_pass_failed "$msg"
write_last_pass failed "$RC" "$msg"
reaper_finish fail "{\"exit_code\":$RC,\"elapsed_secs\":$ELAPSED}"
exit 2
