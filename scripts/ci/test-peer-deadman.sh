#!/usr/bin/env bash
# RESILIENT-1901 — peer-deadman: unreachable, flapping, recovery, blind observer, digest fallback.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DM="$ROOT/scripts/ops/peer-deadman.sh"
fail() { echo "  ✗ $*" >&2; exit 1; }
pass() { echo "  ✓ $*"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
bash -n "$DM" || fail "syntax"
for f in chump-peer-deadman.service chump-peer-deadman.timer; do [[ -f "$ROOT/scripts/dispatch/$f" ]] || fail "missing $f"; done
grep -q 'chump-peer-deadman.timer.*home=slim' "$ROOT/scripts/ops/organ-manifest.txt" || fail "manifest"
grep -q 'External liveness' "$ROOT/docs/process/FLEET_SLOS.md" || fail "FLEET_SLOS"

cat > "$T/tailscale" <<S
#!/bin/bash
if [ "\$1" = status ]; then [ "\$(cat $T/ts)" = up ]; exit \$?; fi
[ "\$(cat $T/hub)" = up ]
S
printf '#!/bin/bash\n[ "$(cat %s/hub)" = up ]\n' "$T" > "$T/ssh"
cp "$T/ssh" "$T/curl"
printf '#!/bin/bash\necho "$1" >> %s/pages\n' "$T" > "$T/notify"
printf '#!/bin/bash\necho "$CHUMP_DIGEST_FALLBACK_REASON" >> %s/digests\n' "$T" > "$T/digest"
chmod +x "$T"/tailscale "$T"/ssh "$T"/curl "$T"/notify "$T"/digest
echo up > "$T/ts"

LOG="$T/ambient.jsonl"; : > "$LOG"
run() {  # <epoch>; hub state from $T/hub
    CHUMP_PEER_DEADMAN_HUB=fakehub CHUMP_PEER_DEADMAN_STATE_DIR="$T/state" CHUMP_PEER_DEADMAN_NOW="$1" \
    CHUMP_PEER_DEADMAN_TS_BIN="$T/tailscale" CHUMP_PEER_DEADMAN_SSH_BIN="$T/ssh" CHUMP_PEER_DEADMAN_CURL_BIN="$T/curl" \
    CHUMP_PEER_DEADMAN_NOTIFY_BIN="$T/notify" CHUMP_PEER_DEADMAN_DIGEST_BIN="$T/digest" \
    CHUMP_PEER_DEADMAN_DIGEST_HOURS_UTC="16" CHUMP_AMBIENT_LOG="$LOG" bash "$DM" >/dev/null 2>&1
}
count() { grep -c "\"kind\":\"$1\"" "$LOG" 2>/dev/null || true; }
pages() { [[ -f "$T/pages" ]] && wc -l < "$T/pages" || echo 0; }
B=1793548800   # 2026-11-01T16:00:00Z (digest hour 16)

echo down > "$T/hub"
run "$B"; run $((B+300))
[[ "$(count node_unreachable)" == 0 && "$(pages)" == 0 ]] || fail "paged before 10 min"
run $((B+600))
[[ "$(count node_unreachable)" == 1 && "$(pages)" == 1 ]] || fail "expected 1 event + 1 page at 10 min"
run $((B+900)); run $((B+1200))
[[ "$(count node_unreachable)" == 1 && "$(pages)" == 1 ]] || fail "re-paged during outage"
pass "unreachable: one event, one page, silent after"
[[ "$(wc -l < "$T/digests")" == 1 ]] && grep -q 'fakehub dark' "$T/digests" || fail "digest fallback should run once, labelled"
pass "digest fallback runs once from this node while hub dark"

echo up > "$T/hub"; run $((B+1500))
[[ "$(count node_reachable)" == 1 ]] || fail "node_reachable not emitted once"
run $((B+1800))
[[ "$(count node_reachable)" == 1 && "$(pages)" == 1 ]] || fail "duplicate recovery"
pass "recovery: node_reachable once"

: > "$LOG"; rm -f "$T/pages"
for i in 0 1 2 3; do
    echo down > "$T/hub"; run $((B+4000+i*1000)); run $((B+4000+i*1000+300))
    echo up > "$T/hub"; run $((B+4000+i*1000+500))
done
[[ "$(count node_unreachable)" == 0 && "$(count node_reachable)" == 0 && "$(pages)" == 0 ]] || fail "flapping paged"
pass "flapping under 10 min: no page, no events"

echo down > "$T/hub"; echo down > "$T/ts"; rm -rf "$T/state"
run "$B"; run $((B+900))
[[ "$(count node_unreachable)" == 0 ]] && grep -q 'observer_tailnet":"down' "$LOG" || fail "blind observer paged or unreported"
pass "own tailnet down: reported blind, not paged"
echo "PASS test-peer-deadman"
