#!/usr/bin/env bash
# test-gap-opened-date-coverage.sh — INFRA-1611
#
# Validates opened_date coverage for the P0 aging census:
#  - `chump gap reserve` stamps opened_date at reservation time (functional,
#    isolated fixture repo)
#  - the tracked .chump/state.sql dump has no open P0/P1 gap with a missing
#    or placeholder opened_date (real-registry gate — this is the data the
#    aging census in CLAUDE.md Mission Driver §4 relies on)

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-1611 gap opened_date coverage test ==="
echo

# 1. `gap reserve` code path stamps opened_date.
if grep -q "opened_date" "$REPO_ROOT/crates/chump-gap-store/src/lib.rs" \
    && grep -A3 "INSERT INTO gaps(id,domain,title,priority,effort,status,created_at,opened_date)" \
        "$REPO_ROOT/crates/chump-gap-store/src/lib.rs" | grep -q "opened_date"; then
    ok "reserve_with_external INSERT stamps opened_date"
else
    fail "reserve_with_external INSERT does not stamp opened_date"
fi

# 2. Backfill script exists (git-log-derived opened_date for pre-existing gaps).
if [[ -x "$REPO_ROOT/scripts/dev/backfill-opened-dates.sh" ]]; then
    ok "backfill-opened-dates.sh exists and is executable"
else
    fail "scripts/dev/backfill-opened-dates.sh missing or not executable"
fi

# 3. Functional test: build binary, reserve a P0 gap in an isolated fixture
#    repo, assert opened_date is non-empty and matches today's date.
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    export CHUMP_REPO="$TMP"
    export CHUMP_HOME="$TMP"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_VERIFY=0

    GAP_ID=$("$BIN" gap reserve --domain INFRA --priority P0 --effort xs \
        --title "opened-date-fixture-p0" --skip-obs-acs --quiet --json 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

    if [[ -n "$GAP_ID" ]]; then
        TODAY="$(date -u +%Y-%m-%d)"
        SHOW_JSON=$("$BIN" gap show "$GAP_ID" --json 2>/dev/null || true)
        OPENED=$(echo "$SHOW_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('opened_date',''))" 2>/dev/null || true)
        if [[ "$OPENED" == "$TODAY" ]]; then
            ok "reserved P0 gap $GAP_ID has opened_date=$TODAY"
        else
            fail "reserved P0 gap $GAP_ID has opened_date='$OPENED' (expected $TODAY)"
        fi
    else
        fail "gap reserve did not return a usable id in fixture repo"
    fi
fi

# 4. Real-registry gate: no open P0/P1 gap in the tracked dump has a
#    missing or placeholder opened_date. Reads .chump/state.sql directly —
#    that's the git-tracked source of truth (state.db is gitignored/local).
SQL_DUMP="$REPO_ROOT/.chump/state.sql"
if [[ -f "$SQL_DUMP" ]]; then
    VIOLATIONS=$(python3 - "$SQL_DUMP" <<'PYEOF'
import re, sys

path = sys.argv[1]
text = open(path, errors="ignore").read()
entries = text.split("\n- id: ")
placeholders = {"", "TBD", "TODO", "0000-00-00", "unknown"}
violations = []
for chunk in entries[1:]:
    block = "- id: " + chunk
    id_match = re.match(r"- id:\s*(\S+)", block)
    if not id_match:
        continue
    gap_id = id_match.group(1)
    # Top-level YAML keys sit at exactly 2-space indent; nested content
    # (acceptance_criteria bullets, notes: | block text) is indented 4+
    # spaces, so anchoring on "\n  <key>:" (not "\n    ") avoids matching
    # the field name when it appears inside quoted free text elsewhere in
    # the block (e.g. a gap whose notes literally say "status: open").
    status_match = re.search(r"\n  status:\s*(\S+)", block)
    if not status_match or status_match.group(1) != "open":
        continue
    prio_match = re.search(r"\n  priority:\s*\"?(P[0-3])\"?", block)
    if not prio_match or prio_match.group(1) not in ("P0", "P1"):
        continue
    date_match = re.search(r"\n  opened_date:\s*'?([^'\n]*)'?", block)
    value = date_match.group(1).strip() if date_match else ""
    if not value or value in placeholders:
        violations.append(gap_id)

for v in violations:
    print(v)
PYEOF
)
    VIOLATION_COUNT=$(echo -n "$VIOLATIONS" | grep -c . || true)
    if [[ "$VIOLATION_COUNT" -eq 0 ]]; then
        ok "no open P0/P1 gap in .chump/state.sql has missing/placeholder opened_date"
    else
        fail "$VIOLATION_COUNT open P0/P1 gap(s) missing/placeholder opened_date: $(echo "$VIOLATIONS" | tr '\n' ' ')"
    fi
else
    fail ".chump/state.sql not found — cannot run real-registry coverage check"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
