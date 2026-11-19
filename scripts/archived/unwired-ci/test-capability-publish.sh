#!/usr/bin/env bash
# scripts/ci/test-capability-publish.sh — INFRA-1825
#
# Verifies capability-publish.sh + chump-capabilities.sh:
#   1. once-mode writes a valid JSON line matching chump-capability-v1 schema
#   2. multiple emits append (not overwrite)
#   3. chump-capabilities.sh list reads + dedups + filters stale
#   4. CHUMP_AUTO_CAPABILITY=0 bypass emits audit event + no manifest write
#   5. CHUMP_PUBLISH_HARDWARE=1 includes gpu/ip; default omits

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUB="$REPO_ROOT/scripts/coord/capability-publish.sh"
CAPS="$REPO_ROOT/scripts/coord/chump-capabilities.sh"
[[ ! -x "$PUB" ]] && { echo "FAIL: $PUB not executable"; exit 1; }
[[ ! -x "$CAPS" ]] && { echo "FAIL: $CAPS not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CHUMP_LOCK_DIR="$TMP/.chump-locks"
export CHUMP_CAPABILITY_DIR="$TMP/.chump-locks/capabilities"
export CHUMP_AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$CHUMP_CAPABILITY_DIR"
touch "$CHUMP_AMBIENT_LOG"

failures=0
fail() { echo "FAIL: $1"; failures=$((failures+1)); }

# ── 1. once-mode writes schema-v1 manifest ──────────────────────────────────
CHUMP_SESSION_ID="test-session-1" CHUMP_AGENT_HARNESS="claude" \
    FLEET_MODEL="opus" CHUMP_SKILLS="rust,shell" \
    "$PUB" once
inbox="$CHUMP_CAPABILITY_DIR/test-session-1.jsonl"
[[ -f "$inbox" ]] || fail "once: did not create $inbox"
grep -q '"schema_version":"chump-capability-v1"' "$inbox" || fail "once: missing schema_version v1"
grep -q '"session_id":"test-session-1"' "$inbox" || fail "once: missing session_id"
grep -q '"harness":"claude"' "$inbox" || fail "once: missing harness"
grep -q '"model_tier":"opus"' "$inbox" || fail "once: missing model_tier"
grep -q '"ttl_seconds":300' "$inbox" || fail "once: missing ttl_seconds=300"
grep -q '"skills":\["rust","shell"\]' "$inbox" || fail "once: skills not encoded as JSON array"

# ── 2. multiple emits append ────────────────────────────────────────────────
CHUMP_SESSION_ID="test-session-1" "$PUB" once
CHUMP_SESSION_ID="test-session-1" "$PUB" once
n=$(wc -l < "$inbox" | tr -d ' ')
[[ "$n" -eq 3 ]] || fail "append: expected 3 lines after 3 emits, got $n"

# ── 3. chump-capabilities list ─────────────────────────────────────────────
out="$("$CAPS" list 2>&1)"
echo "$out" | grep -q "test-session-1" || fail "list: missing test-session-1"
echo "$out" | grep -q "claude" || fail "list: missing harness column"

# 3b. count
c="$("$CAPS" count)"
[[ "$c" == "1" ]] || fail "count: expected 1 live session, got '$c'"

# ── 4. CHUMP_AUTO_CAPABILITY=0 bypass ──────────────────────────────────────
rm -f "$inbox"
CHUMP_SESSION_ID="test-session-2" CHUMP_AUTO_CAPABILITY=0 "$PUB" once
[[ ! -f "$CHUMP_CAPABILITY_DIR/test-session-2.jsonl" ]] || fail "bypass: should not have created session-2 manifest"
grep -q "auto_capability_bypassed" "$CHUMP_AMBIENT_LOG" || fail "bypass: missing audit emit"

# ── 5. CHUMP_PUBLISH_HARDWARE gating ───────────────────────────────────────
CHUMP_SESSION_ID="test-session-3" CHUMP_PUBLISH_HARDWARE=1 \
    CHUMP_GPU_LABEL="test-gpu" CHUMP_IP_LABEL="10.0.0.5" "$PUB" once
inbox3="$CHUMP_CAPABILITY_DIR/test-session-3.jsonl"
grep -q '"gpu":"test-gpu"' "$inbox3" || fail "hw-opt-in: missing gpu"
grep -q '"ip":"10.0.0.5"' "$inbox3" || fail "hw-opt-in: missing ip"
# Default-off check (no env)
CHUMP_SESSION_ID="test-session-4" "$PUB" once
inbox4="$CHUMP_CAPABILITY_DIR/test-session-4.jsonl"
grep -q '"gpu":null' "$inbox4" || fail "hw-default-off: gpu should be null"
grep -q '"ip":null' "$inbox4" || fail "hw-default-off: ip should be null"

[[ $failures -gt 0 ]] && { echo "FAIL INFRA-1825: $failures"; exit 1; }
echo "OK INFRA-1825: capability-publish + chump-capabilities work end-to-end (v0 file-backed)"
