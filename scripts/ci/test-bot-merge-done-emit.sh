#!/usr/bin/env bash
# scripts/ci/test-bot-merge-done-emit.sh — INFRA-1253
#
# Verifies the INFRA-1253 hook in bot-merge.sh: after a successful
# auto-close (gap ship), the script must:
#   1. Call broadcast.sh DONE with corr_id=<gap-id>
#   2. Clear any INFRA-1220 cooldown stamp for the gap
#   3. Remove any INFRA-1252 .handoff-pending/<gap>.ts stamp

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Extract just the INFRA-1253 block from bot-merge.sh and exercise it
# in isolation. Avoids invoking the whole multi-stage script.
SNIPPET=$(awk '/INFRA-1253: emit DONE/,/INFRA-192: forward-chain notifier/' \
    "$REPO_ROOT/scripts/coord/bot-merge.sh")
[ -n "$SNIPPET" ] || fail "could not extract INFRA-1253 block from bot-merge.sh"

# Sandbox
mkdir -p "$TMP/sandbox/scripts/coord" "$TMP/sandbox/.chump-locks/.handoff-pending"
cat > "$TMP/sandbox/scripts/coord/broadcast.sh" <<'EOF'
#!/usr/bin/env bash
# Stub broadcast.sh: log every invocation incl. env vars of interest.
echo "ARGS=$* CHUMP_CORR_ID=${CHUMP_CORR_ID:-}" >> "$BROADCAST_LOG"
EOF
chmod +x "$TMP/sandbox/scripts/coord/broadcast.sh"
cat > "$TMP/sandbox/scripts/coord/gap-cooldown.sh" <<'EOF'
#!/usr/bin/env bash
echo "ARGS=$*" >> "$COOLDOWN_LOG"
EOF
chmod +x "$TMP/sandbox/scripts/coord/gap-cooldown.sh"

export BROADCAST_LOG="$TMP/broadcast.log"
export COOLDOWN_LOG="$TMP/cooldown.log"
: > "$BROADCAST_LOG"; : > "$COOLDOWN_LOG"

# Pre-fill a handoff-pending stamp to verify cleanup
touch "$TMP/sandbox/.chump-locks/.handoff-pending/INFRA-7777.ts"

# Build a driver that supplies the var bindings the snippet expects,
# then runs the snippet.
cat > "$TMP/sandbox/driver.sh" <<DRIVER
#!/usr/bin/env bash
set -uo pipefail
_gid="INFRA-7777"
TARGET_PR=9999
_rd_sha="deadbeef"
LOCK_DIR="$TMP/sandbox/.chump-locks"
green()  { :; }
$SNIPPET
DRIVER
chmod +x "$TMP/sandbox/driver.sh"
(cd "$TMP/sandbox" && bash driver.sh)

# Assertions
grep -q "DONE INFRA-7777" "$BROADCAST_LOG" \
    || fail "broadcast.sh DONE not invoked: $(cat "$BROADCAST_LOG")"
grep -q "CHUMP_CORR_ID=INFRA-7777" "$BROADCAST_LOG" \
    || fail "DONE must carry corr_id=INFRA-7777: $(cat "$BROADCAST_LOG")"
ok "broadcast.sh DONE fires with corr_id=gap-id"

grep -q "clear INFRA-7777" "$COOLDOWN_LOG" \
    || fail "gap-cooldown.sh clear not invoked: $(cat "$COOLDOWN_LOG")"
ok "gap-cooldown.sh clear fires for the gap"

[ ! -f "$TMP/sandbox/.chump-locks/.handoff-pending/INFRA-7777.ts" ] \
    || fail "handoff-pending stamp should be removed after DONE"
ok "INFRA-1252 handoff-pending stamp is cleared"

echo
echo "All INFRA-1253 bot-merge DONE-emit tests passed."
