#!/usr/bin/env bash
# scripts/ci/test-webhook-pr-merge-prune.sh — INFRA-1705
#
# Verifies the github-webhook-receiver auto-prunes the corresponding
# /tmp/chump-<slug>/ worktree when a pull_request closed+merged delivery
# arrives. Closes the 5-10min orphan window between PR-merge and the
# periodic prune-worktrees.sh sweep.
#
# Static + end-to-end:
#   1. Receiver script parses
#   2. _auto_prune_worktree_on_merge defined + called in PR handler
#   3. End-to-end: synthetic git repo, real worktree, HMAC-signed POST,
#      assert worktree gone afterward + ambient event emitted with
#      trigger=pr_merge_webhook
#
# Rust-First-Bypass: integration test for a Python webhook handler that
#   coordinates with git worktree commands; bash is the right shape for
#   spawning the server, POSTing, and asserting on filesystem state.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RECEIVER="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

TMP="$(mktemp -d)"
SLUG="test-1705-$$-$(date +%s)"
WT_PATH="/tmp/chump-$SLUG"
trap 'rm -rf "$TMP" "$WT_PATH"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

# ── 1. Static checks ──────────────────────────────────────────────────────
[[ -f "$RECEIVER" ]] || fail "receiver missing"
python3 -c "import py_compile; py_compile.compile('$RECEIVER', doraise=True)" \
    || fail "receiver fails py_compile"
ok "receiver script parses cleanly"

grep -q "def _auto_prune_worktree_on_merge" "$RECEIVER" \
    || fail "_auto_prune_worktree_on_merge function missing"
ok "_auto_prune_worktree_on_merge defined"

grep -q "_auto_prune_worktree_on_merge(pr, payload)" "$RECEIVER" \
    || fail "_auto_prune_worktree_on_merge not invoked in PR handler"
ok "_auto_prune_worktree_on_merge invoked in PR handler"

# ── 2. Set up synthetic git repo + linked worktree ────────────────────────
SYNTH_REPO="$TMP/repo"
mkdir -p "$SYNTH_REPO"
git -C "$SYNTH_REPO" init -q
git -C "$SYNTH_REPO" config user.email "test@chump.local"
git -C "$SYNTH_REPO" config user.name "test"
echo "init" >"$SYNTH_REPO/README.md"
git -C "$SYNTH_REPO" add README.md
git -C "$SYNTH_REPO" commit -q -m "init"

# Create a linked worktree at /tmp/chump-<slug> matching the convention
# the receiver derives.
git -C "$SYNTH_REPO" worktree add -q -b "chump/$SLUG-claim" "$WT_PATH" \
    || fail "git worktree add failed"
[[ -d "$WT_PATH" ]] || fail "worktree dir not created at $WT_PATH"
ok "synthetic worktree created at $WT_PATH"

# ── 3. Start the receiver ─────────────────────────────────────────────────
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
CACHE_DB="$TMP/cache.db"
AMBIENT="$TMP/ambient.jsonl"
SECRET="testsecret-infra-1705"

CHUMP_WEBHOOK_PORT="$PORT" \
    CHUMP_GITHUB_WEBHOOK_SECRET="$SECRET" \
    CHUMP_CACHE_DB="$CACHE_DB" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_REPO="$SYNTH_REPO" \
    CHUMP_LEASE_NO_AUTO_RELEASE=1 \
    python3 "$RECEIVER" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

# Wait for the server port to open.
for _ in $(seq 1 20); do
    if (echo >"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then break; fi
    sleep 0.1
done

# ── 4. Synthesize + sign + POST a closed+merged pull_request webhook ──────
PAYLOAD_JSON=$(cat <<EOF
{
  "action": "closed",
  "pull_request": {
    "number": 99999,
    "title": "feat(TEST-1705): synthetic merged PR for prune smoke test",
    "body": "INFRA-1705 smoke test payload",
    "merged": true,
    "state": "closed",
    "merged_at": "2026-05-22T23:59:59Z",
    "head": {
      "ref": "chump/$SLUG-claim",
      "sha": "0000000000000000000000000000000000000000"
    },
    "base": {
      "ref": "main",
      "sha": "0000000000000000000000000000000000000001"
    },
    "auto_merge": null,
    "mergeable_state": "clean",
    "user": {"login": "test"}
  }
}
EOF
)

SIG_HEX=$(printf '%s' "$PAYLOAD_JSON" | openssl dgst -sha256 -hmac "$SECRET" -binary | xxd -p -c 256)
SIG="sha256=$SIG_HEX"

HTTP_CODE=$(printf '%s' "$PAYLOAD_JSON" | curl -sS -o "$TMP/resp.txt" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$PORT/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: pull_request" \
    -H "X-Hub-Signature-256: $SIG" \
    --data-binary "@-")
[[ "$HTTP_CODE" == "200" ]] || fail "POST returned HTTP $HTTP_CODE (expected 200); resp=$(cat "$TMP/resp.txt")"
ok "POST accepted by receiver (HTTP 200)"

# ── 5. Assert worktree gone + ambient event emitted ───────────────────────
# Brief wait for the receiver to finish handling.
for _ in $(seq 1 30); do
    [[ ! -d "$WT_PATH" ]] && break
    sleep 0.1
done

[[ ! -d "$WT_PATH" ]] || fail "worktree $WT_PATH still present after merge webhook"
ok "worktree pruned after PR merge"

[[ -f "$AMBIENT" ]] || fail "ambient.jsonl not created"
grep -q '"kind":"worktree_orphan_pruned"' "$AMBIENT" \
    || fail "no worktree_orphan_pruned event in ambient.jsonl: $(cat "$AMBIENT")"
grep -q '"trigger":"pr_merge_webhook"' "$AMBIENT" \
    || fail "worktree_orphan_pruned event missing trigger=pr_merge_webhook: $(cat "$AMBIENT")"
grep -q "\"branch\":\"chump/$SLUG-claim\"" "$AMBIENT" \
    || fail "worktree_orphan_pruned event missing branch field: $(cat "$AMBIENT")"
ok "ambient event emitted with trigger=pr_merge_webhook + branch"

echo ""
echo "ALL INFRA-1705 webhook-prune tests passed."
