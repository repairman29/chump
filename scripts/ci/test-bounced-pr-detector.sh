#!/usr/bin/env bash
# test-bounced-pr-detector.sh — INFRA-781 fixture tests.
#
# We can't easily fake `gh pr list` output without a live API, so this
# fixture validates the detector's core decision logic by stubbing `gh`
# with controllable JSON output and asserting on the ambient events
# emitted + the seen-file state.
#
# Cases:
#   1. CHUMP_BOUNCED_PR_DETECTOR=0 → script silently no-ops
#   2. No closed-unmerged PRs returned → no ambient, no gap
#   3. PR closed unmerged, files NOT re-landed → emit pr_bounced_unfinished
#   4. PR closed unmerged, files re-landed (ratio >= 0.5) → emit pr_bounced_relanded
#   5. Idempotent: same PR processed twice → only one event/gap

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-781 bounced-pr-detector tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/bounced-pr-detector.sh"

if [[ ! -x "$DETECTOR" ]]; then
    echo "FATAL: detector not executable: $DETECTOR"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# W-012 / W-013 (RESILIENT-023): unset workflow-level CHUMP_REPO + CHUMP_LOCK_DIR
# so the detector writes ambient.jsonl to OUR $FAKE/.chump-locks (where the
# assertions look) rather than the workflow-injected paths from INFRA-1959.
# Without this, ambient events go to github.workspace/.chump-locks/ambient.jsonl
# and the test claims the event is missing when it's actually written elsewhere.
unset CHUMP_REPO CHUMP_LOCK_DIR

# Fake repo
FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks" "$FAKE/scripts/coord" "$TMP/bin"
git -C "$FAKE" init -q -b main
git -C "$FAKE" config user.email t@t && git -C "$FAKE" config user.name t
echo "v0" > "$FAKE/file_a.txt"
git -C "$FAKE" add . && git -C "$FAKE" commit -q -m base
cp "$DETECTOR" "$FAKE/scripts/coord/bounced-pr-detector.sh"
chmod +x "$FAKE/scripts/coord/bounced-pr-detector.sh"
cp "$REPO_ROOT/scripts/coord/_bounced_pr_classifier.py" "$FAKE/scripts/coord/_bounced_pr_classifier.py"
chmod +x "$FAKE/scripts/coord/_bounced_pr_classifier.py"

# Fake gh: emits whatever JSON is in $TMP/gh-output.json.
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
# Only `pr list ...` is supported; everything else is a no-op.
case "$1 $2" in
    "pr list")
        cat "$TMP_GH_OUTPUT" 2>/dev/null || echo "[]"
        ;;
    *)
        ;;
esac
GH
chmod +x "$TMP/bin/gh"

# Fake chump: idempotent reserve mock that records calls. We swap PATH so
# the detector's `_chump` lookup picks our mock first.
cat > "$TMP/bin/chump" <<'CMOCK'
#!/usr/bin/env bash
case "$1" in
    gap)
        case "$2" in
            reserve)
                # Record the title for assertion
                echo "$@" >> "$CHUMP_RESERVE_LOG"
                # Print a fake gap ID
                echo "INFRA-FAKE-$(date +%s)"
                exit 0
                ;;
        esac
        ;;
esac
exit 0
CMOCK
chmod +x "$TMP/bin/chump"

run_detector() {
    cd "$FAKE" || return 2
    PATH="$TMP/bin:$PATH" \
    TMP_GH_OUTPUT="${TMP_GH_OUTPUT:-$TMP/gh-output.json}" \
    CHUMP_RESERVE_LOG="$TMP/reserve.log" \
    HOME="$TMP" \
    bash "$FAKE/scripts/coord/bounced-pr-detector.sh" 2>&1
    RC=$?
    cd - >/dev/null || true
    return "$RC"
}

# ── Test 1: bypass env ──────────────────────────────────────────────────────
echo "--- Test 1: CHUMP_BOUNCED_PR_DETECTOR=0 → silent no-op ---"
echo "[]" > "$TMP/gh-output.json"
OUT=$(CHUMP_BOUNCED_PR_DETECTOR=0 run_detector)
if echo "$OUT" | grep -q "skipping"; then
    ok "bypass env produced skip message"
else
    fail "bypass should print skip (out=$OUT)"
fi

# ── Test 2: empty list ──────────────────────────────────────────────────────
echo "--- Test 2: no closed-unmerged PRs → no events ---"
echo "[]" > "$TMP/gh-output.json"
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(run_detector)
if [[ ! -s "$FAKE/.chump-locks/ambient.jsonl" ]]; then
    ok "empty input produced no ambient events"
else
    fail "expected no events (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 3: bounced PR (no relanding) ───────────────────────────────────────
echo "--- Test 3: closed-unmerged PR, files not relanded → pr_bounced_unfinished ---"
# Use NOW timestamp + a file that has no post-seed commits → no relanding.
# Sleep 1s to ensure git log --since= window is empty.
sleep 1
T3_CLOSED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$TMP/gh-output.json" <<EOF
[{"number": 9999, "closedAt": "$T3_CLOSED_AT", "headRefName": "feat/test",
  "title": "Test bounced PR", "files": [{"path": "file_a.txt"}], "mergedAt": null}]
EOF
> "$FAKE/.chump-locks/ambient.jsonl"
> "$FAKE/.chump-locks/bounced-pr-seen.txt"
> "$TMP/reserve.log"
# The seen-file uses substring match for "filed:9999"; ensure not present.
OUT=$(run_detector)
if grep -q "pr_bounced_unfinished" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"pr":9999' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "bounced-unfinished event emitted with PR number"
else
    fail "expected pr_bounced_unfinished for PR 9999 (out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

if grep -q "Test bounced PR" "$TMP/reserve.log" 2>/dev/null; then
    ok "auto-filed recovery gap with PR title"
else
    fail "expected gap reserve call with PR title (reserve.log=$(cat "$TMP/reserve.log" 2>/dev/null))"
fi

# ── Test 4: idempotency — second run doesn't re-file ────────────────────────
echo "--- Test 4: idempotent — second run on same PR doesn't refile ---"
> "$TMP/reserve.log"
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(run_detector)
if [[ ! -s "$TMP/reserve.log" ]]; then
    ok "idempotent: second run did not re-file gap"
else
    fail "second run should not re-file (reserve.log=$(cat "$TMP/reserve.log"))"
fi

# ── Test 5: relanded case — files changed since close ───────────────────────
echo "--- Test 5: closed-unmerged PR, files relanded → pr_bounced_relanded ---"
# Add a commit since the PR's closedAt to simulate relanding.
cd "$FAKE" || exit 2
echo "v1" > file_a.txt
git add . && git commit -q -m "relanding work"
RELANDED_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ -d "1 hour ago" 2>/dev/null \
              || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)
cat > "$TMP/gh-output.json" <<EOF
[{"number": 8888, "closedAt": "$RELANDED_TIME", "headRefName": "feat/relanded",
  "title": "Relanded PR", "files": [{"path": "file_a.txt"}], "mergedAt": null}]
EOF
cd - >/dev/null
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/reserve.log"
OUT=$(run_detector)
if grep -q "pr_bounced_relanded" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "relanded case emits informational event"
else
    fail "expected pr_bounced_relanded (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

if [[ ! -s "$TMP/reserve.log" ]]; then
    ok "relanded case did NOT auto-file a recovery gap"
else
    fail "relanded should not file gap (reserve.log=$(cat "$TMP/reserve.log"))"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
