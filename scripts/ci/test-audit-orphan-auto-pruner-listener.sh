#!/usr/bin/env bash
# test-audit-orphan-auto-pruner-listener.sh — INFRA-5121
#
# Smoke-tests for scripts/coord/audit-orphan-auto-pruner-listener.sh:
#
#   1. A kind=audit_orphan_landed event is recorded into the orphan log
#   2. kind=audit_orphan_recorded is emitted with required fields
#   3. kind=audit_orphan_rescue_triggered is emitted (rescue daemon invoked)
#   4. The bookmark advances so a re-run does not double-process the event
#   5. --dry-run does not write the orphan log, does not emit, does not
#      advance the bookmark, and does not invoke the rescue daemon
#   6. Non-matching events (other kinds) are ignored

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LISTENER="$REPO_ROOT/scripts/coord/audit-orphan-auto-pruner-listener.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$LISTENER" ]] || fail "listener not found at $LISTENER"
[[ -x "$LISTENER" ]] || fail "listener is not executable"

TMP="$(mktemp -d -t test-audit-orphan-pruner.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

FAKE_AMBIENT="$TMP/ambient.jsonl"
FAKE_STATE="$TMP/state.txt"
FAKE_ORPHAN_LOG="$TMP/orphan-log.jsonl"
FAKE_RESCUE="$TMP/fake-rescue.sh"

cat > "$FAKE_RESCUE" <<'EOF'
#!/usr/bin/env bash
echo "rescue-invoked" >> "$FAKE_RESCUE_MARKER"
EOF
chmod +x "$FAKE_RESCUE"

touch "$FAKE_AMBIENT"

_listener_env() {
    env \
        CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
        CHUMP_AUDIT_ORPHAN_PRUNER_STATE="$FAKE_STATE" \
        CHUMP_AUDIT_ORPHAN_PRUNER_LOG="$FAKE_ORPHAN_LOG" \
        CHUMP_AUDIT_ORPHAN_RESCUE_BIN="$FAKE_RESCUE" \
        FAKE_RESCUE_MARKER="$TMP/rescue-marker" \
        "$@"
}

# ── 1: non-matching event is ignored, bookmark still advances ────────────────
printf '{"ts":"2026-09-06T00:00:00Z","kind":"unrelated_event"}\n' >> "$FAKE_AMBIENT"
_listener_env bash "$LISTENER" >/dev/null 2>&1 || true
[[ ! -f "$FAKE_ORPHAN_LOG" ]] && pass "non-matching event does not create orphan log" \
    || fail "non-matching event unexpectedly created orphan log"
[[ -f "$FAKE_STATE" ]] && pass "bookmark advances even with no matching events" \
    || fail "bookmark file not created after tick"

# ── 2: matching event is recorded + emitted + rescue triggered ───────────────
printf '{"ts":"2026-09-06T00:01:00Z","kind":"audit_orphan_landed","entry":"CHUMP_FAKE_ORPHAN","file":"scripts/ci/event-registry-reserved.txt"}\n' >> "$FAKE_AMBIENT"
_listener_env bash "$LISTENER" >/dev/null 2>&1 || true

# Rescue is launched backgrounded (&) inside the listener — give it a beat.
for _ in 1 2 3 4 5; do
    [[ -f "$TMP/rescue-marker" ]] && break
    sleep 0.2
done

[[ -f "$FAKE_ORPHAN_LOG" ]] && grep -q "CHUMP_FAKE_ORPHAN" "$FAKE_ORPHAN_LOG" \
    && pass "orphan recorded into orphan log with entry name" \
    || fail "orphan log missing or does not contain CHUMP_FAKE_ORPHAN"

grep -q '"kind":"audit_orphan_recorded"' "$FAKE_AMBIENT" \
    && pass "kind=audit_orphan_recorded emitted" \
    || fail "kind=audit_orphan_recorded not found in ambient log"

grep -q '"kind":"audit_orphan_rescue_triggered"' "$FAKE_AMBIENT" \
    && pass "kind=audit_orphan_rescue_triggered emitted" \
    || fail "kind=audit_orphan_rescue_triggered not found in ambient log"

[[ -f "$TMP/rescue-marker" ]] \
    && pass "rescue daemon was invoked (within test tick — satisfies 5-min AC by immediacy)" \
    || fail "rescue daemon was never invoked"

# ── 3: re-run does not double-process (bookmark advanced) ────────────────────
BEFORE_LINES="$(wc -l < "$FAKE_ORPHAN_LOG" | xargs)"
_listener_env bash "$LISTENER" >/dev/null 2>&1 || true
AFTER_LINES="$(wc -l < "$FAKE_ORPHAN_LOG" | xargs)"
[[ "$BEFORE_LINES" == "$AFTER_LINES" ]] \
    && pass "re-run does not double-record the same orphan" \
    || fail "re-run re-processed an already-bookmarked event ($BEFORE_LINES -> $AFTER_LINES)"

# ── 4: --dry-run makes no durable changes ─────────────────────────────────────
DRY_AMBIENT="$TMP/ambient-dry.jsonl"
DRY_STATE="$TMP/state-dry.txt"
DRY_LOG="$TMP/orphan-log-dry.jsonl"
DRY_MARKER="$TMP/rescue-marker-dry"
printf '{"ts":"2026-09-06T00:02:00Z","kind":"audit_orphan_landed","entry":"CHUMP_DRY_ORPHAN","file":"scripts/ci/event-registry-reserved.txt"}\n' > "$DRY_AMBIENT"

env CHUMP_AMBIENT_LOG="$DRY_AMBIENT" \
    CHUMP_AUDIT_ORPHAN_PRUNER_STATE="$DRY_STATE" \
    CHUMP_AUDIT_ORPHAN_PRUNER_LOG="$DRY_LOG" \
    CHUMP_AUDIT_ORPHAN_RESCUE_BIN="$FAKE_RESCUE" \
    FAKE_RESCUE_MARKER="$DRY_MARKER" \
    bash "$LISTENER" --dry-run >/dev/null 2>&1 || true

[[ ! -f "$DRY_LOG" ]] && pass "--dry-run does not write orphan log" \
    || fail "--dry-run unexpectedly wrote orphan log"
[[ ! -f "$DRY_STATE" ]] && pass "--dry-run does not advance bookmark" \
    || fail "--dry-run unexpectedly wrote bookmark"
grep -q '"kind":"audit_orphan_recorded"' "$DRY_AMBIENT" \
    && fail "--dry-run unexpectedly emitted audit_orphan_recorded" \
    || pass "--dry-run does not emit audit_orphan_recorded"
[[ ! -f "$DRY_MARKER" ]] && pass "--dry-run does not invoke rescue daemon" \
    || fail "--dry-run unexpectedly invoked rescue daemon"

echo "All INFRA-5121 audit-orphan-auto-pruner-listener checks passed."
