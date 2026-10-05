#!/usr/bin/env bash
# test-drift-flag-extract.sh — CREDIBLE-569
#
# No live almanac binary or index is available in CI, so this stubs
# ALMANAC_BIN with a fake executable that emits canned findings-json and
# asserts: (1) the raw output lands in the requested out file, (2) the
# logged/reported flags_retrieved count matches the DRIFT-kind findings in
# the fixture, (3) exit code 0 on success, (4) exit code 1 when the binary
# is missing/not executable.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

SCRIPT="scripts/dev/drift-flag-extract.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# --- fixture: fake almanac binary emitting 3 findings, 2 of them DRIFT ---
FAKE_BIN="$WORK/almanac"
cat > "$FAKE_BIN" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{
  "findings": [
    {"kind": "DRIFT", "flag": "BEAST_MODE_API", "coverage_status": "full"},
    {"kind": "DRIFT", "flag": "BASE_URL", "coverage_status": "full"},
    {"kind": "GATE", "flag": "SOME_GATE", "coverage_status": "partial"}
  ]
}
JSON
EOF
chmod +x "$FAKE_BIN"

OUT_FILE="$WORK/drift-flags.json"

# --- success path ---
if ! stdout="$(ALMANAC_BIN="$FAKE_BIN" "$SCRIPT" --repo "$WORK" --out "$OUT_FILE" --json 2>"$WORK/stderr.log")"; then
    cat "$WORK/stderr.log"
    fail "script exited non-zero on the happy path"
fi
pass "script exits 0 with a stubbed almanac binary"

[[ -f "$OUT_FILE" ]] || fail "raw output file was not created at $OUT_FILE"
pass "raw findings JSON is stored on disk"

grep -q '"BEAST_MODE_API"' "$OUT_FILE" || fail "raw output file does not contain the fixture's findings"
pass "raw output file contains the fixture's raw findings"

echo "$stdout" | grep -q '"flags_retrieved":2' \
    && pass "reports flags_retrieved=2 (only DRIFT-kind findings counted)" \
    || fail "expected flags_retrieved=2 in JSON summary, got: $stdout"

grep -q "retrieved 2 drift flag(s)" "$WORK/stderr.log" \
    && pass "logs the number of flags retrieved" \
    || fail "expected a log line reporting the retrieved count"

# --- missing binary path ---
set +e
ALMANAC_BIN="$WORK/does-not-exist" "$SCRIPT" --repo "$WORK" --out "$WORK/unused.json" >/dev/null 2>"$WORK/stderr2.log"
rc=$?
set -e
[[ "$rc" -eq 1 ]] && pass "exits 1 when the almanac binary is missing" \
    || fail "expected exit 1 for missing binary, got $rc"

echo "ALL PASS: test-drift-flag-extract.sh"
