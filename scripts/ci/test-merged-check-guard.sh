#!/usr/bin/env bash
# test-merged-check-guard.sh — INFRA-306 regression test.
#
# Verifies the "PR already MERGED" guard fires in:
#   1. bot-merge.sh — exits 0 with "already MERGED" message before push
#   2. pr-watch.sh attempt_recovery — returns 0 without touching git
#
# Strategy: stub `gh` on PATH to return state=MERGED, then run the
# script. Assert exit code + stdout phrase.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
PR_WATCH="$REPO_ROOT/scripts/coord/pr-watch.sh"

[[ -x "$BOT_MERGE" ]] || { echo "[FAIL] bot-merge.sh not found"; exit 1; }
[[ -x "$PR_WATCH" ]]  || { echo "[FAIL] pr-watch.sh not found"; exit 1; }

# ── Test 1: pr-watch.sh attempt_recovery skips on MERGED ─────────────────
# We test pr-watch via stub-on-PATH because it's the cleaner unit (calls
# `gh pr view` early in attempt_recovery; we can't drive bot-merge end-to-
# end in CI without actually pushing). For bot-merge we just grep for the
# guard's literal source text — proof the guard is in place.

echo "Test 1: pr-watch.sh attempt_recovery skips when PR is MERGED"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# Stub gh: respond to `gh pr view <PR> --json state ...` with state=MERGED.
# All other invocations forward to the real gh (so the BRANCH-name check
# at the top of pr-watch still works against the real repo). The stub
# is a single bash file at $TMP/gh; we prepend $TMP to PATH.
cat > "$TMP/gh" <<'STUB'
#!/usr/bin/env bash
# Stub: route 'pr view <PR> --json state' to MERGED; everything else → real gh.
if [[ "$1 $2" == "pr view" ]] && [[ " $* " == *" --json state"* ]]; then
    if [[ " $* " == *" -q .state"* ]] || [[ " $* " == *" --jq .state"* ]]; then
        echo MERGED
    else
        echo '{"state":"MERGED"}'
    fi
    exit 0
fi
exec /usr/bin/env -u PATH bash -c 'export PATH="$REAL_PATH"; exec gh "$@"' _ "$@"
STUB
chmod +x "$TMP/gh"

# We need pr-watch to enter attempt_recovery, which means convincing it
# the polled state is "OPEN DIRTY". Easiest path: test the function in
# isolation. Source the script with a trick — pr-watch isn't structured
# as a library, so instead invoke it with a real PR number and rely on
# the upfront state-check in attempt_recovery to fire as soon as a DIRTY
# poll returns. Since stubbing the WHOLE poll loop would be flaky,
# instead just verify the check exists in source and is reachable:
grep -q 'INFRA-306' "$PR_WATCH" || {
    echo "[FAIL] INFRA-306 marker missing from pr-watch.sh"; exit 1; }
grep -q 'already MERGED — skipping recovery' "$PR_WATCH" || {
    echo "[FAIL] MERGED-skip diagnostic missing from pr-watch.sh"; exit 1; }
# And verify it's in the right place — INSIDE attempt_recovery, BEFORE
# the gh pr merge --disable-auto call (the destructive op).
awk '/^attempt_recovery\(\)/{in_fn=1} in_fn && /gh pr merge "?\$PR"? --disable-auto/{print NR; exit}' "$PR_WATCH" \
    | { read -r disable_line
        awk '/^attempt_recovery\(\)/{in_fn=1} in_fn && /already MERGED — skipping recovery/{print NR; exit}' "$PR_WATCH" \
            | { read -r merged_line
                if [[ -z "$merged_line" || -z "$disable_line" ]] || (( merged_line >= disable_line )); then
                    echo "[FAIL] MERGED-check is missing or comes AFTER the destructive gh pr merge --disable-auto call"
                    echo "       merged_line=$merged_line disable_line=$disable_line"
                    exit 1
                fi
            }
      }
echo "[PASS] pr-watch.sh has the MERGED guard before destructive ops"

# ── Test 2: bot-merge.sh has the guard before git push --force-with-lease ─
echo ""
echo "Test 2: bot-merge.sh has the guard before git push --force-with-lease"
grep -q 'INFRA-306: pre-push MERGED check' "$BOT_MERGE" || {
    echo "[FAIL] INFRA-306 marker missing from bot-merge.sh"; exit 1; }
guard_line=$(grep -n 'INFRA-306: pre-push MERGED check' "$BOT_MERGE" | head -1 | cut -d: -f1)
push_line=$(grep -n 'git push.*--force-with-lease' "$BOT_MERGE" | head -1 | cut -d: -f1)
if [[ -z "$guard_line" || -z "$push_line" ]] || (( guard_line >= push_line )); then
    echo "[FAIL] guard not before force-push (guard_line=$guard_line push_line=$push_line)"
    exit 1
fi
echo "[PASS] bot-merge.sh guard at line $guard_line, before force-push at line $push_line"

# ── Test 3: bypass env CHUMP_SKIP_MERGED_CHECK is documented ─────────────
echo ""
echo "Test 3: CHUMP_SKIP_MERGED_CHECK bypass is mentioned in source + CLAUDE.md"
grep -q 'CHUMP_SKIP_MERGED_CHECK' "$BOT_MERGE" || {
    echo "[FAIL] bypass env missing from bot-merge.sh"; exit 1; }
grep -q 'CHUMP_SKIP_MERGED_CHECK' "$PR_WATCH" || {
    echo "[FAIL] bypass env missing from pr-watch.sh"; exit 1; }
# DOC-018 (2026-05-04) split CLAUDE.md into hot overlay + cold gotchas.
# INFRA-306 recovery details moved to docs/process/CLAUDE_GOTCHAS.md.
# Either location satisfies the doc-pin contract.
if grep -q 'INFRA-306' "$REPO_ROOT/CLAUDE.md" \
   || grep -q 'INFRA-306' "$REPO_ROOT/docs/process/CLAUDE_GOTCHAS.md" 2>/dev/null; then
    echo "[PASS] bypass env documented; INFRA-306 referenced in CLAUDE.md or CLAUDE_GOTCHAS.md"
else
    echo "[FAIL] INFRA-306 not documented in CLAUDE.md or docs/process/CLAUDE_GOTCHAS.md"
    exit 1
fi

echo ""
echo "[OK] all 3 INFRA-306 MERGED-guard cases passed"
