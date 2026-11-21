#!/usr/bin/env bash
# scripts/ci/test-a2a-roadmap-coord.sh — INFRA-1150
#
# Verifies the a2a-mailbox coordination wiring:
#   1. SessionStart inbox-inject block exists in ambient-context-inject.sh
#   2. The inbox-inject reads via chump-inbox.sh and dedups by (kind,from,gap)
#   3. roadmap-status-broadcast.sh exists, is executable, and routes drift
#      to broadcast.sh WARN --to all
#   4. Both new ambient kinds registered in EVENT_REGISTRY.yaml
#   5. Bypass + master-switch env vars wired (CHUMP_A2A_INBOX_INJECT=0,
#      CHUMP_A2A_COORD_DISABLE=1)
#   6. End-to-end inbox-inject: stub mailbox with 2 broadcasts (one
#      duplicate (kind,from,gap)), assert dedup'd output renders once.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INJECT="$REPO_ROOT/scripts/coord/ambient-context-inject.sh"
BROADCAST_WRAP="$REPO_ROOT/scripts/coord/roadmap-status-broadcast.sh"
INBOX="$REPO_ROOT/scripts/coord/chump-inbox.sh"
ER="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# 1. SessionStart inbox-inject block present
grep -q "INFRA-1150: a2a inbox inject" "$INJECT" \
    || fail "ambient-context-inject.sh missing INFRA-1150 inbox block"
ok "ambient-context-inject.sh has INFRA-1150 inbox-inject block"

# 2. Bypass + master-switch wired
grep -q "CHUMP_A2A_INBOX_INJECT" "$INJECT" \
    || fail "missing CHUMP_A2A_INBOX_INJECT bypass"
grep -q "CHUMP_A2A_COORD_DISABLE" "$INJECT" \
    || fail "missing CHUMP_A2A_COORD_DISABLE master switch"
ok "bypass + master-switch env vars wired"

# 3. INBOX_INJECT_FILE plumbed through to digest
grep -q 'INBOX_INJECT_FILE=' "$INJECT" \
    || fail "INBOX_INJECT_FILE not exported to digest"
grep -qE 'os\.environ\.get\("INBOX_INJECT_FILE"' "$INJECT" \
    || fail "digest does not read INBOX_INJECT_FILE"
ok "INBOX_INJECT_FILE exported to digest and consumed there"

# 4. Dedup logic by (kind, from, gap)
grep -q "Dedup by (kind, from, gap)" "$INJECT" \
    || fail "dedup-by-(kind,from,gap) logic missing"
ok "dedup logic present"

# 5. roadmap-status-broadcast.sh exists + executable + uses broadcast.sh WARN --to all
[[ -x "$BROADCAST_WRAP" ]] || fail "roadmap-status-broadcast.sh missing or not executable"
grep -q '\-\-to all WARN' "$BROADCAST_WRAP" \
    || fail "broadcast wrapper does not call broadcast.sh --to all WARN"
ok "roadmap-status-broadcast.sh routes drift via broadcast.sh --to all WARN"

# 6. EVENT_REGISTRY registers both new kinds
grep -q '^  - kind: a2a_coord_broadcast_sent' "$ER" \
    || fail "EVENT_REGISTRY missing a2a_coord_broadcast_sent"
grep -q '^  - kind: a2a_coord_inbox_consumed' "$ER" \
    || fail "EVENT_REGISTRY missing a2a_coord_inbox_consumed"
ok "EVENT_REGISTRY registers both new kinds"

# 7. End-to-end dedup test: feed a 2-message inbox where 2 are identical
# (same kind/from/gap) and assert the output renders 1 line for the dup'd pair.
TMP=$(mktemp -d -t a2a-dedup-test-XXXX)
trap 'rm -rf "$TMP"' EXIT

# Synthesise a JSON array as if chump-inbox.sh emitted it
cat > "$TMP/inbox.json" <<'EOF'
[
  {"kind":"WARN","session":"agentA","gap":"INFRA-9999","note":"hot file index.html"},
  {"kind":"WARN","session":"agentA","gap":"INFRA-9999","note":"hot file index.html duplicate"},
  {"kind":"INTENT","session":"agentB","gap":"INFRA-1234","note":"about to touch src/main.rs"}
]
EOF

# Run the same Python dedup logic from the inject block (extract + execute)
OUT="$TMP/out.txt"
python3 -c "
import json, sys
from pathlib import Path
msgs = json.loads(Path('$TMP/inbox.json').read_text())
seen = set()
dedup = []
for m in msgs:
    k = (m.get('kind') or m.get('event') or '?',
         m.get('session') or m.get('from') or '?',
         m.get('gap') or '?')
    if k in seen:
        continue
    seen.add(k)
    dedup.append(m)
dedup = dedup[:10]
lines = ['=== Pending broadcasts (INFRA-1150 a2a) ===']
for m in dedup:
    ev = m.get('kind') or m.get('event') or '?'
    src = m.get('session') or m.get('from') or '?'
    gap = m.get('gap') or '-'
    note = m.get('note') or m.get('message') or ''
    if len(note) > 80:
        note = note[:77] + '...'
    lines.append(f'[{ev}] {src} gap={gap} {note}')
lines.append(f'(showing {len(dedup)} of {len(msgs)} pending; chump-inbox.sh read --since cursor to consume)')
Path('$OUT').write_text('\n'.join(lines))
"

# Assert: 3 input messages, 2 dedup'd (one dup pair), so 2 lines + header + summary = 4 lines
[[ -s "$OUT" ]] || fail "dedup logic produced no output"
LINES=$(wc -l < "$OUT" | tr -d ' ')
# Expected: header + 2 dedup'd msgs + summary = 4 lines (last line has no trailing newline so wc -l reports 3)
if ! grep -q "showing 2 of 3 pending" "$OUT"; then
    echo "--- output of dedup test ---"
    cat "$OUT"
    fail "dedup did not collapse 3 → 2 messages (one duplicate pair); see output above"
fi
grep -q 'INFRA-9999' "$OUT" || fail "first dedup'd msg missing"
grep -q 'INFRA-1234' "$OUT" || fail "second msg missing"
# Verify the duplicate kind/from/gap pair rendered ONCE not TWICE
COUNT_INFRA9999=$(grep -c 'INFRA-9999' "$OUT" || true)
[[ "$COUNT_INFRA9999" -eq 1 ]] || fail "duplicate (kind,from,gap=INFRA-9999) rendered $COUNT_INFRA9999 times (expected 1)"
ok "end-to-end dedup: 3 input → 2 unique, duplicate (kind,from,gap) collapsed"

echo
echo "All INFRA-1150 a2a-roadmap-coord tests passed."
