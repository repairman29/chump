#!/usr/bin/env bash
# test-flake-detector.sh — META-141 smoke tests.
#
# 6-test suite covering flake-detector.sh and flake-quarantine.sh.
# Network-free: uses only sqlite3, python3, and bash.
#
# Tests:
#   1. detector script exists + executable
#   2. fingerprint computation is deterministic (same input → same output)
#   3. 3-occurrence threshold (2 distinct PRs → not quarantined, 3 → quarantined)
#   4. 24h window (failures older than 24h are excluded)
#   5. quarantine state file format (valid JSON with required fields)
#   6. emits kind=flake_detected with all expected fields

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/flake-detector.sh"
LIB="$REPO_ROOT/scripts/coord/lib/flake-quarantine.sh"

PASS=0
FAIL=0

_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

_require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "SKIP: $cmd not available — skipping test suite"
        exit 0
    fi
}

_require_cmd sqlite3
_require_cmd python3

# ── shared tmp setup ─────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FLAKE_DB="$TMP/flake_tracker.db"
QUARANTINE_FILE="$TMP/quarantined-flakes.json"
AMBIENT_LOG="$TMP/ambient.jsonl"

# Initialise the DB schema (mirrors flake-detector.sh init_db())
sqlite3 "$FLAKE_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS flake_run (
  test_path         TEXT NOT NULL,
  run_id            TEXT NOT NULL,
  pr_num            INTEGER,
  conclusion        TEXT NOT NULL,
  error_fingerprint TEXT,
  ts                TEXT NOT NULL,
  PRIMARY KEY (test_path, run_id)
);
CREATE INDEX IF NOT EXISTS idx_flake_run_path_ts ON flake_run(test_path, ts DESC);

CREATE TABLE IF NOT EXISTS flake_quarantine (
  test_path         TEXT PRIMARY KEY,
  quarantined_at    TEXT NOT NULL,
  fingerprint       TEXT NOT NULL,
  follow_up_gap     TEXT NOT NULL DEFAULT '',
  expires_at        TEXT NOT NULL,
  consecutive_passes INTEGER NOT NULL DEFAULT 0
);
SQL

# ── Test 1: detector script exists + executable ───────────────────────────────
echo "Test 1: detector script exists and is executable"
if [[ -x "$DETECTOR" ]]; then
    _pass "flake-detector.sh exists and is executable"
else
    _fail "flake-detector.sh missing or not executable at $DETECTOR"
fi

# ── Test 2: fingerprint computation is deterministic ─────────────────────────
echo "Test 2: fingerprint computation deterministic"
_fingerprint() {
    local text="$1"
    printf '%s' "${text:0:200}" | sha256sum | cut -c1-16
}

fp1="$(_fingerprint "thread 'test_foo' panicked at 'assertion failed: left == right', src/lib.rs:42")"
fp2="$(_fingerprint "thread 'test_foo' panicked at 'assertion failed: left == right', src/lib.rs:42")"
fp_other="$(_fingerprint "thread 'test_bar' panicked at 'called Result::unwrap()', src/lib.rs:99")"

if [[ "$fp1" == "$fp2" ]] && [[ "$fp1" != "$fp_other" ]] && [[ ${#fp1} -eq 16 ]]; then
    _pass "same error → same fingerprint ($fp1); different error → different fingerprint ($fp_other)"
else
    _fail "fingerprint not deterministic or not 16 chars: fp1=$fp1 fp2=$fp2 fp_other=$fp_other"
fi

# ── Test 3: 3-occurrence threshold ───────────────────────────────────────────
echo "Test 3: 3-occurrence threshold (2 PRs → not flake, 3 PRs → flake)"

# Populate DB with 2 PRs failing with the same fingerprint (should NOT quarantine)
FINGERPRINT_A="$(_fingerprint "DNS_RACE_FAIL")"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

sqlite3 "$FLAKE_DB" <<SQL
INSERT INTO flake_run VALUES ('pkg::test_dns', 'run-101', 10, 'fail', '$FINGERPRINT_A', '$NOW_ISO');
INSERT INTO flake_run VALUES ('pkg::test_dns', 'run-102', 11, 'fail', '$FINGERPRINT_A', '$NOW_ISO');
SQL

out3a="$(CHUMP_FLAKE_DB="$FLAKE_DB" \
         CHUMP_FLAKE_QUARANTINE_FILE="$QUARANTINE_FILE" \
         CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
         CHUMP_FLAKE_THRESHOLD=3 \
         CHUMP_FLAKE_WINDOW_SECS=86400 \
         "$DETECTOR" --dry-run 2>&1 || true)"

if [[ "$out3a" != *"would quarantine"* ]]; then
    _pass "2 distinct PRs does not trigger quarantine"
else
    _fail "2 distinct PRs should not quarantine; got: $out3a"
fi

# Add a 3rd PR — now should trigger
sqlite3 "$FLAKE_DB" <<SQL
INSERT INTO flake_run VALUES ('pkg::test_dns', 'run-103', 12, 'fail', '$FINGERPRINT_A', '$NOW_ISO');
SQL

out3b="$(CHUMP_FLAKE_DB="$FLAKE_DB" \
         CHUMP_FLAKE_QUARANTINE_FILE="$QUARANTINE_FILE" \
         CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
         CHUMP_FLAKE_THRESHOLD=3 \
         CHUMP_FLAKE_WINDOW_SECS=86400 \
         "$DETECTOR" --dry-run 2>&1 || true)"

if [[ "$out3b" == *"would quarantine"*"pkg::test_dns"* ]]; then
    _pass "3 distinct PRs triggers quarantine in dry-run"
else
    _fail "3 distinct PRs should trigger quarantine; got: $out3b"
fi

# ── Test 4: 24h window (old failures excluded) ────────────────────────────────
echo "Test 4: 24h window — old failures excluded"

# Insert failures that are 4 days old (well outside the window)
OLD_TS="2026-05-26T00:00:00Z"   # 4 days before 2026-05-30
FINGERPRINT_B="$(_fingerprint "OLD_ERROR")"

sqlite3 "$FLAKE_DB" <<SQL
INSERT INTO flake_run VALUES ('pkg::test_old', 'run-201', 20, 'fail', '$FINGERPRINT_B', '$OLD_TS');
INSERT INTO flake_run VALUES ('pkg::test_old', 'run-202', 21, 'fail', '$FINGERPRINT_B', '$OLD_TS');
INSERT INTO flake_run VALUES ('pkg::test_old', 'run-203', 22, 'fail', '$FINGERPRINT_B', '$OLD_TS');
SQL

out4="$(CHUMP_FLAKE_DB="$FLAKE_DB" \
        CHUMP_FLAKE_QUARANTINE_FILE="$QUARANTINE_FILE" \
        CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
        CHUMP_FLAKE_THRESHOLD=3 \
        CHUMP_FLAKE_WINDOW_SECS=86400 \
        "$DETECTOR" --dry-run 2>&1 || true)"

if [[ "$out4" != *"pkg::test_old"* ]]; then
    _pass "4-day-old failures excluded from 24h window"
else
    _fail "old failures should be excluded; got: $out4"
fi

# ── Test 5: quarantine state file format ─────────────────────────────────────
echo "Test 5: quarantine state file format"

# Run live (not dry-run) against a fresh DB so an entry is written
FLAKE_DB5="$TMP/flake5.db"
QUARANTINE_FILE5="$TMP/quarantined5.json"
AMBIENT_LOG5="$TMP/ambient5.jsonl"
FINGERPRINT_C="$(_fingerprint "FORMAT_TEST_ERROR")"

sqlite3 "$FLAKE_DB5" <<'SQL'
CREATE TABLE IF NOT EXISTS flake_run (
  test_path TEXT NOT NULL, run_id TEXT NOT NULL, pr_num INTEGER,
  conclusion TEXT NOT NULL, error_fingerprint TEXT, ts TEXT NOT NULL,
  PRIMARY KEY (test_path, run_id)
);
CREATE TABLE IF NOT EXISTS flake_quarantine (
  test_path TEXT PRIMARY KEY, quarantined_at TEXT NOT NULL,
  fingerprint TEXT NOT NULL, follow_up_gap TEXT NOT NULL DEFAULT '',
  expires_at TEXT NOT NULL, consecutive_passes INTEGER NOT NULL DEFAULT 0
);
SQL

sqlite3 "$FLAKE_DB5" <<SQL
INSERT INTO flake_run VALUES ('pkg::test_format', 'run-301', 30, 'fail', '$FINGERPRINT_C', '$NOW_ISO');
INSERT INTO flake_run VALUES ('pkg::test_format', 'run-302', 31, 'fail', '$FINGERPRINT_C', '$NOW_ISO');
INSERT INTO flake_run VALUES ('pkg::test_format', 'run-303', 32, 'fail', '$FINGERPRINT_C', '$NOW_ISO');
SQL

CHUMP_FLAKE_DB="$FLAKE_DB5" \
CHUMP_FLAKE_QUARANTINE_FILE="$QUARANTINE_FILE5" \
CHUMP_AMBIENT_LOG="$AMBIENT_LOG5" \
CHUMP_FLAKE_THRESHOLD=3 \
CHUMP_FLAKE_WINDOW_SECS=86400 \
"$DETECTOR" >/dev/null 2>&1 || true

if [[ -f "$QUARANTINE_FILE5" ]]; then
    # Validate JSON is parseable and has required fields
    required_fields_ok=1
    for field in test_path fingerprint quarantined_at expires_at occurrence_count affected_pr_count; do
        if ! python3 -c "
import json, sys
with open('$QUARANTINE_FILE5') as f:
    data = json.load(f)
assert isinstance(data, list), 'not a list'
assert len(data) > 0, 'empty list'
entry = data[0]
assert '$field' in entry, f'missing field $field'
sys.exit(0)
" 2>/dev/null; then
            required_fields_ok=0
            _fail "quarantine JSON missing field: $field"
            break
        fi
    done
    if [[ "$required_fields_ok" == "1" ]]; then
        _pass "quarantine file is valid JSON with all required fields"
    fi
else
    _fail "quarantine file not written at $QUARANTINE_FILE5"
fi

# ── Test 6: emits kind=flake_detected with expected fields ────────────────────
echo "Test 6: emits kind=flake_detected with all expected fields"

if [[ -f "$AMBIENT_LOG5" ]]; then
    # Find a flake_detected event
    detected_line="$(grep '"kind":"flake_detected"' "$AMBIENT_LOG5" | head -1 || true)"
    if [[ -n "$detected_line" ]]; then
        fields_ok=1
        for field in ts kind test_path fingerprint occurrence_count affected_pr_count first_seen last_seen expires_at; do
            if ! printf '%s' "$detected_line" | python3 -c "
import json, sys
line = sys.stdin.read()
evt = json.loads(line)
assert '$field' in evt, f'missing $field'
sys.exit(0)
" 2>/dev/null; then
                _fail "flake_detected event missing field: $field"
                fields_ok=0
                break
            fi
        done
        if [[ "$fields_ok" == "1" ]]; then
            _pass "flake_detected event present with all expected fields"
        fi
    else
        _fail "no kind=flake_detected event found in $AMBIENT_LOG5"
    fi
else
    _fail "ambient log not written at $AMBIENT_LOG5"
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "All flake-detector tests passed."
