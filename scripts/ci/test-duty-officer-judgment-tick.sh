#!/usr/bin/env bash
# scripts/ci/test-duty-officer-judgment-tick.sh — RESILIENT-1497 smoke test for
# the free Opus peer's cadenced judgment tick (duty-officer-loop.sh
# judgment-tick), lib/peer-memory.sh, and lib/peer-guardrails.sh.
#
# Self-contained: stubs `claude` on PATH so no real model is ever invoked,
# writes to a throwaway chump_memory.db, and asserts on exit codes + ambient
# emits + sqlite rows. Runs offline in well under a second.

set -uo pipefail   # NOT -e: we check exit codes explicitly

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOOP="$REPO_ROOT/scripts/coord/duty-officer-loop.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

_check() { # _check <label> <expected_exit> <actual_exit>
    if [[ "$2" == "$3" ]]; then printf '  ok   %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
    else printf '  FAIL %s (expected exit %s, got %s)\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
_emitted() { # _emitted <label> <ambient_file> <grep-ERE>
    if grep -qE "$3" "$2" 2>/dev/null; then printf '  ok   %s\n' "$1"; PASS=$((PASS+1))
    else printf '  FAIL %s (no match /%s/ in %s)\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

[[ -x "$LOOP" ]] || { printf 'FATAL: %s not found or not executable\n' "$LOOP" >&2; exit 1; }

echo "[test-judgment-tick] CHUMP_PEER_EXECUTE unset/0 — dry-run, never invokes claude"
A="$TMP/dry.jsonl"; : > "$A"
DB="$TMP/dry-memory.db"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_MEMORY_DB="$DB" bash "$LOOP" judgment-tick >/dev/null 2>&1 || rc=$?
_check "dry-run exits 0" 0 "$rc"
_emitted "dry-run emits verdict:skipped" "$A" '"kind":"duty_officer_action".*"signal":"peer_judgment".*"verdict":"skipped"'

echo "[test-judgment-tick] claude_bin missing — skips gracefully, never errors"
A="$TMP/missing.jsonl"; : > "$A"
DB="$TMP/missing-memory.db"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_MEMORY_DB="$DB" CHUMP_PEER_EXECUTE=1 \
    CHUMP_PEER_CLAUDE_BIN="/no/such/claude-binary-xyz" \
    bash "$LOOP" judgment-tick >/dev/null 2>&1 || rc=$?
_check "missing claude_bin exits 0" 0 "$rc"
_emitted "missing claude_bin emits verdict:skipped" "$A" '"kind":"duty_officer_action".*"signal":"peer_judgment".*"verdict":"skipped"'

echo "[test-judgment-tick] stubbed claude success — healed + episode written to chump_memory.db"
STUB_DIR="$TMP/bin"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/fake-claude-ok" <<'EOF'
#!/usr/bin/env bash
echo "ok, judged and acted"
exit 0
EOF
chmod +x "$STUB_DIR/fake-claude-ok"
A="$TMP/ok.jsonl"; : > "$A"
DB="$TMP/ok-memory.db"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_MEMORY_DB="$DB" CHUMP_PEER_EXECUTE=1 \
    CHUMP_PEER_CLAUDE_BIN="$STUB_DIR/fake-claude-ok" \
    bash "$LOOP" judgment-tick >/dev/null 2>&1 || rc=$?
_check "stubbed success exits 0" 0 "$rc"
_emitted "stubbed success emits verdict:healed" "$A" '"kind":"duty_officer_action".*"signal":"peer_judgment".*"tier":1,"verdict":"healed"'
if command -v sqlite3 >/dev/null 2>&1; then
    n="$(sqlite3 "$DB" "SELECT COUNT(*) FROM chump_episodes WHERE tags LIKE '%peer%';" 2>/dev/null || echo 0)"
    if [[ "${n:-0}" -ge 1 ]]; then printf '  ok   episode written to chump_memory.db\n'; PASS=$((PASS+1))
    else printf '  FAIL no peer episode row in chump_memory.db\n'; FAIL=$((FAIL+1)); fi
else
    printf '  skip sqlite3 not available\n'
fi

echo "[test-judgment-tick] stubbed claude rate-limited output — rate_limited verdict, no error"
cat > "$STUB_DIR/fake-claude-ratelimit" <<'EOF'
#!/usr/bin/env bash
echo "Error: rate limit exceeded, please retry later"
exit 1
EOF
chmod +x "$STUB_DIR/fake-claude-ratelimit"
A="$TMP/rl.jsonl"; : > "$A"
DB="$TMP/rl-memory.db"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_MEMORY_DB="$DB" CHUMP_PEER_EXECUTE=1 \
    CHUMP_PEER_CLAUDE_BIN="$STUB_DIR/fake-claude-ratelimit" \
    bash "$LOOP" judgment-tick >/dev/null 2>&1 || rc=$?
_check "rate-limited tick still exits 0" 0 "$rc"
_emitted "rate-limited emits verdict:rate_limited" "$A" '"kind":"duty_officer_action".*"signal":"peer_judgment".*"verdict":"rate_limited"'

echo "[test-judgment-tick] lib/peer-guardrails.sh — gated action categories"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/coord/lib/peer-guardrails.sh"
_gate_check() { # _gate_check <label> <text> <expect_gated:0|1>
    local rc=1
    peer_guardrail_is_gated "$2" && rc=0
    _check "$1" "$3" "$rc"
}
_gate_check "repo visibility flip is gated"       "gh repo edit --visibility public"            0
_gate_check "credential rotation is gated"        "rotate the API key for prod"                 0
_gate_check "rm -rf is gated"                     "rm -rf /some/path"                           0
_gate_check "outward tweet is gated"               "tweet the release announcement"              0
_gate_check "filing a gap is NOT gated"            "chump gap reserve --domain INFRA --title x"  1
_gate_check "dispatching work is NOT gated"        "chump dispatch INFRA-1 --backend headless"   1

echo "[test-judgment-tick] lib/peer-guardrails.sh — surface emits ambient + does not execute"
A="$TMP/gated.jsonl"; : > "$A"
NOTIFIED="$TMP/notified.txt"; : > "$NOTIFIED"
CHUMP_AMBIENT_LOG="$A" CHUMP_NOTIFY_CMD_OVERRIDE_UNUSED=1 \
    bash -c "source '$REPO_ROOT/scripts/coord/lib/peer-guardrails.sh'; CHUMP_AMBIENT_LOG='$A' peer_guardrail_surface 'flip repo to public' 'repo_visibility_flip'" \
    >/dev/null 2>&1
_emitted "guardrail surface emits peer_gated_action_surfaced" "$A" '"kind":"peer_gated_action_surfaced".*"signal":"repo_visibility_flip"'

echo "[test-judgment-tick] lib/peer-memory.sh — init is idempotent and schema matches chump-mcp-memory"
DB2="$TMP/schema-check.db"
# shellcheck disable=SC1091
( CHUMP_MEMORY_DB="$DB2" source "$REPO_ROOT/scripts/coord/lib/peer-memory.sh"; CHUMP_MEMORY_DB="$DB2" peer_memory_init; CHUMP_MEMORY_DB="$DB2" peer_memory_init ) >/dev/null 2>&1
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$DB2" ]]; then
    tables="$(sqlite3 "$DB2" ".tables" 2>/dev/null)"
    if [[ "$tables" == *chump_memory* && "$tables" == *chump_episodes* ]]; then
        printf '  ok   schema has chump_memory + chump_episodes tables\n'; PASS=$((PASS+1))
    else
        printf '  FAIL schema missing expected tables (got: %s)\n' "$tables"; FAIL=$((FAIL+1))
    fi
else
    printf '  skip sqlite3 not available\n'
fi

echo
printf '[test-judgment-tick] %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "[test-judgment-tick] PASS"
