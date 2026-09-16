#!/usr/bin/env bash
# scripts/ci/test-gap-id-extraction.sh — CREDIBLE-1258 (CREDIBLE-268 slice)
#
# Validates the current gap-ID extraction mechanism in
# scripts/ops/github-webhook-receiver.py:
#   1. Unit test: _extract_gap_ids pulls IDs from PR title (regex applied
#      directly) and from body `Closes:` trailer lines (regex applied within
#      the matched trailer), via \b([A-Z][A-Z-]+-\d+)\b.
#   2. Integration test: spawn the receiver, POST a synthetic merged
#      pull_request webhook, and verify the extracted-ID list surfaced via
#      the gap_autoflip_suppressed ambient event (would_have_flipped) matches
#      the expected list (title ID + Closes: trailer ID, deduped, in order).
#   3. Both run under this script so CI enforces pass/fail as one gate.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RECEIVER="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$RECEIVER" ]] || fail "receiver missing"

# ── 1. Unit test: _extract_gap_ids (AC1) ───────────────────────────────────
python3 - "$RECEIVER" <<'PYEOF' || fail "unit test for _extract_gap_ids failed"
import importlib.util
import sys

receiver_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("github_webhook_receiver", receiver_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

extract = mod._extract_gap_ids

# Title-only match
ids = extract({"title": "CREDIBLE-1258: validate gap id extraction", "body": ""})
assert ids == ["CREDIBLE-1258"], f"title-only extraction wrong: {ids}"

# Body Closes: trailer match
ids = extract({"title": "some unrelated title", "body": "context text\nCloses: INFRA-42\nmore text"})
assert ids == ["INFRA-42"], f"body Closes: trailer extraction wrong: {ids}"

# Title + body combined, deduped, order preserved (title first)
ids = extract({
    "title": "INFRA-1 INFRA-2: two gaps",
    "body": "see also INFRA-2 in passing\nCloses: INFRA-3, INFRA-1",
})
assert ids == ["INFRA-1", "INFRA-2", "INFRA-3"], f"combined extraction wrong: {ids}"

# Body text outside a Closes: trailer is NOT scanned
ids = extract({"title": "no gap here", "body": "References INFRA-99 for context"})
assert ids == [], f"non-trailer body text should not match: {ids}"

# No matches
ids = extract({"title": "chore: tidy up", "body": ""})
assert ids == [], f"expected no matches: {ids}"

print("unit test ok")
PYEOF
ok "_extract_gap_ids: title + Closes: trailer extraction via \\b([A-Z][A-Z-]+-\\d+)\\b"

# ── 2. Integration test: receiver end-to-end on a merged PR (AC2) ─────────
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
CACHE_DB="$TMP/cache.db"
AMBIENT="$TMP/ambient.jsonl"
SECRET="testsecret123"

CHUMP_WEBHOOK_PORT="$PORT" \
    CHUMP_GITHUB_WEBHOOK_SECRET="$SECRET" \
    CHUMP_CACHE_DB="$CACHE_DB" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    python3 "$RECEIVER" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 20); do
    if (echo >"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then break; fi
    sleep 0.2
done

PAYLOAD='{"action":"closed","pull_request":{"number":5678,"merged":true,"head":{"ref":"feature","sha":"abc1234567"},"base":{"ref":"main","sha":"def1234567"},"mergeable_state":"clean","auto_merge":null,"draft":false,"merged_at":"2026-09-16T00:00:00Z","title":"CREDIBLE-1258: sample merged PR","body":"Closes: INFRA-42","user":{"login":"tester"},"updated_at":"2026-09-16T00:00:00Z"}}'
SIG="sha256=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"

RC=$(curl -s -o "$TMP/resp.txt" -w "%{http_code}" \
    -H "X-Hub-Signature-256: $SIG" \
    -H "X-GitHub-Event: pull_request" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "http://127.0.0.1:$PORT/webhook")
[[ "$RC" == "200" ]] || fail "merged webhook returned $RC: $(cat "$TMP/resp.txt") server=$(cat "$TMP/server.log")"

sleep 0.3
LINE=$(grep '"kind":"gap_autoflip_suppressed"' "$AMBIENT" || true)
[[ -n "$LINE" ]] || fail "no gap_autoflip_suppressed event in ambient: $(cat "$AMBIENT" 2>/dev/null)"

EXTRACTED=$(python3 -c "
import json, sys
line = json.loads(sys.argv[1])
print(json.dumps(line.get('would_have_flipped')))
" "$LINE")
[[ "$EXTRACTED" == '["CREDIBLE-1258", "INFRA-42"]' ]] \
    || fail "extracted gap IDs wrong: got $EXTRACTED, expected [\"CREDIBLE-1258\", \"INFRA-42\"]"
ok "integration: merged PR extracted IDs match expected list (title + Closes: trailer)"

echo
echo "All CREDIBLE-1258 gap-ID extraction tests passed."
