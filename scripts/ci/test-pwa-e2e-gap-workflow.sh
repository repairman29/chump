#!/usr/bin/env bash
# test-pwa-e2e-gap-workflow.sh — CREDIBLE-020 tests.
#
# Verifies the PWA gap-work endpoint end-to-end:
#   (a) Source audit: spawn_gap_workflow exists and emits all 4 phases
#   (b) Source audit: all 3 workflow steps are invoked (claim/execute-gap/ship)
#   (c) Source audit: Rust unit tests (credible020_*) are present
#   (d) Rust unit test run: spawn_gap_workflow stub — 4 phases + status=done
#   (e) Live HTTP: POST /api/gap/work/TEST-001 → poll /api/gap/status/TEST-001
#       until status='done' (skipped if binary unavailable or SKIP_LIVE=1)
#
# CI gate: required before any PR modifying spawn_gap_workflow in web_server.rs
#
# Run: bash scripts/ci/test-pwa-e2e-gap-workflow.sh
# Run (with live HTTP): CHUMP_BIN=${CARGO_TARGET_DIR:-./target}/debug/chump bash scripts/ci/test-pwa-e2e-gap-workflow.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WS="$REPO_ROOT/src/web_server.rs"

echo "=== CREDIBLE-020 PWA e2e gap workflow tests ==="
echo

# ── (a) Source audit: spawn_gap_workflow exists and emits 4 phases ────────────
echo "--- Tests 1-5: source audit — spawn_gap_workflow phases ---"

if grep -q 'async fn spawn_gap_workflow(' "$WS" 2>/dev/null; then
    ok "Test 1: spawn_gap_workflow defined in web_server.rs"
else
    fail "Test 1: spawn_gap_workflow missing from web_server.rs"
fi

for phase in preflight claim "execute-gap" ship; do
    if grep -q "\"$phase\"" "$WS" 2>/dev/null; then
        ok "Test: emit_ambient_event records phase '$phase'"
    else
        fail "Test: emit_ambient_event NOT found for phase '$phase' in web_server.rs"
    fi
done

# ── (b) Source audit: workflow steps invoked ──────────────────────────────────
echo "--- Tests 6-8: workflow steps invoked ---"

for pattern in '"claim"' '"--execute-gap"' '"ship"'; do
    if grep -q "$pattern" "$WS" 2>/dev/null; then
        ok "Test: spawn_gap_workflow invokes $pattern"
    else
        fail "Test: spawn_gap_workflow does NOT invoke $pattern in web_server.rs"
    fi
done

# ── (c) Source audit: Rust unit tests present ─────────────────────────────────
echo "--- Test 9: Rust unit tests for workflow_e2e_tests ---"

if grep -q 'credible020_' "$WS" 2>/dev/null; then
    _count=$(grep -c 'fn credible020_' "$WS" 2>/dev/null || echo 0)
    if [[ "${_count:-0}" -ge 2 ]]; then
        ok "Test 9: workflow_e2e_tests has ${_count} credible020_* tests"
    else
        fail "Test 9: workflow_e2e_tests has only ${_count} test(s) — expected ≥ 2"
    fi
else
    fail "Test 9: credible020_* tests missing from web_server.rs"
fi

# ── (d) Rust unit test run ────────────────────────────────────────────────────
echo "--- Test 10: cargo test web_server::workflow_e2e_tests ---"

if command -v cargo >/dev/null 2>&1; then
    _out=$(cargo test --manifest-path "$REPO_ROOT/Cargo.toml" \
        --bin chump \
        -- web_server::workflow_e2e_tests \
        --test-threads=1 \
        2>&1)
    if echo "$_out" | grep -q 'test result: ok'; then
        _passed=$(echo "$_out" | grep 'test result: ok' | grep -oE '[0-9]+ passed' | head -1)
        ok "Test 10: cargo test workflow_e2e_tests — $_passed"
    else
        fail "Test 10: cargo test workflow_e2e_tests failed"
        echo "$_out" | tail -20 >&2
    fi
else
    ok "Test 10: cargo not available — source checks passed (skipping Rust test run)"
fi

# ── (e) Live HTTP integration ─────────────────────────────────────────────────
echo "--- Tests 11-N: live HTTP integration (POST /api/gap/work → poll status) ---"

REAL_BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
SKIP_LIVE="${SKIP_LIVE:-0}"

if [[ "$SKIP_LIVE" == "1" ]]; then
    ok "Test (live): SKIP_LIVE=1 — skipping live HTTP test"
elif [[ ! -x "$REAL_BIN" ]]; then
    ok "Test (live): binary not found at $REAL_BIN — skipping (run after cargo build)"
else
    # Create temp workspace: gap store + stub binary + ambient log
    TMP="$(mktemp -d)"
    _WEB_PID=""
    trap 'kill "${_WEB_PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT

    mkdir -p "$TMP/.chump" "$TMP/.chump-locks"
    AMBIENT="$TMP/ambient.jsonl"

    # Fixture gap TEST-001 in an open state
    sqlite3 "$TMP/.chump/state.db" "
    CREATE TABLE gaps (
        id TEXT PRIMARY KEY,
        domain TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        priority TEXT NOT NULL DEFAULT '',
        effort TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'open',
        acceptance_criteria TEXT NOT NULL DEFAULT '',
        depends_on TEXT NOT NULL DEFAULT '',
        notes TEXT NOT NULL DEFAULT '',
        source_doc TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL DEFAULT 0,
        closed_at INTEGER
    );
    CREATE TABLE IF NOT EXISTS gap_counters (
        domain TEXT PRIMARY KEY,
        next_num INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE IF NOT EXISTS leases (
        session_id TEXT PRIMARY KEY,
        gap_id TEXT NOT NULL,
        worktree TEXT NOT NULL DEFAULT '',
        expires_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS intents (
        ts INTEGER NOT NULL,
        session_id TEXT NOT NULL,
        gap_id TEXT NOT NULL,
        files TEXT NOT NULL DEFAULT ''
    );
    INSERT INTO gaps (id, domain, title, status, priority, effort)
    VALUES ('TEST-001', 'TEST', 'CREDIBLE-020 live fixture gap', 'open', 'P1', 's');
    "

    # Stub chump binary: claim/execute-gap → noop; ship → update DB
    STUB_BIN="$TMP/stub-chump"
    cat > "$STUB_BIN" <<STUB
#!/usr/bin/env bash
REPO="\${CHUMP_REPO:-}"
case "\$1" in
  claim) exit 0 ;;
  --execute-gap) exit 0 ;;
  gap)
    case "\$2" in
      ship)
        # Retry on SQLite busy/lock — server holds state.db open concurrently.
        for _attempt in 1 2 3 4 5; do
          if sqlite3 -cmd '.timeout 5000' "\$REPO/.chump/state.db" \
              "UPDATE gaps SET status='done' WHERE id='\$3'" 2>/dev/null; then
            exit 0
          fi
          sleep 0.5
        done
        # Final attempt with stderr visible for diagnostic
        sqlite3 -cmd '.timeout 5000' "\$REPO/.chump/state.db" \
            "UPDATE gaps SET status='done' WHERE id='\$3'" >&2
        exit 0
        ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
STUB
    chmod +x "$STUB_BIN"

    # Pick port (3849 — unlikely to conflict with Chump default 3000 or e2e port 3847)
    PORT=3849

    # Start server: CHUMP_BIN → stub so spawn_gap_workflow uses it; no auth (CHUMP_WEB_TOKEN="")
    # CREDIBLE-023 added CSRF + rate-limit guards by default. CSRF disabled
    # here so the test can POST without holding a token. Rate-limit kept at
    # default (10/60s) since one POST is well under cap. Note: setting
    # CHUMP_GAP_RATE_LIMIT=0 does NOT disable — it sets max=0 → always-deny.
    CHUMP_BIN="$STUB_BIN" \
    CHUMP_REPO="$TMP" \
    CHUMP_WEB_TOKEN="" \
    CHUMP_CSRF_ENABLED=0 \
    CHUMP_AMBIENT_IN_PROMPT="$AMBIENT" \
        "$REAL_BIN" --web --port "$PORT" >"$TMP/server.log" 2>&1 &
    _WEB_PID=$!

    # Wait for server health (max ~7.5s, 15 × 0.5s)
    _ready=0
    for i in $(seq 1 15); do
        if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
            _ready=1
            break
        fi
        sleep 0.5
    done

    if [[ "$_ready" -eq 0 ]]; then
        fail "Test 11 (live): server did not start within 7.5s"
        tail -20 "$TMP/server.log" >&2
    else
        ok "Test 11 (live): chump --web started and /api/health returned 200"

        # POST /api/gap/work/TEST-001 — triggers async workflow
        _resp=$(curl -sf -X POST \
            -H "Content-Type: application/json" \
            "http://127.0.0.1:$PORT/api/gap/work/TEST-001" 2>&1 || echo "CURL_FAIL")

        if echo "$_resp" | grep -q '"started"'; then
            ok "Test 12 (live): POST /api/gap/work/TEST-001 returned status=started"
        else
            fail "Test 12 (live): POST /api/gap/work/TEST-001 unexpected response: $_resp"
        fi

        # Poll /api/gap/status/TEST-001 until status='done' (max 60s, 60 × 1s).
        # 20s wasn't enough — Test 13 still flaked on #1570/#1605 under
        # concurrent CI load. The stub now retries on SQLite-busy and the
        # poll budget is 60s. Underlying logic is correct; this just rides
        # out lock contention between the stub UPDATE and gap_store reads.
        _done=0
        for i in $(seq 1 60); do
            _st=$(curl -sf \
                "http://127.0.0.1:$PORT/api/gap/status/TEST-001" 2>/dev/null || echo "")
            if echo "$_st" | grep -q '"done"'; then
                _done=1
                break
            fi
            sleep 1
        done

        if [[ "$_done" -eq 1 ]]; then
            ok "Test 13 (live): gap status reached 'done' within 60s"
        else
            _last=$(curl -sf "http://127.0.0.1:$PORT/api/gap/status/TEST-001" 2>/dev/null || echo "(unreachable)")
            fail "Test 13 (live): gap status did not reach 'done' within 60s — last: $_last"
            # Diagnostic dump on Test 13 failure (stub never updated DB?).
            echo "  [diag] sqlite3 available: $(command -v sqlite3 || echo NO)" >&2
            echo "  [diag] state.db direct query:" >&2
            sqlite3 "$TMP/.chump/state.db" "SELECT id,status FROM gaps;" 2>&1 >&2 || true
            echo "  [diag] stub script exists: $(test -x "$STUB_BIN" && echo YES || echo NO)" >&2
            echo "  [diag] last 30 server log lines:" >&2
            tail -30 "$TMP/server.log" 2>&1 >&2 || true
        fi

        # Verify 4 phases in ambient.jsonl
        if [[ -f "$AMBIENT" ]]; then
            for phase in preflight claim execute-gap ship; do
                if grep -q "\"$phase\"" "$AMBIENT" 2>/dev/null; then
                    ok "Test (live): phase '$phase' recorded in ambient.jsonl"
                else
                    fail "Test (live): phase '$phase' NOT found in ambient.jsonl"
                fi
            done
        else
            fail "Test (live): ambient.jsonl not created — emit_ambient_event not triggered?"
        fi
    fi

    # Clean up server
    kill "${_WEB_PID:-}" 2>/dev/null || true
    wait "${_WEB_PID:-}" 2>/dev/null || true
    _WEB_PID=""
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
