#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-fleet-brief-alerts-window-honesty.sh — CREDIBLE-121
#
# `chump fleet brief` Alerts(30m) must be derived live from ambient.jsonl:
# >= 3 for 3 fresh alerts, 0 when only stale alerts exist, and it must name
# its source and per-kind breakdown.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$(dirname "$0")/lib/discover-chump-bin.sh"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "FAIL: chump binary not found at $CHUMP_BIN"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/.chump-locks" "$TMP/repo/.chump"
git -C "$TMP/repo" init -q

iso() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
AMB="$TMP/repo/.chump-locks/ambient.jsonl"

echo "Test 1: 3 fresh alerts (+1 stale) => Alerts(30m): 3 with kind breakdown"
cat >"$AMB" <<EOT
{"ts":"$(iso 5)","event":"ALERT","kind":"pr_stuck","session":"a"}
{"ts":"$(iso 10)","event":"alert","kind":"pr_stuck","session":"b"}
{"ts":"$(iso 15)","event":"ALERT","kind":"silent_agent","session":"c"}
{"ts":"$(iso 300)","event":"ALERT","kind":"silent_agent","session":"d"}
EOT
OUT="$(CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief 2>/dev/null)"
if echo "$OUT" | grep -qE "Alerts\(30m\): 3 .*ambient\.jsonl.*pr_stuck=2.*silent_agent=1"; then
    echo "  PASS"
else
    echo "  FAIL: got:"; echo "$OUT" | grep -i alert | sed 's/^/  /'; exit 1
fi

echo "Test 2: only stale alerts => Alerts(30m): 0"
cat >"$AMB" <<EOT
{"ts":"$(iso 300)","event":"ALERT","kind":"silent_agent","session":"d"}
EOT
OUT="$(CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief 2>/dev/null)"
if echo "$OUT" | grep -qE "Alerts\(30m\): 0 "; then
    echo "  PASS"
else
    echo "  FAIL: got:"; echo "$OUT" | grep -i alert | sed 's/^/  /'; exit 1
fi

echo "All tests passed."
