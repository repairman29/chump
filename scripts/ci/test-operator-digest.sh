#!/usr/bin/env bash
# scripts/ci/test-operator-digest.sh — INFRA-1302

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/operator-digest.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -x "$SCRIPT" ] || fail "missing"

export CHUMP_LOCK_DIR="$TMP/locks"
mkdir -p "$CHUMP_LOCK_DIR/inbox"

AMB="$CHUMP_LOCK_DIR/ambient.jsonl"
FB="$CHUMP_LOCK_DIR/feedback.jsonl"

# Seed test fixtures via a single python script that writes directly to the
# right files. Avoids bash quoting hell when nesting JSON in command-sub.
python3 - "$AMB" "$FB" "$CHUMP_LOCK_DIR/inbox/operator-test.jsonl" <<'PY'
import json, sys
from datetime import datetime, timezone
ts = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
amb_path, fb_path, inbox_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(fb_path, "w") as f:
    for sess in ("sess-1", "sess-2", "sess-3"):
        f.write(json.dumps({
            "event": "FEEDBACK", "kind": "proposal", "session": sess,
            "ts": ts, "subject": "POLICY-A", "rationale": "x",
        }) + "\n")
with open(amb_path, "w") as f:
    f.write(json.dumps({
        "event": "STUCK", "session": "sess-x", "ts": ts,
        "subject": "INFRA-9999", "corr_id": "INFRA-9999", "reason": "flaky",
    }) + "\n")
    f.write(json.dumps({
        "event": "DONE", "session": "sess-y", "ts": ts,
        "subject": "INFRA-100", "corr_id": "INFRA-100", "commit": "abc",
    }) + "\n")
    f.write(json.dumps({
        "event": "DONE", "session": "sess-y", "ts": ts,
        "subject": "CREDIBLE-50", "corr_id": "CREDIBLE-50", "commit": "def",
    }) + "\n")
with open(inbox_path, "w") as f:
    f.write(json.dumps({
        "event": "HANDOFF", "session": "sess-x", "ts": ts,
        "subject": "INFRA-9001", "to": "operator-test",
    }) + "\n")
PY

# ── Test 1: JSON mode shape ────────────────────────────────────────────
out=$("$SCRIPT" --json)
echo "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
# FEEDBACK proposal POLICY-A had 3 sessions → cluster surfaced
top = d.get('top_feedback_clusters', [])
hit = [c for c in top if c['subject'] == 'POLICY-A']
assert hit and hit[0]['n_sessions'] == 3, top
# Unresolved STUCK: INFRA-9999 no matching DONE
us = d.get('unresolved_stuck', [])
assert any(s['subject'] == 'INFRA-9999' for s in us), us
# DONE by domain: INFRA=1, CREDIBLE=1
done = d.get('done_by_domain', {})
assert done.get('INFRA', 0) == 1 and done.get('CREDIBLE', 0) == 1, done
# Pending operator HANDOFF
ph = d.get('pending_operator_handoffs', [])
assert any(p['operator'] == 'operator-test' for p in ph), ph
print('ok')
" || fail "JSON shape wrong: $out"
ok "JSON mode: feedback cluster + unresolved STUCK + DONE counts + pending HANDOFF"

# ── Test 2: human mode renders ─────────────────────────────────────────
human=$("$SCRIPT" --human)
echo "$human" | grep -q "Operator Digest" || fail "missing header"
echo "$human" | grep -q "POLICY-A" || fail "missing FEEDBACK cluster"
echo "$human" | grep -q "INFRA-9999" || fail "missing unresolved STUCK"
echo "$human" | grep -q "INFRA" || fail "missing DONE domain"
ok "human mode renders all sections"

# ── Test 3: CHUMP_NO_DIGEST=1 short-circuits ───────────────────────────
out=$(CHUMP_NO_DIGEST=1 "$SCRIPT" --json 2>&1)
echo "$out" | grep -q "disabled via CHUMP_NO_DIGEST" || fail "should skip when disabled: $out"
ok "CHUMP_NO_DIGEST=1 disables digest"

# ── Test 4: audit event emitted to ambient ─────────────────────────────
"$SCRIPT" --json >/dev/null
grep -q "operator_digest_emitted" "$AMB" || fail "audit event missing"
ok "audit event kind=operator_digest_emitted written to ambient"

echo
echo "All INFRA-1302 operator-digest tests passed."
