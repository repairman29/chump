#!/usr/bin/env bash
# test-pipeline-healing-smoke.sh — INFRA-374/375/376 batch smoke test.
#
# Verifies (network-free, gh-stubbed):
#   1. auto-arm-sweeper.sh CHUMP_AUTO_ARM_SWEEPER=0 bypass exits 0
#   2. auto-arm-sweeper.sh on empty PR list short-circuits cleanly
#   3. auto-arm-sweeper.sh skips draft / already-armed / labeled PRs
#   4. ci-flake-rerun.sh CHUMP_CI_FLAKE_RERUN=0 bypass exits 0
#   5. ci-flake-rerun.sh on empty PR list short-circuits cleanly
#   6. stuck-pr-filer.sh now tags titles with [STUCK_CLASS]
#   7. reaper-heartbeat-watchdog.sh includes auto-arm + ci-flake by default

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SWEEPER="$REPO_ROOT/scripts/ops/auto-arm-sweeper.sh"
FLAKER="$REPO_ROOT/scripts/ops/ci-flake-rerun.sh"
FILER="$REPO_ROOT/scripts/ops/stuck-pr-filer.sh"
WATCHDOG="$REPO_ROOT/scripts/ops/reaper-heartbeat-watchdog.sh"

for f in "$SWEEPER" "$FLAKER" "$FILER" "$WATCHDOG"; do
    [[ -x "$f" ]] || { echo "FAIL: $f not executable"; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub gh so no network. Subsequent tests overwrite the stub for each scenario.
mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

# Initialize a tiny git repo for reaper_setup to find a "main repo".
mkdir -p "$TMP/repo"
( cd "$TMP/repo" && git init -q -b main && git config user.email t@t && git config user.name t \
   && echo init > README && git add . && git commit -qm init )
mkdir -p "$TMP/repo/.chump-locks"

run_in_repo() { ( cd "$TMP/repo" && "$@" ); }

# ── Test 1: auto-arm-sweeper bypass env ─────────────────────────────────────
echo "Test 1: auto-arm-sweeper CHUMP_AUTO_ARM_SWEEPER=0 bypasses"
out=$(CHUMP_AUTO_ARM_SWEEPER=0 "$SWEEPER" 2>&1)
[[ "$out" == *"bypass"* ]] && echo "  PASS" || { echo "  FAIL: $out"; exit 1; }

# ── Test 2: auto-arm-sweeper on empty PR list ───────────────────────────────
echo "Test 2: auto-arm-sweeper short-circuits on empty PR list"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "[]"
EOF
chmod +x "$TMP/bin/gh"
out=$(run_in_repo "$SWEEPER" --dry-run 2>&1)
[[ "$out" == *"No open PRs."* ]] && echo "  PASS" || { echo "  FAIL: $out" | head -5; exit 1; }

# ── Test 3: auto-arm-sweeper skips draft / armed / labeled ──────────────────
echo "Test 3: auto-arm-sweeper skips draft, already-armed, labeled PRs"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<JSON
[
  {"number":100, "title":"draft pr",   "isDraft":true,  "labels":[], "autoMergeRequest":null, "mergeStateStatus":"BLOCKED", "statusCheckRollup":[]},
  {"number":101, "title":"armed pr",   "isDraft":false, "labels":[], "autoMergeRequest":{"mergeMethod":"SQUASH"}, "mergeStateStatus":"BLOCKED", "statusCheckRollup":[]},
  {"number":102, "title":"labeled pr", "isDraft":false, "labels":[{"name":"human-review-wanted"}], "autoMergeRequest":null, "mergeStateStatus":"BLOCKED", "statusCheckRollup":[]},
  {"number":103, "title":"eligible pr","isDraft":false, "labels":[], "autoMergeRequest":null, "mergeStateStatus":"BLOCKED", "statusCheckRollup":[]}
]
JSON
        ;;
    *) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"
out=$(run_in_repo "$SWEEPER" --dry-run 2>&1)
if [[ "$out" == *"PR #100 skip: draft"* ]] \
   && [[ "$out" == *"PR #101 skip: already_armed"* ]] \
   && [[ "$out" == *"PR #102 skip: label:human-review-wanted"* ]] \
   && [[ "$out" == *"would arm PR #103"* ]]; then
    echo "  PASS (3 skips + 1 arm)"
else
    echo "  FAIL"; echo "$out" | sed 's/^/    /' | head -10; exit 1
fi

# ── Test 4: ci-flake-rerun bypass env ───────────────────────────────────────
echo "Test 4: ci-flake-rerun CHUMP_CI_FLAKE_RERUN=0 bypasses"
out=$(CHUMP_CI_FLAKE_RERUN=0 "$FLAKER" 2>&1)
[[ "$out" == *"bypass"* ]] && echo "  PASS" || { echo "  FAIL: $out"; exit 1; }

# ── Test 5: ci-flake-rerun on empty PR list ─────────────────────────────────
echo "Test 5: ci-flake-rerun short-circuits on empty PR list"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "[]"
EOF
chmod +x "$TMP/bin/gh"
out=$(run_in_repo "$FLAKER" --dry-run 2>&1)
[[ "$out" == *"No open PRs."* ]] && echo "  PASS" || { echo "  FAIL: $out" | head -5; exit 1; }

# ── Test 6: stuck-pr-filer tags titles with [STUCK_CLASS] ───────────────────
echo "Test 6: stuck-pr-filer titles include [REBASE]/[CI-RED]/[BEHIND]/[ORPHAN] tag"
if grep -q 'PR #${pr_num} stuck \[\${stuck_class}\]' "$FILER" \
   || grep -q '\[\${stuck_class}\]' "$FILER"; then
    echo "  PASS (file_stuck_gap embeds [\${stuck_class}] in title)"
else
    echo "  FAIL: stuck-pr-filer.sh no longer tags titles"; exit 1
fi
# Also verify all four classes wired in main loop
for cls in REBASE CI-RED BEHIND ORPHAN; do
    if ! grep -q "STUCK_CLASS=\"$cls\"" "$FILER"; then
        echo "  FAIL: STUCK_CLASS=\"$cls\" not assigned in main loop"; exit 1
    fi
done
echo "  PASS (all 4 STUCK_CLASS values wired)"

# ── Test 7: reaper-heartbeat-watchdog includes new reapers ──────────────────
echo "Test 7: watchdog default targets include auto-arm + ci-flake"
if grep -q 'TARGETS=(pr worktree branch stuck-pr auto-arm ci-flake)' "$WATCHDOG"; then
    echo "  PASS"
else
    echo "  FAIL: watchdog default targets don't include auto-arm + ci-flake"; exit 1
fi

echo ""
echo "All pipeline-healing smoke tests passed."
