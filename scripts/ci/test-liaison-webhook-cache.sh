#!/usr/bin/env bash
# scripts/ci/test-liaison-webhook-cache.sh — INFRA-1877
#
# End-to-end smoke test for GitHub Liaison Phase 2 (INFRA-1318 sub-gap 5/5).
# Covers all 5 slice signals: α/β/γ/δ from INFRA-1873–1876 plus the combined
# receiver + liaison end-to-end path.
#
# Sections:
#   E2E  Spin up receiver on ephemeral port + start liaison --once; POST
#        pull_request + check_run payloads; assert webhook_cache_write +
#        pr_state/check_runs DB rows.
#   α    webhook_cache_write event per upsert (INFRA-1873)
#   β    liaison_cache_stale when row aged past CHUMP_LIAISON_CACHE_STALE_S (INFRA-1874)
#   γ    liaison_polling_fallback_active after health-probe failures (INFRA-1875)
#   δ    daemon offline-mode refuse + liaison_cache_offline_read tag (INFRA-1876)
#
# Target: <15s total wall-clock.
#
# Design notes:
#   - github_cache.sh::_cache_ambient_path() ignores CHUMP_AMBIENT_LOG; it
#     always writes to {git-show-toplevel}/.chump-locks/ambient.jsonl. We use
#     that native path for all assertions and take pre/post line-count snapshots
#     to isolate each section.
#   - github-liaison.sh hardcodes RECONCILE_SCRIPT=$REPO/scripts/ops/github-
#     cache-reconcile.sh (no env override). We replace it with a fast no-op
#     stub for the duration of any liaison --once call, then restore it. This
#     avoids the ~20s real gh-api round-trip without modifying the liaison
#     daemon or cache helpers.
#
# Rust-First-Bypass: integration test for a Python receiver + bash liaison
#   daemon; orchestrates process lifecycle, port allocation, and sqlite
#   state — bash is the right shape.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RECEIVER="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"
LIAISON="$REPO_ROOT/scripts/ops/github-liaison.sh"
CACHE_LIB="$REPO_ROOT/scripts/coord/lib/github_cache.sh"
# github-liaison.sh calls resolve_main_worktree() which always returns the
# main (non-linked) worktree via `git worktree list --porcelain`. The
# RECONCILE_SCRIPT it uses is therefore <main-worktree>/scripts/ops/…, NOT
# the path relative to REPO_ROOT (this worktree). Resolve the main worktree
# the same way so the stub targets the right file.
MAIN_WORKTREE="$(git -C "$REPO_ROOT/scripts/ops" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / {print $2; exit}')"
[[ -n "$MAIN_WORKTREE" ]] || MAIN_WORKTREE="$REPO_ROOT"
REAL_RECONCILE="$MAIN_WORKTREE/scripts/ops/github-cache-reconcile.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
info() { printf '      %s\n' "$*"; }

# Ambient path — all scripts resolve this via git show-toplevel.
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

TMP="$(mktemp -d)"
CACHE_DB="$TMP/cache.db"
SECRET="testsecret-infra-1877"
SERVER_PID=""
RECONCILE_BACKUP="$TMP/github-cache-reconcile.sh.bak"

# EXIT trap: kill server, remove tmp, restore reconcile if we swapped it out.
cleanup() {
    [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
    [[ -f "$RECONCILE_BACKUP" ]] && cp "$RECONCILE_BACKUP" "$REAL_RECONCILE" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

# ── Reconcile stub helpers ────────────────────────────────────────────────────
# Because liaison.sh hardcodes RECONCILE_SCRIPT=$REPO/…/github-cache-reconcile.sh
# (no env-override), we swap the file for a fast no-op for any liaison --once
# call, then restore immediately. Backup on first call; restore on each restore.
reconcile_stub_install() {
    [[ -f "$RECONCILE_BACKUP" ]] || cp "$REAL_RECONCILE" "$RECONCILE_BACKUP"
    printf '#!/usr/bin/env bash\n# INFRA-1877 test stub — exits 0 immediately\nexit 0\n' \
        > "$REAL_RECONCILE"
}
reconcile_stub_restore() {
    [[ -f "$RECONCILE_BACKUP" ]] && cp "$RECONCILE_BACKUP" "$REAL_RECONCILE" 2>/dev/null || true
}

# Snapshot helpers.
ambient_line_count() { wc -l < "$AMBIENT" 2>/dev/null || echo "0"; }
ambient_has_kind_after() {
    local since="$1" kind="$2"
    tail -n "+$((since + 1))" "$AMBIENT" 2>/dev/null | grep -q "\"kind\":\"$kind\""
}

# ── Static prerequisites ─────────────────────────────────────────────────────
[[ -f "$RECEIVER" ]]  || fail "receiver missing: $RECEIVER"
[[ -f "$LIAISON" ]]   || fail "liaison missing: $LIAISON"
[[ -f "$CACHE_LIB" ]] || fail "cache lib missing: $CACHE_LIB"
python3 -c "import py_compile; py_compile.compile('$RECEIVER', doraise=True)" \
    || fail "receiver fails py_compile"
bash -n "$LIAISON"   || fail "liaison has syntax error"
bash -n "$CACHE_LIB" || fail "cache lib has syntax error"
ok "static: all three source files parse cleanly"

# HMAC-SHA256 signature helper.
sign_payload() {
    local body="$1"
    printf 'sha256=%s' "$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"
}

# Port-open wait helper (max 4s).
wait_for_port() {
    local port="$1"
    for _ in $(seq 1 40); do
        if (echo >"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    return 1
}

# ── Spin up the webhook receiver ─────────────────────────────────────────────
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")

CHUMP_WEBHOOK_PORT="$PORT" \
    CHUMP_GITHUB_WEBHOOK_SECRET="$SECRET" \
    CHUMP_CACHE_DB="$CACHE_DB" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_LEASE_NO_AUTO_RELEASE=1 \
    CHUMP_NO_AUTO_PRUNE_WORKTREE=1 \
    python3 "$RECEIVER" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

wait_for_port "$PORT" \
    || fail "receiver did not start within 4s; log=$(cat "$TMP/server.log")"
ok "receiver started on port $PORT"

# Payloads.
PR_PAYLOAD='{"action":"opened","pull_request":{"number":7777,"head":{"ref":"feat/e2e-test","sha":"deadbeef11111111deadbeef11111111deadbeef"},"base":{"ref":"main","sha":"cafebabe22222222"},"mergeable_state":"clean","auto_merge":null,"draft":false,"merged_at":null,"title":"INFRA-1877 end-to-end smoke","user":{"login":"smoke-tester"},"updated_at":"2026-05-23T00:00:00Z"}}'
PR_SIG=$(sign_payload "$PR_PAYLOAD")

CHECK_PAYLOAD='{"action":"completed","check_suite":{"id":8888,"head_sha":"deadbeef11111111deadbeef11111111deadbeef","status":"completed","conclusion":"success","created_at":"2026-05-23T00:00:00Z","updated_at":"2026-05-23T00:01:00Z","app":{"slug":"github-actions"},"pull_requests":[{"number":7777}]}}'
CHECK_SIG=$(sign_payload "$CHECK_PAYLOAD")

# ── E2E: POST pull_request → DB row ──────────────────────────────────────────
SNAP_E2E=$(ambient_line_count)

RC=$(curl -s -o "$TMP/pr_resp.txt" -w "%{http_code}" \
    -H "X-Hub-Signature-256: $PR_SIG" \
    -H "X-GitHub-Event: pull_request" \
    -H "Content-Type: application/json" \
    -d "$PR_PAYLOAD" \
    "http://127.0.0.1:$PORT/webhook")
[[ "$RC" == "200" ]] || fail "E2E pull_request POST returned HTTP $RC: $(cat "$TMP/pr_resp.txt")"

PR_ROW=$(sqlite3 "$CACHE_DB" "SELECT number, mergeable_state FROM pr_state WHERE number=7777" 2>/dev/null)
[[ "$PR_ROW" == "7777|clean" ]] || fail "E2E pr_state row wrong: '$PR_ROW'"
ok "E2E: pull_request webhook → pr_state row written (number=7777, mergeable_state=clean)"

# POST check_suite → check_runs row.
RC=$(curl -s -o "$TMP/chk_resp.txt" -w "%{http_code}" \
    -H "X-Hub-Signature-256: $CHECK_SIG" \
    -H "X-GitHub-Event: check_suite" \
    -H "Content-Type: application/json" \
    -d "$CHECK_PAYLOAD" \
    "http://127.0.0.1:$PORT/webhook")
[[ "$RC" == "200" ]] || fail "E2E check_suite POST returned HTTP $RC: $(cat "$TMP/chk_resp.txt")"

sleep 0.3
CHK_ROW=$(sqlite3 "$CACHE_DB" \
    "SELECT COUNT(*) FROM check_runs WHERE head_sha='deadbeef11111111deadbeef11111111deadbeef'" 2>/dev/null)
[[ "$CHK_ROW" -ge "1" ]] || fail "E2E check_runs row not written (count=$CHK_ROW)"
ok "E2E: check_suite webhook → check_runs row written"

# liaison --once: install reconcile stub so it returns fast.
LIAISON_LOCK="$TMP/liaison.lock"
reconcile_stub_install
CHUMP_LIAISON_LOCK_DIR="$LIAISON_LOCK" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_LIAISON_WEBHOOK_HEALTH_DISABLED=1 \
    CHUMP_CACHE_DB="$CACHE_DB" \
    bash "$LIAISON" --once >/dev/null 2>&1 || true
reconcile_stub_restore

sleep 0.2
ambient_has_kind_after "$SNAP_E2E" liaison_elected \
    || fail "E2E liaison --once did not emit liaison_elected"
ok "E2E: liaison --once ran + emitted liaison_elected"

# ── Slice α: webhook_cache_write per upsert (INFRA-1873) ─────────────────────
ambient_has_kind_after "$SNAP_E2E" webhook_cache_write \
    || fail "α: no webhook_cache_write in ambient after pull_request POST"
tail -n "+$((SNAP_E2E + 1))" "$AMBIENT" | grep '"kind":"webhook_cache_write"' \
    | grep -q '"target":"pr"' \
    || fail "α: webhook_cache_write missing target=pr"
tail -n "+$((SNAP_E2E + 1))" "$AMBIENT" | grep '"kind":"webhook_cache_write"' \
    | grep -q '"target":"check_runs"' \
    || fail "α: no webhook_cache_write with target=check_runs after check_suite POST"
ok "slice α: webhook_cache_write emitted per upsert (pull_request + check_suite paths)"

# ── Slice β: liaison_cache_stale when row aged past CHUMP_LIAISON_CACHE_STALE_S (INFRA-1874) ──
# Age the row to epoch-zero so age_s >> any threshold.
# Use a gh stub on PATH so _cache_fetch_and_store exits at the `gh repo view`
# check (empty stdout → early return 1) without real API calls.
sqlite3 "$CACHE_DB" \
    "UPDATE pr_state SET fetched_at_local = '1970-01-01T00:00:00Z' WHERE number=7777"
info "β: aged pr_state row to 1970-01-01T00:00:00Z"

GH_STUB_DIR="$TMP/gh-stub"
mkdir -p "$GH_STUB_DIR"
printf '#!/usr/bin/env bash\n# fast stub — returns empty so _cache_fetch_and_store exits early\nexit 1\n' \
    > "$GH_STUB_DIR/gh"
chmod +x "$GH_STUB_DIR/gh"

SNAP_BETA=$(ambient_line_count)
CHUMP_CACHE_DB="$CACHE_DB" \
    CHUMP_LIAISON_CACHE_STALE_S=2 \
    CHUMP_CACHE_TTL_S=1 \
    PATH="$GH_STUB_DIR:$PATH" \
    bash -c "
        source '$CACHE_LIB'
        cache_lookup_pr 7777 >/dev/null 2>&1 || true
    " 2>/dev/null || true

sleep 0.2
ambient_has_kind_after "$SNAP_BETA" liaison_cache_stale \
    || fail "β: liaison_cache_stale not emitted; ambient tail=$(tail -5 "$AMBIENT" 2>/dev/null)"
ok "slice β: liaison_cache_stale emitted when cached row aged past CHUMP_LIAISON_CACHE_STALE_S=2"

# ── Slice γ: liaison_polling_fallback_active on health-probe failures (INFRA-1875) ──
# Use a dead port so curl fails immediately (connection refused, no 5s wait).
DEAD_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)")
GAMMA_LOCK="$TMP/gamma.lock"

reconcile_stub_install
SNAP_GAMMA=$(ambient_line_count)
# CHUMP_LIAISON_WEBHOOK_HEALTH_MAX_FAILS=1: single failure → threshold → both events fire.
CHUMP_LIAISON_LOCK_DIR="$GAMMA_LOCK" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_LIAISON_WEBHOOK_HEALTH_URL="http://127.0.0.1:$DEAD_PORT/health" \
    CHUMP_LIAISON_WEBHOOK_HEALTH_MAX_FAILS=1 \
    CHUMP_CACHE_DB="$CACHE_DB" \
    bash "$LIAISON" --once >/dev/null 2>&1 || true
reconcile_stub_restore

sleep 0.2
ambient_has_kind_after "$SNAP_GAMMA" liaison_webhook_unhealthy \
    || fail "γ: liaison_webhook_unhealthy not emitted; ambient tail=$(tail -5 "$AMBIENT" 2>/dev/null)"
ambient_has_kind_after "$SNAP_GAMMA" liaison_polling_fallback_active \
    || fail "γ: liaison_polling_fallback_active not emitted; ambient tail=$(tail -5 "$AMBIENT" 2>/dev/null)"
ok "slice γ: liaison_polling_fallback_active emitted after CHUMP_LIAISON_WEBHOOK_HEALTH_MAX_FAILS=1 failures"

# ── Slice δ: daemon offline-mode refuse + liaison_cache_offline_read (INFRA-1876) ──
# δ(a): daemon exits 0 + emits liaison_offline_mode_gated.
DELTA_LOCK="$TMP/delta.lock"
SNAP_DELTA=$(ambient_line_count)
OFFLINE_RC=0
CHUMP_GITHUB_MODE=offline \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_LIAISON_LOCK_DIR="$DELTA_LOCK" \
    bash "$LIAISON" >"$TMP/delta-liaison.log" 2>&1 || OFFLINE_RC=$?

[[ "$OFFLINE_RC" -eq 0 ]] \
    || fail "δ(a): daemon with CHUMP_GITHUB_MODE=offline should exit 0, got $OFFLINE_RC"
grep -qi "offline mode" "$TMP/delta-liaison.log" \
    || fail "δ(a): missing 'offline mode' message; log=$(cat "$TMP/delta-liaison.log")"
ambient_has_kind_after "$SNAP_DELTA" liaison_offline_mode_gated \
    || fail "δ(a): liaison_offline_mode_gated not emitted; ambient tail=$(tail -5 "$AMBIENT" 2>/dev/null)"
ok "slice δ(a): daemon refuses offline mode (exit 0 + liaison_offline_mode_gated emitted)"

# δ(b): cache_lookup_pr emits liaison_cache_offline_read when CHUMP_GITHUB_MODE=offline.
# Remove debounce marker so the event fires on the first call in this test run.
rm -f "${TMPDIR:-/tmp}/chump-liaison-offline-cache_lookup_pr.marker" 2>/dev/null || true
SNAP_DELTA2=$(ambient_line_count)
CHUMP_GITHUB_MODE=offline \
    CHUMP_CACHE_DB="$CACHE_DB" \
    bash -c "
        source '$CACHE_LIB'
        cache_lookup_pr 7777 >/dev/null 2>&1 || true
    " 2>/dev/null || true

sleep 0.2
ambient_has_kind_after "$SNAP_DELTA2" liaison_cache_offline_read \
    || fail "δ(b): liaison_cache_offline_read not emitted; ambient tail=$(tail -5 "$AMBIENT" 2>/dev/null)"
tail -n "+$((SNAP_DELTA2 + 1))" "$AMBIENT" \
    | grep '"kind":"liaison_cache_offline_read"' \
    | grep -q '"helper":"cache_lookup_pr"' \
    || fail "δ(b): liaison_cache_offline_read missing helper=cache_lookup_pr"
ok "slice δ(b): cache_lookup_pr emits liaison_cache_offline_read when CHUMP_GITHUB_MODE=offline"

# ── Final: confirm all 5 slice signals present in ambient.jsonl ──────────────
echo ""
echo "Signal summary (all 5 must be present):"
MISSING=0
for kind in webhook_cache_write liaison_cache_stale liaison_polling_fallback_active \
            liaison_offline_mode_gated liaison_cache_offline_read; do
    if grep -q "\"kind\":\"$kind\"" "$AMBIENT" 2>/dev/null; then
        printf '  \033[0;32m✓\033[0m %s\n' "$kind"
    else
        printf '  \033[0;31m✗\033[0m %s\n' "$kind"
        MISSING=$((MISSING + 1))
    fi
done
[[ "$MISSING" -eq 0 ]] || fail "final: $MISSING slice signal(s) absent from ambient.jsonl"

echo ""
echo "All INFRA-1877 Phase 2 end-to-end smoke tests passed (5/5 slice signals present)."
