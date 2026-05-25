#!/usr/bin/env bash
# capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CREDIBLE-078)
# test-gap-list-domain-summary.sh — INFRA-431
#
# `chump gap list` now hides pure-test domains by default, prints a domain
# summary line, and ALERTs on anomalous domain populations. This test seeds
# a fresh state.db with a mix of normal + test-domain gaps and asserts:
#
#   1. SPIKE-* rows are hidden by default
#   2. --include-test-domains brings them back
#   3. The summary line includes total + per-domain top-N
#   4. The "filtered out" line names the hidden domains
#   5. ALERT fires when a single domain crosses the 50%-of-total threshold
#   6. --json output is unchanged (no filter, no summary, no ALERT)
#
# Network-free: scoped to a tempdir state.db via CHUMP_REPO.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$(git rev-parse --show-toplevel)/target}/release/chump}"
[ -x "$CHUMP_BIN" ] || { echo "FATAL: $CHUMP_BIN not found"; exit 2; }

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-431 chump gap list domain-summary + test-filter test ==="
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump" "$TMP/docs/gaps"
# CHUMP_REPO scopes the SQLite store. CHUMP_WORKTREE_ROOT (INFRA-247)
# scopes the per-file YAML write so we don't leak into the host repo's
# docs/gaps/. cd into TMP so any git-rev-parse fallback also stays
# scoped (TMP is not a git repo, so worktree_root falls back to CWD).
cd "$TMP"
git init -q -b main . 2>/dev/null || true
git -C "$TMP" config user.email "test@test.com" 2>/dev/null
git -C "$TMP" config user.name "Test" 2>/dev/null
export CHUMP_REPO="$TMP"
export CHUMP_WORKTREE_ROOT="$TMP"
export CHUMP_BINARY_STALENESS_CHECK=0

# Seed: 3 INFRA + 1 META + 5 SPIKE rows. SPIKE = 5/9 = 55% of total — over
# the 50% threshold, so the ALERT must fire. Use --force to bypass the
# FLEET-029 ambient overlap check and --force-duplicate (INFRA-1149) to bypass
# the title-similarity check (the titles intentionally repeat shape across rows
# for the leak-fixture analog).
for i in 1 2 3; do
    "$CHUMP_BIN" gap reserve --domain INFRA --title "isolated-test-fixture-row-$i-$$" --priority P2 --effort xs --force --force-duplicate >/dev/null 2>&1
done
"$CHUMP_BIN" gap reserve --domain META --title "isolated-meta-fixture-$$" --priority P2 --effort xs --force --force-duplicate >/dev/null 2>&1
for i in 1 2 3 4 5; do
    "$CHUMP_BIN" gap reserve --domain SPIKE --title "spike-test-$i-$$" --priority P2 --effort xs --force --force-duplicate >/dev/null 2>&1
done

# ── Test 1: SPIKE hidden by default ─────────────────────────────────────────
echo "--- Test 1: default output hides SPIKE rows ---"
out_default="$("$CHUMP_BIN" gap list --status open 2>&1)"
spike_in_default=$(echo "$out_default" | grep -cE '^\[open\] SPIKE-' || true)
if [[ "$spike_in_default" -eq 0 ]]; then
    ok "no SPIKE rows in default output"
else
    fail "found $spike_in_default SPIKE row(s) in default output"
fi

# ── Test 2: --include-test-domains shows them ──────────────────────────────
echo "--- Test 2: --include-test-domains brings SPIKE rows back ---"
out_inc="$("$CHUMP_BIN" gap list --status open --include-test-domains 2>&1)"
spike_in_inc=$(echo "$out_inc" | grep -cE '^\[open\] SPIKE-' || true)
if [[ "$spike_in_inc" -eq 5 ]]; then
    ok "all 5 SPIKE rows shown with --include-test-domains"
else
    fail "expected 5 SPIKE rows, got $spike_in_inc"
fi

# ── Test 3: summary line present ───────────────────────────────────────────
echo "--- Test 3: summary line shows total + per-domain ---"
if echo "$out_default" | grep -q "9 total open across" \
   && echo "$out_default" | grep -qE "top: SPIKE=5"; then
    ok "summary line present with correct counts"
else
    fail "summary line missing or wrong; default output:"
    echo "$out_default" | sed 's/^/      /'
fi

# ── Test 4: filtered-out line names hidden domains ─────────────────────────
echo "--- Test 4: 'filtered out' line names SPIKE ---"
if echo "$out_default" | grep -qE "filtered out 5 .*SPIKE"; then
    ok "filtered-out line names SPIKE"
else
    fail "filtered-out line missing or doesn't name SPIKE"
fi

# ── Test 5: ALERT fires on > 50%-of-total domain ───────────────────────────
echo "--- Test 5: ALERT fires when SPIKE > 50% of total (5/9 = 55%) ---"
# stderr only — capture separately.
err_only="$("$CHUMP_BIN" gap list --status open 2>&1 1>/dev/null)"
if echo "$err_only" | grep -qE "ALERT: domain SPIKE has 5 gaps \(55% of total\) — likely a test-fixture leak"; then
    ok "ALERT fired with expected text"
else
    fail "expected ALERT not in stderr; stderr was:"
    echo "$err_only" | sed 's/^/      /'
fi

# ── Test 6: --json output unchanged ────────────────────────────────────────
echo "--- Test 6: --json output excludes summary + filter + ALERT ---"
out_json="$("$CHUMP_BIN" gap list --status open --json 2>/dev/null)"
err_json="$("$CHUMP_BIN" gap list --status open --json 2>&1 1>/dev/null)"
# JSON must include all 9 rows including SPIKE (tooling sees ground truth).
spike_in_json=$(echo "$out_json" | python3 -c "
import json, sys
print(sum(1 for g in json.load(sys.stdin) if g['id'].startswith('SPIKE-')))
")
# Summary lines must NOT appear in --json stdout.
summary_in_json=$(echo "$out_json" | grep -cE "total open across|filtered out" || true)
# ALERT also suppressed in --json mode (deliberately — JSON is for tooling).
alert_in_err=$(echo "$err_json" | grep -cE "^ALERT" || true)
if [[ "$spike_in_json" -eq 5 && "$summary_in_json" -eq 0 && "$alert_in_err" -eq 0 ]]; then
    ok "--json output is clean (5 SPIKE rows visible, no summary, no ALERT)"
else
    fail "--json behavior wrong: spike=$spike_in_json summary=$summary_in_json alert=$alert_in_err"
fi

# ── EFFECTIVE-023 tests: --domain header, --domain all summary, JSON object ──
# Use a fresh DB with simple ALPHA/BETA rows so results are deterministic.
DB2="$TMP/state-e023.db"
python3 - "$DB2" <<'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("""
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY, domain TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '',
    description TEXT DEFAULT '', priority TEXT DEFAULT 'P1', effort TEXT DEFAULT 's',
    status TEXT DEFAULT 'open', acceptance_criteria TEXT DEFAULT '',
    depends_on TEXT DEFAULT '', notes TEXT DEFAULT '', source_doc TEXT DEFAULT '',
    created_at INTEGER DEFAULT 0, closed_at INTEGER,
    opened_date TEXT DEFAULT '', closed_date TEXT DEFAULT '', closed_pr INTEGER,
    skills_required TEXT DEFAULT '', preferred_backend TEXT DEFAULT '',
    preferred_machine TEXT DEFAULT '', estimated_minutes TEXT DEFAULT '',
    required_model TEXT DEFAULT ''
)
""")
rows = [
    ('ALPHA-001','ALPHA','ALPHA: first open gap',  'P0','xs','open'),
    ('ALPHA-002','ALPHA','ALPHA: second open gap', 'P1','s', 'open'),
    ('ALPHA-003','ALPHA','ALPHA: done gap',        'P1','s', 'done'),
    ('BETA-001', 'BETA', 'BETA: single open gap',  'P1','m', 'open'),
    ('BETA-002', 'BETA', 'BETA: done gap',         'P2','s', 'done'),
]
for r in rows:
    conn.execute("INSERT OR REPLACE INTO gaps (id,domain,title,priority,effort,status) VALUES (?,?,?,?,?,?)",r)
conn.commit()
PYEOF

# ── Test 7 (EFFECTIVE-023): --domain <D> shows header + only that domain's rows
echo "--- Test 7 (EFFECTIVE-023): --domain ALPHA shows header + only ALPHA rows ---"
out7="$(CHUMP_STATE_DB="$DB2" "$CHUMP_BIN" gap list --domain ALPHA 2>/dev/null)"
if echo "$out7" | grep -q "Domain: ALPHA"; then
    ok "--domain ALPHA: domain header present"
else
    fail "--domain ALPHA: domain header missing (output: $out7)"
fi
non_alpha="$(echo "$out7" | grep -E "^\[" | grep -v "ALPHA-" || true)"
if [[ -z "$non_alpha" ]]; then
    ok "--domain ALPHA: only ALPHA rows shown"
else
    fail "--domain ALPHA: non-ALPHA rows appeared: $non_alpha"
fi

# ── Test 8 (EFFECTIVE-023): --domain all shows per-domain summary footer
echo "--- Test 8 (EFFECTIVE-023): --domain all shows per-domain summary footer ---"
out8="$(CHUMP_STATE_DB="$DB2" "$CHUMP_BIN" gap list --domain all 2>/dev/null)"
if echo "$out8" | grep -qE "^ALPHA:.*open" && echo "$out8" | grep -qE "^BETA:.*open"; then
    ok "--domain all: per-domain summary lines present for ALPHA and BETA"
else
    fail "--domain all: missing per-domain summary lines (output: $out8)"
fi

# ── Test 9 (EFFECTIVE-023): --domain <D> --json wraps in {gaps, domain_summary}
echo "--- Test 9 (EFFECTIVE-023): --domain ALPHA --json returns object with domain_summary ---"
out9="$(CHUMP_STATE_DB="$DB2" "$CHUMP_BIN" gap list --domain ALPHA --json 2>/dev/null)"
check9="$(echo "$out9" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert isinstance(d,dict), 'not an object'
assert 'gaps' in d and 'domain_summary' in d, 'missing keys'
assert 'ALPHA' in d['domain_summary'], 'ALPHA not in domain_summary'
bad=[g['id'] for g in d['gaps'] if not g['id'].startswith('ALPHA')]
assert not bad, f'non-ALPHA in gaps: {bad}'
print('OK')
" 2>&1 || true)"
if [[ "$check9" == "OK" ]]; then
    ok "--domain ALPHA --json: {gaps, domain_summary} structure correct"
else
    fail "--domain ALPHA --json: structure check failed: $check9 (output: $out9)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
