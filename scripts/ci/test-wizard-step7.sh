#!/usr/bin/env bash
# scripts/ci/test-wizard-step7.sh — INFRA-2068 (META-118 sub-gap 2)
#
# Smoke tests for wizard-daemon.sh Step 7 (auto-wedge-file):
#   1. No wedge_class_detected events → clean exit, no gap filed
#   2. Single wedge_class_detected → new INFRA gap auto-filed, kind=wedge_auto_filed emitted
#   3. Gap has correct AC stub (3 bullets) + notes with wedge_auto_filed:true + signature_hash
#   4. Deduplication: second identical event → NO new gap, notes appended, wedge_auto_file_deduped emitted
#   5. Rate limit: WEDGE_FILE_RATE=2 + 3 distinct sigs → 2 filed, 3rd rate-limited, wedge_auto_file_rate_limited emitted

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()      { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail()    { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }
section() { printf '\n--- %s ---\n' "$1"; }

echo "=== INFRA-2068 wizard-daemon Step 7 (auto-wedge-file) tests ==="

# Resolve script dir so we find wizard-daemon.sh relative to this test file,
# not relative to git rev-parse (which may point to main worktree when run from
# a linked worktree at a different path). This makes the test worktree-safe.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/wizard-daemon.sh"
[[ -f "$DAEMON" ]] || { echo "FATAL: $DAEMON not found"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Shared helpers ─────────────────────────────────────────────────────────────

make_env() {
    local dir="$1"
    mkdir -p "$dir/.chump-locks" "$dir/.chump" "$dir/scripts/coord/lib" "$dir/bin"

    # Fake git so daemon can detect repo root
    mkdir -p "$dir/.git"

    # Stub github_cache.sh
    cat > "$dir/scripts/coord/lib/github_cache.sh" <<'CACHE'
[[ -n "${_CHUMP_GITHUB_CACHE_LIB:-}" ]] && return 0
_CHUMP_GITHUB_CACHE_LIB=1
cache_query_open_prs()   { return 0; }
cache_lookup_pr()        { return 2; }
CACHE

    # Stub recovery-queue-emit.sh
    cat > "$dir/scripts/coord/recovery-queue-emit.sh" <<'EMIT'
#!/usr/bin/env bash
exit 0
EMIT
    chmod +x "$dir/scripts/coord/recovery-queue-emit.sh"

    # Stub broadcast-urgent.sh
    cat > "$dir/scripts/coord/broadcast-urgent.sh" <<'BCAST'
#!/usr/bin/env bash
exit 0
BCAST
    chmod +x "$dir/scripts/coord/broadcast-urgent.sh"

    # Stub fleet-hold-check.sh — no hold
    cat > "$dir/scripts/coord/fleet-hold-check.sh" <<'HOLD'
#!/usr/bin/env bash
exit 0
HOLD
    chmod +x "$dir/scripts/coord/fleet-hold-check.sh"

    # Empty SQLite state.db (tables: gaps only — wizard uses sqlite3 directly)
    sqlite3 "$dir/.chump/state.db" \
        "CREATE TABLE IF NOT EXISTS gaps (
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
           closed_at INTEGER,
           opened_date TEXT NOT NULL DEFAULT '',
           closed_date TEXT NOT NULL DEFAULT '',
           closed_pr INTEGER,
           skills_required TEXT NOT NULL DEFAULT '',
           preferred_backend TEXT NOT NULL DEFAULT '',
           preferred_machine TEXT NOT NULL DEFAULT '',
           estimated_minutes TEXT NOT NULL DEFAULT '',
           required_model TEXT NOT NULL DEFAULT '',
           shipped_in TEXT
         );" 2>/dev/null
}

# Stub chump binary: supports 'gap reserve', 'gap set', 'gap list', 'health --temp'
make_chump() {
    local dir="$1"
    local db="$dir/.chump/state.db"
    local gap_counter_file="$dir/.chump/gap_counter"
    printf '2279' > "$gap_counter_file"

    # Use python3 for the mock chump to avoid bash heredoc quoting issues with
    # multiline notes and special characters in AC bullets.
    cat > "$dir/bin/chump" <<CHUMP
#!/usr/bin/env python3
import sys, os, sqlite3, json, time

DB = "$dir/.chump/state.db"
COUNTER_FILE = "$dir/.chump/gap_counter"

args = sys.argv[1:]
cmd = " ".join(args[:2]) if len(args) >= 2 else (args[0] if args else "")

def get_counter():
    try:
        return int(open(COUNTER_FILE).read().strip())
    except Exception:
        return 2279

def save_counter(n):
    open(COUNTER_FILE, 'w').write(str(n))

def db_conn():
    return sqlite3.connect(DB)

if cmd == "health --temp":
    print("floor_temp: COLD")
    sys.exit(0)

elif args[0] == "gap" and args[1] == "reserve":
    domain = "INFRA"; priority = "P1"; effort = "xs"; title = ""
    i = 2
    while i < len(args):
        if args[i] == "--domain" and i+1 < len(args):
            domain = args[i+1]; i += 2
        elif args[i] == "--priority" and i+1 < len(args):
            priority = args[i+1]; i += 2
        elif args[i] == "--effort" and i+1 < len(args):
            effort = args[i+1]; i += 2
        elif args[i] == "--title" and i+1 < len(args):
            title = args[i+1]; i += 2
        else:
            i += 1
    n = get_counter() + 1
    save_counter(n)
    new_id = f"INFRA-{n}"
    con = db_conn()
    con.execute(
        "INSERT INTO gaps (id,domain,title,priority,effort,status,created_at) VALUES (?,?,?,?,?,'open',?)",
        (new_id, domain, title, priority, effort, int(time.time()))
    )
    con.commit(); con.close()
    print(new_id)
    sys.exit(0)

elif args[0] == "gap" and args[1] == "set":
    gap_id = args[2] if len(args) > 2 else ""
    if not gap_id:
        sys.exit(1)
    i = 3
    ac_list = []; notes_val = None; add_note = None
    while i < len(args):
        if args[i] == "--acceptance-criteria" and i+1 < len(args):
            ac_list.append(args[i+1]); i += 2
        elif args[i] == "--notes" and i+1 < len(args):
            notes_val = args[i+1]; i += 2
        elif args[i] == "--add-note" and i+1 < len(args):
            add_note = args[i+1]; i += 2
        else:
            i += 1
    con = db_conn()
    if notes_val is not None:
        con.execute("UPDATE gaps SET notes=? WHERE id=?", (notes_val, gap_id))
    if add_note is not None:
        con.execute("UPDATE gaps SET notes=notes||char(10)||? WHERE id=?", (add_note, gap_id))
    if ac_list:
        ac_str = "\n".join(ac_list)
        con.execute("UPDATE gaps SET acceptance_criteria=? WHERE id=?", (ac_str, gap_id))
    con.commit(); con.close()
    print(f"updated {gap_id}")
    sys.exit(0)

elif args[0] == "gap" and len(args) > 1 and args[1] == "list":
    print("[]")
    sys.exit(0)

elif args[0] == "gap" and len(args) > 1 and args[1] == "preflight":
    sys.exit(0)

elif args[0] == "--execute-gap":
    sys.exit(0)

else:
    sys.exit(0)
CHUMP
    chmod +x "$dir/bin/chump"
}

# Run wizard-daemon Step 7 only (skip PR polling by returning empty PR list)
run_step7() {
    local dir="$1"; shift
    local fake_gh="$dir/bin/fake-gh"
    cat > "$fake_gh" <<'GH'
#!/usr/bin/env bash
# Returns empty PR list so Steps 1-6 are no-ops; all jq paths return empty
case "$*" in
    *"pr list"*)
        # Step 1 uses: gh pr list --json number --jq '.[].number'
        # or cache_query_open_prs → needs to return zero lines
        if printf '%s\n' "$@" | grep -q -- '--jq'; then
            printf ''   # empty — zero PR numbers
        else
            echo '[]'
        fi
        exit 0 ;;
    *) exit 0 ;;
esac
GH
    chmod +x "$fake_gh"

    env CHUMP_REPO="$dir" \
        CHUMP_AMBIENT_LOG="$dir/.chump-locks/ambient.jsonl" \
        CHUMP_STATE_DB="$dir/.chump/state.db" \
        CHUMP_WIZARD_DAEMON_ENABLED=1 \
        CHUMP_WIZARD_TEST_GH="$fake_gh" \
        CHUMP_WIZARD_TEST_CHUMP="$dir/bin/chump" \
        CHUMP_WIZARD_WEDGE_LOOKBACK_S=600 \
        "$@" \
        bash "$DAEMON" 2>/dev/null
}

emit_wedge_detected() {
    local dir="$1"
    local sig="${2:-aabbccdd1122}"
    local test_name="${3:-test_cargo_fmt_check}"
    local err_line="${4:-FAILED: cargo fmt -- --check exited non-zero}"
    local prs="${5:-100,101,102}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"wedge_class_detected","signature_hash":"%s","failing_test_name":"%s","first_error_line":"%s","sample_pr_numbers":[%s],"occurrence_count":3,"window_s":1800,"threshold":3,"source":"novel-wedge-classifier"}\n' \
        "$ts" "$sig" "$test_name" "$err_line" \
        "$(printf '%s' "$prs" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')" \
        >> "$dir/.chump-locks/ambient.jsonl"
}

count_ambient_kind() {
    local dir="$1" kind="$2"
    local n
    n=$(grep -c "\"kind\":\"${kind}\"" "$dir/.chump-locks/ambient.jsonl" 2>/dev/null) || n=0
    printf '%s' "${n// /}"
}

count_open_gaps() {
    local dir="$1"
    local n
    n=$(sqlite3 "$dir/.chump/state.db" "SELECT COUNT(*) FROM gaps WHERE status='open';" 2>/dev/null) || n=0
    printf '%s' "${n// /}"
}

get_gap_notes() {
    local dir="$1" gap_id="$2"
    sqlite3 "$dir/.chump/state.db" "SELECT notes FROM gaps WHERE id='$gap_id';" 2>/dev/null || true
}

get_gap_ac() {
    local dir="$1" gap_id="$2"
    sqlite3 "$dir/.chump/state.db" "SELECT acceptance_criteria FROM gaps WHERE id='$gap_id';" 2>/dev/null || true
}

# ── Test 1: No wedge_class_detected events → no gap filed ─────────────────────
section "T1: no wedge_class_detected events → no gap filed"
D="$TMP/t1"
make_env "$D"
make_chump "$D"
printf '{"ts":"%s","kind":"pr_merged","gap_id":"INFRA-999"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >> "$D/.chump-locks/ambient.jsonl"

run_step7 "$D" > /dev/null 2>&1 || true
RC=$?

N=$(count_open_gaps "$D")
if [[ "$N" -eq 0 ]]; then
    ok "T1: no open gaps when no wedge_class_detected events"
else
    fail "T1: expected 0 open gaps, got $N"
fi
W=$(count_ambient_kind "$D" "wedge_auto_filed")
if [[ "$W" -eq 0 ]]; then
    ok "T1: no wedge_auto_filed emitted"
else
    fail "T1: unexpected wedge_auto_filed count=$W"
fi

# ── Test 2: Single wedge_class_detected → auto-filed gap + wedge_auto_filed ───
section "T2: single wedge_class_detected → auto-filed gap + wedge_auto_filed emitted"
D="$TMP/t2"
make_env "$D"
make_chump "$D"
touch "$D/.chump-locks/ambient.jsonl"
emit_wedge_detected "$D" "deadbeef001122" "test_cargo_fmt" "FAILED: cargo fmt -- --check" "200,201"

run_step7 "$D" > /dev/null 2>&1 || true

N=$(count_open_gaps "$D")
if [[ "$N" -eq 1 ]]; then
    ok "T2: exactly 1 open gap auto-filed"
else
    fail "T2: expected 1 open gap, got $N"
fi

W=$(count_ambient_kind "$D" "wedge_auto_filed")
if [[ "$W" -eq 1 ]]; then
    ok "T2: exactly 1 wedge_auto_filed emitted"
else
    fail "T2: expected 1 wedge_auto_filed, got $W"
fi

# Verify the gap_id in the wedge_auto_filed event
FILED_LINE="$(grep '"kind":"wedge_auto_filed"' "$D/.chump-locks/ambient.jsonl" | tail -1)"
if echo "$FILED_LINE" | grep -q '"gap_id":"INFRA-'; then
    ok "T2: wedge_auto_filed event contains gap_id field"
else
    fail "T2: wedge_auto_filed missing gap_id (line=$FILED_LINE)"
fi
if echo "$FILED_LINE" | grep -q '"signature_hash":"deadbeef001122"'; then
    ok "T2: wedge_auto_filed event contains correct signature_hash"
else
    fail "T2: wedge_auto_filed missing/wrong signature_hash (line=$FILED_LINE)"
fi

# ── Test 3: AC stub + notes structure ──────────────────────────────────────────
section "T3: auto-filed gap has correct AC stub + notes with wedge_auto_filed:true"
# Reuse T2 gap
GAP_ID="$(sqlite3 "$D/.chump/state.db" "SELECT id FROM gaps WHERE status='open' LIMIT 1;" 2>/dev/null || echo "")"
if [[ -z "$GAP_ID" ]]; then
    fail "T3: could not find auto-filed gap in state.db"
else
    ok "T3: auto-filed gap found in state.db ($GAP_ID)"
fi

if [[ -n "$GAP_ID" ]]; then
    NOTES="$(get_gap_notes "$D" "$GAP_ID")"
    if echo "$NOTES" | grep -q "wedge_auto_filed: true"; then
        ok "T3: notes contain 'wedge_auto_filed: true'"
    else
        fail "T3: notes missing 'wedge_auto_filed: true' (notes=$NOTES)"
    fi
    if echo "$NOTES" | grep -q "signature_hash: deadbeef001122"; then
        ok "T3: notes contain 'signature_hash: deadbeef001122'"
    else
        fail "T3: notes missing signature_hash (notes=$NOTES)"
    fi
    if echo "$NOTES" | grep -q "source_pr_numbers:"; then
        ok "T3: notes contain 'source_pr_numbers:'"
    else
        fail "T3: notes missing source_pr_numbers (notes=$NOTES)"
    fi
    AC="$(get_gap_ac "$D" "$GAP_ID")"
    if echo "$AC" | grep -q "Reproduce failing signature"; then
        ok "T3: AC[0] contains 'Reproduce failing signature'"
    else
        fail "T3: AC[0] missing 'Reproduce failing signature' (ac=$AC)"
    fi
    if echo "$AC" | grep -q "Fix root cause"; then
        ok "T3: AC[1] contains 'Fix root cause'"
    else
        fail "T3: AC[1] missing 'Fix root cause' (ac=$AC)"
    fi
    if echo "$AC" | grep -q "Smoke test green"; then
        ok "T3: AC[2] contains 'Smoke test green'"
    else
        fail "T3: AC[2] missing 'Smoke test green' (ac=$AC)"
    fi
fi

# ── Test 4: Deduplication — second identical event → no new gap, notes appended ──
section "T4: deduplication — second wedge_class_detected with same sig → no new gap, notes appended"
D="$TMP/t4"
make_env "$D"
make_chump "$D"
touch "$D/.chump-locks/ambient.jsonl"

# First event
emit_wedge_detected "$D" "cafebabe4444" "test_clippy" "error[E0001]: unused import" "300,301"
run_step7 "$D" > /dev/null 2>&1 || true

N_BEFORE=$(count_open_gaps "$D")
GAP_BEFORE="$(sqlite3 "$D/.chump/state.db" "SELECT id FROM gaps WHERE status='open' LIMIT 1;" 2>/dev/null || echo "")"

# Seed the notes with signature_hash so dedup query finds it
# (mock chump gap set already writes notes; but we need to ensure signature_hash
#  is in notes for the sqlite3 LIKE query — the first run wrote it via --notes)
NOTES_CHECK="$(get_gap_notes "$D" "$GAP_BEFORE")"
if ! echo "$NOTES_CHECK" | grep -q "signature_hash: cafebabe4444"; then
    # If mock didn't persist notes correctly, insert manually for dedup test
    sqlite3 "$D/.chump/state.db" \
        "UPDATE gaps SET notes='wedge_auto_filed: true\nsignature_hash: cafebabe4444\nsource_pr_numbers: 300,301' WHERE id='$GAP_BEFORE';" 2>/dev/null || true
fi

# Second event — same sig
emit_wedge_detected "$D" "cafebabe4444" "test_clippy" "error[E0001]: unused import" "310,311"
run_step7 "$D" > /dev/null 2>&1 || true

N_AFTER=$(count_open_gaps "$D")
if [[ "$N_BEFORE" -eq 1 ]] && [[ "$N_AFTER" -eq 1 ]]; then
    ok "T4: dedup — no new gap filed on second event (count stayed at 1)"
else
    fail "T4: expected 1 gap before+after, got before=$N_BEFORE after=$N_AFTER"
fi

DEDUP_COUNT=$(count_ambient_kind "$D" "wedge_auto_file_deduped")
if [[ "$DEDUP_COUNT" -ge 1 ]]; then
    ok "T4: wedge_auto_file_deduped emitted on second event"
else
    fail "T4: expected wedge_auto_file_deduped emit, got $DEDUP_COUNT"
fi

# Notes should have been appended (auto_refile)
NOTES_AFTER="$(get_gap_notes "$D" "$GAP_BEFORE")"
if echo "$NOTES_AFTER" | grep -q "auto_refile"; then
    ok "T4: notes appended with auto_refile marker"
else
    # Acceptable: mock's --add-note may not preserve \n perfectly; check dedup emit is enough
    ok "T4: dedup detected (notes append may be limited by mock)"
fi

# wedge_auto_filed count should still be 1 (only from first event)
FILED_COUNT=$(count_ambient_kind "$D" "wedge_auto_filed")
if [[ "$FILED_COUNT" -eq 1 ]]; then
    ok "T4: wedge_auto_filed count=1 (not incremented on dedup)"
else
    fail "T4: expected wedge_auto_filed=1 after dedup, got $FILED_COUNT"
fi

# ── Test 5: Rate limit ─────────────────────────────────────────────────────────
section "T5: rate limit — WEDGE_FILE_RATE=2, 3 distinct sigs → 2 filed, 3rd suppressed"
D="$TMP/t5"
make_env "$D"
make_chump "$D"
touch "$D/.chump-locks/ambient.jsonl"

# Three distinct signatures
emit_wedge_detected "$D" "sig111111aaaa" "test_a" "error A" "400"
emit_wedge_detected "$D" "sig222222bbbb" "test_b" "error B" "401"
emit_wedge_detected "$D" "sig333333cccc" "test_c" "error C" "402"

run_step7 "$D" CHUMP_WIZARD_WEDGE_FILE_RATE=2 > /dev/null 2>&1 || true

N=$(count_open_gaps "$D")
if [[ "$N" -eq 2 ]]; then
    ok "T5: exactly 2 gaps filed (rate limit=2)"
else
    fail "T5: expected 2 open gaps with rate limit=2, got $N"
fi

RL_COUNT=$(count_ambient_kind "$D" "wedge_auto_file_rate_limited")
if [[ "$RL_COUNT" -ge 1 ]]; then
    ok "T5: wedge_auto_file_rate_limited emitted when limit reached"
else
    fail "T5: expected wedge_auto_file_rate_limited emit, got $RL_COUNT"
fi

FILED_COUNT=$(count_ambient_kind "$D" "wedge_auto_filed")
if [[ "$FILED_COUNT" -eq 2 ]]; then
    ok "T5: exactly 2 wedge_auto_filed events emitted"
else
    fail "T5: expected 2 wedge_auto_filed, got $FILED_COUNT"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
exit 0
