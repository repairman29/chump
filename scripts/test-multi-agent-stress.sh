#!/usr/bin/env bash
# test-multi-agent-stress.sh — INFRA-042 multi-agent stress harness.
#
# Spawns N concurrent processes, each acting as an independent agent racing
# to claim the SAME gap-id via the file-based lease path. Reports how many
# leases ended up holding the gap (>1 = race window observed).
#
# Hermetic: uses a tmp lockdir (CHUMP_LOCK_DIR) so it cannot interfere with
# live agents in this repo. No NATS is exercised — that is the COORD-NATS
# atomic-claim path; this harness covers the file-based fallback that 100%
# of agents exercise when chump-coord is not in PATH.
#
# Usage:
#   scripts/test-multi-agent-stress.sh [N=4]
#
# Exit codes:
#   0  — at least one agent claimed (no deadlock, no data loss)
#   1  — zero agents claimed (deadlock or all errored)
#   2  — usage error
#
# What this DOES NOT test:
#   - Real subprocess execution (cargo build, claude CLI dispatch)
#   - Cross-machine coordination (FLEET-006/007)
#   - Subtask posting/claiming across agents (acceptance #4)
# Those scopes are intentionally out of band — this is the minimum viable
# stress test for the lease primitive that all dispatchers depend on.

set -euo pipefail

N="${1:-4}"
if ! [[ "$N" =~ ^[0-9]+$ ]] || [[ "$N" -lt 2 ]]; then
    echo "Usage: $0 [N>=2]  (default 4)" >&2
    exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
TMPDIR_BASE="$(mktemp -d -t chump-stress-XXXXXX)"
LOCK_DIR="$TMPDIR_BASE/.chump-locks"
mkdir -p "$LOCK_DIR"

# Use a fictional gap-id reserved for this stress test so no real gap is touched.
GAP_ID="STRESS-$$"

cleanup() {
    rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

printf '[stress] N=%d agents racing on %s in %s\n' "$N" "$GAP_ID" "$LOCK_DIR"

start_ns=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')

# Spawn N background processes. Each gets its own CHUMP_SESSION_ID and
# bypasses the worktree-guard / preflight-broadcast (which would try to talk
# to the real ambient stream). We exercise gap-claim.sh directly — that is
# the file-write path under stress.
pids=()
results_dir="$TMPDIR_BASE/results"
mkdir -p "$results_dir"

for i in $(seq 1 "$N"); do
    (
        export CHUMP_LOCK_DIR="$LOCK_DIR"
        export CHUMP_SESSION_ID="stress-agent-$i-$$"
        export CHUMP_PATH_CASE_CHECK=0
        export CHUMP_ALLOW_MAIN_WORKTREE=1
        # Mirror the production agent flow: check the lock dir for any existing
        # claim on this gap-id BEFORE writing our own claim. This exposes the
        # actual race window that exists in real agent runs (between the
        # check and the write — non-atomic in the file-based path).
        if compgen -G "$LOCK_DIR/*.json" > /dev/null && \
           grep -l "\"gap_id\": *\"$GAP_ID\"" "$LOCK_DIR"/*.json >/dev/null 2>&1; then
            echo "1" > "$results_dir/$i.exit"
            echo "abort: another lease holds $GAP_ID" > "$results_dir/$i.err"
            exit 0
        fi
        if "$REPO_ROOT/scripts/gap-claim.sh" "$GAP_ID" >"$results_dir/$i.out" 2>"$results_dir/$i.err"; then
            echo "0" > "$results_dir/$i.exit"
        else
            echo "$?" > "$results_dir/$i.exit"
        fi
    ) &
    pids+=($!)
done

# Wait for all to finish. Hard timeout 30s — if any agent hangs we treat it
# as a deadlock failure.
deadline=$(( $(date +%s) + 30 ))
for pid in "${pids[@]}"; do
    while kill -0 "$pid" 2>/dev/null; do
        if [[ "$(date +%s)" -gt "$deadline" ]]; then
            echo "[stress] FAIL: deadlock — pid $pid still running at 30s" >&2
            kill -9 "${pids[@]}" 2>/dev/null || true
            exit 1
        fi
        sleep 0.1
    done
    wait "$pid" 2>/dev/null || true
done

end_ns=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

# Count successful exits and lease files referencing GAP_ID.
ok_count=0
err_count=0
for i in $(seq 1 "$N"); do
    if [[ "$(cat "$results_dir/$i.exit")" == "0" ]]; then
        ok_count=$((ok_count + 1))
    else
        err_count=$((err_count + 1))
    fi
done

# Lease files that ended up referencing GAP_ID — this is the "claimed" count.
claim_count=0
if compgen -G "$LOCK_DIR/*.json" > /dev/null; then
    claim_count=$(grep -l "\"gap_id\": *\"$GAP_ID\"" "$LOCK_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
fi

printf '[stress] elapsed_ms=%d agents=%d ok=%d err=%d leases_holding_gap=%d\n' \
    "$elapsed_ms" "$N" "$ok_count" "$err_count" "$claim_count"

if [[ "$claim_count" -lt 1 ]]; then
    echo "[stress] FAIL: zero leases written — file-based claim broken" >&2
    exit 1
fi

if [[ "$claim_count" -gt 1 ]]; then
    printf '[stress] OBSERVED: %d agents simultaneously hold lease for %s\n' "$claim_count" "$GAP_ID"
    printf '[stress]   This documents the COORD-NATS race window: gap-claim.sh\n'
    printf '[stress]   has no atomic CAS in the file-based path. NATS atomic claim\n'
    printf '[stress]   (chump-coord) closes this race when available.\n'
    printf '[stress]   See docs/INFRA-042-MULTI-AGENT-REPORT.md for analysis.\n'
fi

echo "[stress] PASS: no deadlock, $claim_count/$N agents acquired the lease"
exit 0
