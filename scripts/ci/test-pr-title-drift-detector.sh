#!/usr/bin/env bash
# test-pr-title-drift-detector.sh — INFRA-104 unit tests.
#
# Mocks `gh` and `git` so the detector runs against synthetic PR data.
# Verifies:
#   (1) Title with gap-ID + diff containing it → OK (no alert)
#   (2) Title with gap-ID + body containing it → OK (no alert)
#   (3) Title with gap-ID + file path containing it → OK (no alert)
#   (4) Title with gap-ID + NEITHER body/files/diff signature → DRIFT alert
#   (5) Filing PR (chore(gaps): file …) → SKIP (no alert ever)
#   (6) Closure PR (chore(gaps): close …) → SKIP
#   (7) Backfill PR (chore(gaps): backfill …) → SKIP
#   (8) PR title without any gap-ID → SKIP (no signature to check)
#   (9) Multi-gap PR — only the missing one alerts; the present one passes
#  (10) Ambient ALERT line shape includes pr/gap_id/title/note fields

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-104 pr-title-drift-detector unit tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/pr-title-drift-detector.sh"

if [ ! -x "$DETECTOR" ]; then
    chmod +x "$DETECTOR" 2>/dev/null || true
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Build a fake `gh` shim that reads canned responses from disk.
# Per-PR fixture layout: $TMPDIR_BASE/<pr>/{title,body,files,diff}
GH_SHIM_DIR="$TMPDIR_BASE/bin"
mkdir -p "$GH_SHIM_DIR"
cat > "$GH_SHIM_DIR/gh" <<'GH_EOF'
#!/usr/bin/env bash
# Mock gh: dispatches based on argv to canned files in $GH_FIXTURE_DIR.
set -e
case "$1 $2" in
    "pr view")
        # gh pr view <PR> --json <field> [-q ...]
        pr="$3"
        field=""
        for arg in "$@"; do
            case "$arg" in
                title) field="title" ;;
                body)  field="body"  ;;
                files) field="files" ;;
            esac
        done
        cat "$GH_FIXTURE_DIR/$pr/$field" 2>/dev/null || true
        ;;
    "pr diff")
        pr="$3"
        cat "$GH_FIXTURE_DIR/$pr/diff" 2>/dev/null || true
        ;;
    "pr list")
        # Used by --recent; not exercised in these tests
        echo ""
        ;;
    *) echo "mock gh: unknown args: $*" >&2; exit 1 ;;
esac
GH_EOF
chmod +x "$GH_SHIM_DIR/gh"
export PATH="$GH_SHIM_DIR:$PATH"
export GH_FIXTURE_DIR="$TMPDIR_BASE"

seed_pr() {
    local pr="$1" title="$2" body="$3" files="$4" diff="$5"
    mkdir -p "$TMPDIR_BASE/$pr"
    printf '%s' "$title" > "$TMPDIR_BASE/$pr/title"
    printf '%s' "$body"  > "$TMPDIR_BASE/$pr/body"
    printf '%s' "$files" > "$TMPDIR_BASE/$pr/files"
    printf '%s' "$diff"  > "$TMPDIR_BASE/$pr/diff"
}

reset_ambient() {
    : > "$TMPDIR_BASE/ambient.jsonl"
}

run_detector() {
    CHUMP_AMBIENT_LOG="$TMPDIR_BASE/ambient.jsonl" "$DETECTOR" "$@" 2>&1
}

# ── Test 1: gap-ID in diff → OK ──────────────────────────────────────────────
echo "--- Test 1: title 'INFRA-100: foo' with INFRA-100 in diff → OK ---"
reset_ambient
seed_pr 100 \
    "INFRA-100: implement the foo widget" \
    "Random body without any IDs" \
    "src/foo.rs" \
    "diff --git a/src/foo.rs b/src/foo.rs
+ // INFRA-100 marker added
+ pub fn foo() {}"
out=$(run_detector 100)
if echo "$out" | grep -q "\[OK\]"; then
    ok "Test 1: gap-ID found in diff content → OK"
else
    fail "Test 1: expected OK, got: $out"
fi
[ ! -s "$TMPDIR_BASE/ambient.jsonl" ] && ok "Test 1: no ambient ALERT emitted" || fail "Test 1: ambient ALERT emitted spuriously"

# ── Test 2: gap-ID in body → OK ──────────────────────────────────────────────
echo "--- Test 2: title 'INFRA-200: bar' with INFRA-200 in body → OK ---"
reset_ambient
seed_pr 200 \
    "INFRA-200: redo the bar pipeline" \
    "Closes INFRA-200 by adding the new path" \
    "src/unrelated.rs" \
    "diff --git a/src/unrelated.rs b/src/unrelated.rs
+ pub fn bar() {}"
out=$(run_detector 200)
if echo "$out" | grep -q "\[OK\]"; then ok "Test 2: gap-ID found in body → OK"; else fail "Test 2: expected OK, got: $out"; fi

# ── Test 3: gap-ID in file path → OK ─────────────────────────────────────────
echo "--- Test 3: title 'INFRA-300: x' with INFRA-300 in file path → OK ---"
reset_ambient
seed_pr 300 \
    "INFRA-300: ledger flip" \
    "" \
    "docs/gaps/INFRA-300.yaml" \
    "diff --git a/docs/gaps/INFRA-300.yaml b/docs/gaps/INFRA-300.yaml
+ status: done"
out=$(run_detector 300)
if echo "$out" | grep -q "\[OK\]"; then ok "Test 3: gap-ID found in file path → OK"; else fail "Test 3: expected OK, got: $out"; fi

# ── Test 4: DRIFT — no signature anywhere ────────────────────────────────────
echo "--- Test 4: title 'INFRA-400: x' with NO INFRA-400 anywhere → DRIFT ---"
reset_ambient
seed_pr 400 \
    "INFRA-400: rename widget" \
    "Random body without any references" \
    "src/unrelated.rs" \
    "diff --git a/src/unrelated.rs b/src/unrelated.rs
+ // unrelated change"
out=$(run_detector 400)
if echo "$out" | grep -q "DRIFT.*INFRA-400"; then
    ok "Test 4: drift correctly detected"
else
    fail "Test 4: expected DRIFT alert, got: $out"
fi
if grep -q '"kind":"pr_title_drift"' "$TMPDIR_BASE/ambient.jsonl"; then
    ok "Test 4: ambient ALERT line emitted"
else
    fail "Test 4: ambient ALERT line missing"
fi

# ── Test 5: filing PR → SKIP ─────────────────────────────────────────────────
echo "--- Test 5: 'chore(gaps): file INFRA-500' → SKIP (no alert) ---"
reset_ambient
seed_pr 500 \
    "chore(gaps): file INFRA-500 — new bug found" \
    "" \
    "docs/gaps/INFRA-500.yaml" \
    "diff --git a/docs/gaps/INFRA-500.yaml b/docs/gaps/INFRA-500.yaml
+ - id: INFRA-500
+   status: open"
out=$(run_detector 500)
if echo "$out" | grep -q "SKIP: ledger"; then ok "Test 5: filing PR correctly skipped"; else fail "Test 5: expected SKIP, got: $out"; fi
[ ! -s "$TMPDIR_BASE/ambient.jsonl" ] && ok "Test 5: no ambient ALERT for filing PR" || fail "Test 5: filing PR triggered alert"

# ── Test 6: closure PR → SKIP ────────────────────────────────────────────────
echo "--- Test 6: 'chore(gaps): close INFRA-600' → SKIP ---"
reset_ambient
seed_pr 600 "chore(gaps): close INFRA-600 (#999)" "" "docs/gaps/INFRA-600.yaml" "diff"
out=$(run_detector 600)
if echo "$out" | grep -q "SKIP: ledger"; then ok "Test 6: closure PR correctly skipped"; else fail "Test 6: expected SKIP, got: $out"; fi

# ── Test 7: backfill PR → SKIP ───────────────────────────────────────────────
echo "--- Test 7: 'chore(gaps): backfill 71 historical ghosts' → SKIP ---"
reset_ambient
seed_pr 700 "chore(gaps): backfill 71 historical ghosts (INFRA-700)" "" "docs/gaps/INFRA-700.yaml" "diff"
out=$(run_detector 700)
if echo "$out" | grep -q "SKIP: ledger"; then ok "Test 7: backfill PR correctly skipped"; else fail "Test 7: expected SKIP, got: $out"; fi

# ── Test 8: no gap-ID in title → SKIP ────────────────────────────────────────
echo "--- Test 8: title with no gap-ID → SKIP ---"
reset_ambient
seed_pr 800 "fix: typo in README" "" "README.md" "diff --git a/README.md b/README.md\n+ fix"
out=$(run_detector 800)
if echo "$out" | grep -q "SKIP: no gap-ID"; then ok "Test 8: no-gap-ID PR correctly skipped"; else fail "Test 8: expected SKIP, got: $out"; fi

# ── Test 9: multi-gap — only missing one alerts ──────────────────────────────
echo "--- Test 9: 'INFRA-901 + INFRA-902' with only -901 in diff → DRIFT on -902 only ---"
reset_ambient
seed_pr 900 \
    "INFRA-901: feature land + close INFRA-902" \
    "" \
    "src/feat.rs" \
    "$(printf 'diff --git a/src/feat.rs b/src/feat.rs\n+ // INFRA-901 marker\n+ pub fn feat() {}\n')"
out=$(run_detector 900)
# Anchor assertion to "claims '<gap-id>'" — the title text after the colon
# contains both IDs, so DRIFT.*INFRA-901 would match the alerting-on-902
# line too. The "claims 'X'" anchor unambiguously identifies which gap
# triggered the alert.
if echo "$out" | grep -q "claims 'INFRA-902'"; then
    ok "Test 9: drift on missing INFRA-902 detected"
else
    fail "Test 9: expected DRIFT on INFRA-902, got: $out"
fi
if echo "$out" | grep -q "claims 'INFRA-901'"; then
    fail "Test 9: INFRA-901 should NOT have alerted (it IS in diff)"
else
    ok "Test 9: INFRA-901 (present in diff) correctly NOT alerted"
fi

# ── Test 10: ambient ALERT line shape ────────────────────────────────────────
echo "--- Test 10: ambient ALERT line has pr / gap_id / title / kind fields ---"
reset_ambient
seed_pr 1000 "INFRA-1000: ghost work" "no ref" "src/x.rs" "diff --git a/src/x.rs b/src/x.rs
+ blank"
run_detector 1000 >/dev/null
line=$(head -1 "$TMPDIR_BASE/ambient.jsonl")
missing=""
for f in '"pr":1000' '"gap_id":"INFRA-1000"' '"kind":"pr_title_drift"' '"event":"ALERT"' '"title"' '"note"'; do
    if ! echo "$line" | grep -q "$f"; then missing="$missing $f"; fi
done
if [ -z "$missing" ]; then
    ok "Test 10: ambient line has all required fields"
else
    fail "Test 10: missing fields:$missing — line: $line"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
