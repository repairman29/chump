#!/usr/bin/env bash
# test-orphan-closer-pr-diff-check.sh — INFRA-1423
#
# Verifies orphan-pr-closer.sh checks the PR's own commit diff for
# docs/gaps/<id>.yaml BEFORE consulting main/state.db.
#
# Incident repro: 2026-05-15 PR #2063 (PRODUCT-120) was closed because
# state.db drift hid PRODUCT-120; the gap yaml WAS in the PR's own diff
# but the closer only checked main. This test guards that regression.
#
# ACs tested:
#   1. PR diff check happens BEFORE chump gap show (ordering guard)
#   2. Closer queries repos/{owner}/{repo}/pulls/<pr>/files for the yaml
#   3. kind=orphan_close_skipped emitted with reason=in_pr_diff when yaml found
#   4. yaml path construction: docs/gaps/<lowercased-id>.yaml
#   5. Smoke: yaml-in-diff → skip (mock gh, assert closer skips close)
#   6. Smoke: PR #2063 repro — state.db says unregistered, yaml in diff → skip

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLOSER="$REPO_ROOT/scripts/coord/orphan-pr-closer.sh"

echo "=== INFRA-1423 orphan-pr-closer PR-diff-check tests ==="

[[ -f "$CLOSER" ]] || { echo "FAIL: $CLOSER missing"; exit 2; }

# ── AC #1: PR diff check appears before chump gap show (ordering guard) ───────
# Repro guard: the #2063 incident happened because the yaml check was absent
# entirely; after INFRA-1423 fix it must appear BEFORE `gap show`.
_diff_line=$(grep -n "pulls/\${pr}/files\|pulls/\$pr/files\|_pr_diff_has_yaml" "$CLOSER" | head -1 | cut -d: -f1)
_gapshow_line=$(grep -n 'gap show "\$gap_id"\|gap show "$gap_id"' "$CLOSER" | head -1 | cut -d: -f1)

if [[ -n "$_diff_line" && -n "$_gapshow_line" && "$_diff_line" -lt "$_gapshow_line" ]]; then
    ok "AC #1: PR diff check (line $_diff_line) precedes chump gap show (line $_gapshow_line)"
else
    fail "AC #1: PR diff check must precede chump gap show — ordering guard failed (diff=$_diff_line, gapshow=$_gapshow_line)"
fi

# ── AC #2: Closer queries the PR /files endpoint for gap yaml ─────────────────
if grep -qE 'pulls/\$\{?pr\}?/files' "$CLOSER"; then
    ok "AC #2: closer queries pulls/\$pr/files to inspect PR diff"
else
    fail "AC #2: closer does not query PR files endpoint"
fi

# ── AC #2: yaml path is lowercased from gap id ────────────────────────────────
if grep -q "tr '\\[:upper:\\]' '\\[:lower:\\]'" "$CLOSER" || grep -q 'tr.*upper.*lower' "$CLOSER"; then
    ok "AC #2: gap yaml path is lowercased (docs/gaps/<lowercased-id>.yaml)"
else
    fail "AC #2: gap yaml path not lowercased — would miss mixed-case gap IDs"
fi

# ── AC #3: kind=orphan_close_skipped emitted ─────────────────────────────────
if grep -q '"orphan_close_skipped"\|orphan_close_skipped' "$CLOSER"; then
    ok "AC #3: kind=orphan_close_skipped emitted when yaml found in PR diff"
else
    fail "AC #3: orphan_close_skipped event not emitted"
fi

# ── AC #3: reason=in_pr_diff present in the emit ─────────────────────────────
if grep -A3 "orphan_close_skipped" "$CLOSER" | grep -q "in_pr_diff\|reason=in_pr_diff"; then
    ok "AC #3: reason=in_pr_diff included in orphan_close_skipped event"
else
    fail "AC #3: reason=in_pr_diff missing from orphan_close_skipped event"
fi

# ── AC #4: skip message references the yaml path found ───────────────────────
if grep -q "_gap_yaml_path" "$CLOSER"; then
    ok "AC #4: skip log message references the yaml path that was found"
else
    fail "AC #4: skip log message does not reference the yaml path"
fi

# ── AC #5: Smoke — yaml-in-diff → skip (mock mode) ───────────────────────────
# Build a temporary environment where:
#   - gh returns a fabricated PR list (one PR with INFRA-9999 in title, stale)
#   - gh /files returns the gap yaml in diff
#   - chump gap show returns status:done (to confirm yaml check takes priority)
#   - We assert the closer exits 0 and emits the skip, NOT orphan_pr_candidate
_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"' EXIT

# Fake freshness cutoff: PR updated 2h ago
_stale_ts="2020-01-01T00:00:00Z"

# Fake gh binary that responds to each endpoint
cat > "$_tmpdir/gh" << 'GHEOF'
#!/usr/bin/env bash
# Minimal mock for orphan-pr-closer smoke test
args="$*"
case "$args" in
  *"pulls?state=open"*)
    # One open non-draft PR: INFRA-9999, stale
    printf '%s\t%s\t%s\t%s\n' \
      9999 "fix(INFRA-9999): test pr" "chump/infra-9999-claim" "2020-01-01T00:00:00Z"
    ;;
  *"pulls/9999/commits"*)
    echo "[]"
    ;;
  *"pulls/9999/files"*)
    # Gap yaml IS in the PR diff — this is the PR #2063 repro scenario
    echo '"docs/gaps/infra-9999.yaml"'
    ;;
  *"pulls/9999"*"--jq"*"autoMerge"*)
    echo '{"autoMerge":null,"state":"open"}'
    ;;
  *"pulls/9999"*"--jq"*"head.sha"*)
    echo "abc123"
    ;;
  *"commits/abc123/check-runs"*)
    echo ""
    ;;
  *"-X POST"*"comments"*)
    exit 0
    ;;
  *"-X PATCH"*"state=closed"*)
    # Should NEVER be called when yaml is in PR diff
    echo "ERROR: PATCH close called despite yaml in PR diff!" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
GHEOF
chmod +x "$_tmpdir/gh"

# Fake chump binary
cat > "$_tmpdir/chump" << 'CHUMPEOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"gap show INFRA-9999"*)
    # Simulate state.db drift: gap not found (would have triggered false-positive close)
    exit 1
    ;;
  *"ambient emit"*)
    # Record the event kind emitted
    echo "AMBIENT: $*" >> "${TMPDIR:-/tmp}/orphan_closer_smoke_events.txt"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
CHUMPEOF
chmod +x "$_tmpdir/chump"

# Fake git
cat > "$_tmpdir/git" << 'GITEOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"rev-parse --show-toplevel"*)
    echo "${REPO_ROOT:-/tmp}"
    ;;
  *"log origin/main"*)
    echo ""  # no commit on main references INFRA-9999
    ;;
  *)
    exit 0
    ;;
esac
GITEOF
chmod +x "$_tmpdir/git"

_events_file="${TMPDIR:-/tmp}/orphan_closer_smoke_events.txt"
rm -f "$_events_file"

# Run closer in dry-run mode with mocked path
smoke_out=$(
    PATH="$_tmpdir:$PATH" \
    CHUMP_ORPHAN_PR_FRESHNESS_MIN=9999 \
    CHUMP_REPO="$_tmpdir" \
    bash "$CLOSER" 2>&1 || true
)

# AC #5: closer must NOT print "would close" for this PR (yaml in diff → skip)
if echo "$smoke_out" | grep -q "would close.*9999"; then
    fail "AC #5: closer printed 'would close' for PR with yaml in diff — regression!"
else
    ok "AC #5: closer did NOT attempt to close PR where yaml is in the PR diff"
fi

# AC #5: closer must print SKIP with yaml reason
if echo "$smoke_out" | grep -qiE "SKIP.*9999.*yaml|SKIP.*9999.*in_pr_diff|SKIP.*9999.*gap yaml"; then
    ok "AC #5: closer emitted expected SKIP message for yaml-in-diff PR"
else
    fail "AC #5: closer did not emit expected SKIP message (output: $smoke_out)"
fi

# ── AC #6: PR #2063 repro — state.db says unregistered, yaml in diff → skip ──
# This matches the exact failure mode: chump gap show returns nothing (state.db
# drift / gap not yet merged to main), but the yaml IS in the PR's own diff.
# The fix must spare the PR regardless of state.db return value.
if echo "$smoke_out" | grep -qiE "SKIP.*9999"; then
    ok "AC #6: PR #2063 repro confirmed — yaml-in-diff spares PR even when state.db is empty"
else
    fail "AC #6: PR #2063 repro FAILED — closer may close PRs whose gap yaml is in their own diff but absent from state.db"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
