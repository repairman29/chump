#!/usr/bin/env bash
# scripts/ci/test-resilient-1625-structural-hook.sh — RESILIENT-1625 regression.
#
# Verifies:
#   1. Stub-chump behavioral matrix (8 cases) on pre-push Guard 0a:
#      (new binary advertising --structural vs stale binary without --structural)
#      x (CHUMP_BOT_MERGE_IN_PROGRESS=0 vs 1)
#      x (chump preflight exit 0 vs 1).
#   2. Plain push (CHUMP_BOT_MERGE_IN_PROGRESS=0) NEVER passes --structural.
#   3. Bot-merge push with new binary emits kind=prepush_structural_subset_ran
#      (NOT prepush_preflight_skipped_botmerge); stale binary emits
#      kind=prepush_preflight_skipped_botmerge.
#   4. .github/ workflow change triggers preflight_has_targets=1 in Guard 0a.
#   5. bot-merge.sh stage 4b runs BEFORE stage 4e (bot-merge.lock) and its
#      watchdog budget (150s) exceeds the 120s run timeout.

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== RESILIENT-1625: behavioral Guard 0a 8-case matrix & bot-merge stage 4b ==="

# Check bot-merge stage 4b placement and watchdog budget
line_4b="$(grep -n '^# ── 4b\. Structural preflight subset' "$BOT_MERGE" | head -1 | cut -d: -f1)"
line_4e="$(grep -n '^# ── 4e\. INFRA-860: bot-merge mutex' "$BOT_MERGE" | head -1 | cut -d: -f1)"
if [[ -n "$line_4b" && -n "$line_4e" ]] && (( line_4b < line_4e )); then
    ok "bot-merge stage 4b runs before stage 4e bot-merge.lock ($line_4b < $line_4e)"
else
    fail "bot-merge stage 4b must run before stage 4e bot-merge.lock (4b=$line_4b 4e=$line_4e)"
fi

if grep -q 'stage_start "structural preflight subset (chump preflight --structural)" 150' "$BOT_MERGE"; then
    ok "bot-merge stage 4b watchdog budget (150s) exceeds run timeout (120s)"
else
    fail "bot-merge stage 4b watchdog budget must be 150s (> 120s run timeout)"
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/resilient-1625.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# Set up stub git repo with origin/main and a commit touching scripts/foo.sh
git init -q -b main "$T/repo"
git -C "$T/repo" config user.email "test@example.com"
git -C "$T/repo" config user.name "Test"
mkdir -p "$T/repo/scripts/git-hooks" "$T/repo/.chump-locks" "$T/repo/.github/workflows"
cp "$HOOK" "$T/repo/scripts/git-hooks/pre-push"
chmod +x "$T/repo/scripts/git-hooks/pre-push"
echo "init" > "$T/repo/README.md"
git -C "$T/repo" add README.md
git -C "$T/repo" commit -q -m "init"
git clone -q --bare "$T/repo" "$T/origin.git"
git -C "$T/repo" remote add origin "$T/origin.git"
git -C "$T/repo" fetch -q origin main
base_sha="$(git -C "$T/repo" rev-parse HEAD)"

git -C "$T/repo" checkout -q -b chump/resilient-1625-claim
echo "#!/usr/bin/env bash" > "$T/repo/scripts/foo.sh"
git -C "$T/repo" add scripts/foo.sh
git -C "$T/repo" commit -q -m "touch script"
head_sha="$(git -C "$T/repo" rev-parse HEAD)"

mkdir -p "$T/bin"
cat > "$T/bin/chump" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "verify-claim-branch" ]]; then
    exit 0
fi
if [[ "${1:-}" == "preflight" && "${2:-}" == "--help" ]]; then
    if [[ "${STUB_CHUMP_MODE:-new}" == "new" ]]; then
        echo "Usage: chump preflight [--structural]"
    else
        echo "Usage: chump preflight [--scope auto]"
    fi
    exit 0
fi
if [[ "${1:-}" == "preflight" ]]; then
    echo "$*" >> "$STUB_INVOKE_LOG"
    exit "${STUB_PREFLIGHT_RC:-0}"
fi
exit 0
STUB
chmod +x "$T/bin/chump"

run_case() {
    local mode="$1" bm="$2" pf_rc="$3"
    rm -f "$T/invoke.log" "$T/repo/.chump-locks/ambient.jsonl"
    local rc=0
    (
        cd "$T/repo" &&         PATH="$T/bin:$PATH"         STUB_CHUMP_MODE="$mode"         STUB_PREFLIGHT_RC="$pf_rc"         STUB_INVOKE_LOG="$T/invoke.log"         CHUMP_BOT_MERGE_IN_PROGRESS="$bm"         CHUMP_PREPUSH_GUARD_0A_ONLY=1         bash "$T/repo/scripts/git-hooks/pre-push" origin "$T/origin.git"             <<< "refs/heads/chump/resilient-1625-claim $head_sha refs/heads/chump/resilient-1625-claim $base_sha"
    ) >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# Case 1: new binary, bm=0, pf=0 -> runs plain `preflight` (no --structural), exits 0
rc=$(run_case new 0 0)
inv="$(cat "$T/invoke.log" 2>/dev/null || true)"
if [[ "$rc" -eq 0 && "$inv" == "preflight" ]]; then
    ok "case 1 (new, bm=0, pf=0): plain preflight ran (no --structural) and passed"
else
    fail "case 1 failed: rc=$rc inv='$inv'"
fi

# Case 2: new binary, bm=0, pf=1 -> runs plain `preflight`, exits 1
rc=$(run_case new 0 1)
inv="$(cat "$T/invoke.log" 2>/dev/null || true)"
if [[ "$rc" -ne 0 && "$inv" == "preflight" ]]; then
    ok "case 2 (new, bm=0, pf=1): plain preflight ran and blocked push"
else
    fail "case 2 failed: rc=$rc inv='$inv'"
fi

# Case 3: new binary, bm=1, pf=0 -> runs `preflight --structural`, emits prepush_structural_subset_ran, exits 0
rc=$(run_case new 1 0)
inv="$(cat "$T/invoke.log" 2>/dev/null || true)"
amb="$(cat "$T/repo/.chump-locks/ambient.jsonl" 2>/dev/null || true)"
if [[ "$rc" -eq 0 && "$inv" == "preflight --structural" ]]    && grep -q '"kind":"prepush_structural_subset_ran"' <<<"$amb"    && ! grep -q '"kind":"prepush_preflight_skipped_botmerge"' <<<"$amb"; then
    ok "case 3 (new, bm=1, pf=0): ran --structural and emitted prepush_structural_subset_ran"
else
    fail "case 3 failed: rc=$rc inv='$inv' amb='$amb'"
fi

# Case 4: new binary, bm=1, pf=1 -> runs `preflight --structural`, blocks push (rc != 0)
rc=$(run_case new 1 1)
inv="$(cat "$T/invoke.log" 2>/dev/null || true)"
if [[ "$rc" -ne 0 && "$inv" == "preflight --structural" ]]; then
    ok "case 4 (new, bm=1, pf=1): failing --structural subset blocked bot-merge push"
else
    fail "case 4 failed: rc=$rc inv='$inv'"
fi

# Case 5: stale binary, bm=0, pf=0 -> runs plain `preflight`, exits 0
rc=$(run_case stale 0 0)
inv="$(cat "$T/invoke.log" 2>/dev/null || true)"
if [[ "$rc" -eq 0 && "$inv" == "preflight" ]]; then
    ok "case 5 (stale, bm=0, pf=0): plain preflight ran (no --structural) and passed"
else
    fail "case 5 failed: rc=$rc inv='$inv'"
fi

# Case 6: stale binary, bm=0, pf=1 -> runs plain `preflight`, exits 1
rc=$(run_case stale 0 1)
inv="$(cat "$T/invoke.log" 2>/dev/null || true)"
if [[ "$rc" -ne 0 && "$inv" == "preflight" ]]; then
    ok "case 6 (stale, bm=0, pf=1): plain preflight ran and blocked push"
else
    fail "case 6 failed: rc=$rc inv='$inv'"
fi

# Case 7: stale binary, bm=1, pf=0 -> skips preflight, emits prepush_preflight_skipped_botmerge, exits 0
rc=$(run_case stale 1 0)
inv="$(cat "$T/invoke.log" 2>/dev/null || true)"
amb="$(cat "$T/repo/.chump-locks/ambient.jsonl" 2>/dev/null || true)"
if [[ "$rc" -eq 0 && -z "$inv" ]] && grep -q '"kind":"prepush_preflight_skipped_botmerge"' <<<"$amb"; then
    ok "case 7 (stale, bm=1, pf=0): skipped preflight and emitted prepush_preflight_skipped_botmerge"
else
    fail "case 7 failed: rc=$rc inv='$inv' amb='$amb'"
fi

# Case 8: stale binary, bm=1, pf=1 -> skips preflight, exits 0
rc=$(run_case stale 1 1)
inv="$(cat "$T/invoke.log" 2>/dev/null || true)"
if [[ "$rc" -eq 0 && -z "$inv" ]]; then
    ok "case 8 (stale, bm=1, pf=1): stale binary skipped under bot-merge without budget-blow"
else
    fail "case 8 failed: rc=$rc inv='$inv'"
fi

# .github/ target detection check
git -C "$T/repo" checkout -q -b chump/resilient-1625-gh main
echo "name: test" > "$T/repo/.github/workflows/ci.yml"
git -C "$T/repo" add .github/workflows/ci.yml
git -C "$T/repo" commit -q -m "touch workflow"
gh_sha="$(git -C "$T/repo" rev-parse HEAD)"
rm -f "$T/invoke.log"
(
    cd "$T/repo" &&     PATH="$T/bin:$PATH"     STUB_CHUMP_MODE="new"     STUB_PREFLIGHT_RC=0     STUB_INVOKE_LOG="$T/invoke.log"     CHUMP_BOT_MERGE_IN_PROGRESS=1     CHUMP_PREPUSH_GUARD_0A_ONLY=1     bash "$T/repo/scripts/git-hooks/pre-push" origin "$T/origin.git"         <<< "refs/heads/chump/resilient-1625-gh $gh_sha refs/heads/chump/resilient-1625-gh $base_sha"
) >/dev/null 2>&1
inv="$(cat "$T/invoke.log" 2>/dev/null || true)"
if [[ "$inv" == "preflight --structural" ]]; then
    ok ".github/ workflow diff triggers Guard 0a preflight target detection"
else
    fail ".github/ workflow diff did not trigger Guard 0a (inv='$inv')"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
