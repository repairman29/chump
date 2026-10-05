#!/usr/bin/env bash
# test-ci-flake-rerun.sh — INFRA-375 smoke test.
#
# Exercises scripts/ops/ci-flake-rerun.sh with stubbed `gh` on PATH.
# Verifies:
#   1. CHUMP_CI_FLAKE_RERUN=0 bypasses cleanly (exit 0, "bypass" in output).
#   2. Empty PR list short-circuits without error.
#   3. --dry-run output shows "would rerun" when a flake pattern matches.
#   4. Non-matching failure is left alone (no "would rerun").
#   5. Per-run-id cooldown prevents a second rerun attempt.
#
# Network-free: stubs `gh` via PATH.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/ci-flake-rerun.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

# Reaper instrumentation resolves REAPER_REPO_ROOT from git. Stand up a
# minimal bare+working-tree pair so git commands succeed.
git init -q --bare "$TMP/origin.git" >/dev/null
git init -q -b main "$TMP/repo" >/dev/null
cd "$TMP/repo"
git config user.email "test@chump.local"
git config user.name "Chump Test"
echo init > README.md
git add README.md && git commit -qm "init"
git remote add origin "$TMP/origin.git"
git push -q origin main

# reaper_setup sets REAPER_REPO_ROOT = git common-dir parent = $TMP/repo.
# The script builds COOLDOWN_DIR off that, so create the dir here too.
COOLDOWN_DIR="$TMP/repo/.chump-locks/ci-flake-cooldown"
mkdir -p "$COOLDOWN_DIR"
# Point REAPER_LOCK_DIR at our tmp dir to avoid polluting the real ambient.
export REAPER_LOCK_DIR="$TMP/repo/.chump-locks"

# ── Test 1: bypass env exits 0 ───────────────────────────────────────────────
echo "Test 1: CHUMP_CI_FLAKE_RERUN=0 bypasses"
out=$(CHUMP_CI_FLAKE_RERUN=0 "$SCRIPT" 2>&1)
if [[ "$out" == *"bypass"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'bypass' in output, got: $out"
    exit 1
fi

# ── Test 2: empty PR list short-circuits ─────────────────────────────────────
echo "Test 2: empty PR list short-circuits"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "[]"
EOF
chmod +x "$TMP/bin/gh"

out=$("$SCRIPT" 2>&1 || true)
if [[ "$out" == *"No open PRs"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'No open PRs', got: $out"
    exit 1
fi

# ── Test 3: flake-pattern match → dry-run shows "would rerun" ────────────────
echo "Test 3: flake-pattern match → would rerun"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<'JSON'
[{"number":42,"title":"INFRA-100: flaky test","headRefName":"chump/infra-100","statusCheckRollup":[{"conclusion":"FAILURE","targetUrl":"https://github.com/owner/repo/actions/runs/9999001/job/123"}]}]
JSON
        ;;
    "run view 9999001 --log-failed")
        echo "##[error]The operation was canceled."
        ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$("$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"would rerun"*"PR #42"*"9999001"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'would rerun PR #42 run 9999001', got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 4: non-matching failure is left alone ───────────────────────────────
echo "Test 4: non-matching failure is left alone"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<'JSON'
[{"number":55,"title":"INFRA-200: real test failure","headRefName":"chump/infra-200","statusCheckRollup":[{"conclusion":"FAILURE","targetUrl":"https://github.com/owner/repo/actions/runs/9999002/job/456"}]}]
JSON
        ;;
    "run view 9999002 --log-failed")
        echo "assertion failed: expected 42, got 0"
        ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$("$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" != *"would rerun"* ]] && [[ "$out" == *"leaving alone"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: non-matching failure should be left alone, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 5: per-run-id cooldown prevents second rerun ────────────────────────
echo "Test 5: cooldown prevents second rerun"
# Re-use the flake stub from test 3 but pre-create the cooldown file.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<'JSON'
[{"number":42,"title":"INFRA-100: flaky test","headRefName":"chump/infra-100","statusCheckRollup":[{"conclusion":"FAILURE","targetUrl":"https://github.com/owner/repo/actions/runs/9999001/job/123"}]}]
JSON
        ;;
    "run view 9999001 --log-failed")
        echo "##[error]The operation was canceled."
        ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

# In dry-run mode no cooldown file is written, so create it manually.
touch "$COOLDOWN_DIR/run-9999001.ts"

out=$("$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" != *"would rerun"* ]] && [[ "$out" == *"already attempted rerun"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: cooldown should suppress rerun, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 6: catalogued test-name flake (RESILIENT-306) → would rerun ─────────
echo "Test 6: catalogued test-name flake → would rerun (RESILIENT-306)"
FIXTURE_CATALOG="$TMP/known_flakes.yaml"
cat > "$FIXTURE_CATALOG" <<'YAML'
flakes:
  - test: proof_of_merge_tests::credible218_merge_older_than_200_commits_is_proven
    tracking_gap: CREDIBLE-283
    max_reruns: 2
check_flakes: []
YAML
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<'JSON'
[{"number":77,"title":"RESILIENT-306: flaky proof-of-merge","headRefName":"chump/resilient-306","statusCheckRollup":[{"conclusion":"FAILURE","targetUrl":"https://github.com/owner/repo/actions/runs/9999003/job/789"}]}]
JSON
        ;;
    "run view 9999003 --log-failed")
        cat <<'LOG'
running 6 tests
test proof_of_merge_tests::credible218_merge_older_than_200_commits_is_proven ... FAILED

failures:
    proof_of_merge_tests::credible218_merge_older_than_200_commits_is_proven

test result: FAILED. 5 passed; 1 failed; 0 ignored
LOG
        ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"
out=$(CHUMP_KNOWN_FLAKES_FILE="$FIXTURE_CATALOG" "$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"would rerun"*"PR #77"*"9999003"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: catalogued test-name flake should rerun, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 7: uncatalogued real test failure → left alone (escalate-not-loop) ──
echo "Test 7: uncatalogued real test failure → left alone"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<'JSON'
[{"number":88,"title":"INFRA-900: real bug","headRefName":"chump/infra-900","statusCheckRollup":[{"conclusion":"FAILURE","targetUrl":"https://github.com/owner/repo/actions/runs/9999004/job/321"}]}]
JSON
        ;;
    "run view 9999004 --log-failed")
        cat <<'LOG'
running 3 tests
test billing::tests::charge_is_idempotent ... FAILED

failures:
    billing::tests::charge_is_idempotent

test result: FAILED. 2 passed; 1 failed; 0 ignored
LOG
        ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"
out=$(CHUMP_KNOWN_FLAKES_FILE="$FIXTURE_CATALOG" "$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" != *"would rerun"* ]] && [[ "$out" == *"leaving alone"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: real (uncatalogued) failure must be left alone, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 8: per-PR flake-budget exceeded → escalate ONCE, never loop ─────────
echo "Test 8: flake-budget exceeded → refuse rerun + escalate once (no loop)"
export RERUN_LOG="$TMP/rerun.log"; : > "$RERUN_LOG"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list")
        cat <<'JSON'
[{"number":99,"title":"INFRA-999: persistent","headRefName":"chump/infra-999","statusCheckRollup":[{"conclusion":"FAILURE","targetUrl":"https://github.com/owner/repo/actions/runs/9999005/job/654"}]}]
JSON
        ;;
    "run view")   echo "##[error]The operation was canceled." ;;
    "run rerun")  echo "RERUN_CALLED" >> "$RERUN_LOG" ;;
    "pr comment") echo "COMMENT_CALLED" >> "$RERUN_LOG" ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"
# Pre-exceed the per-PR budget.
echo 2 > "$COOLDOWN_DIR/pr-99.count"
out=$(CHUMP_FLAKE_BUDGET=2 "$SCRIPT" 2>&1 || true)
reran=$(grep -c RERUN_CALLED "$RERUN_LOG" 2>/dev/null || true)
if [[ "$out" == *"flake-budget exceeded"* ]] && [[ "$reran" -eq 0 ]]; then
    echo "  PASS (rerun refused; not looped)"
else
    echo "  FAIL: budget-exceeded must refuse rerun. reran=$reran out:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi
# Escalation is bounded: exactly one ambient flake_budget_exceeded + one comment.
amb="$REAPER_LOCK_DIR/ambient.jsonl"
evs=$(grep -c flake_budget_exceeded "$amb" 2>/dev/null || true)
comments=$(grep -c COMMENT_CALLED "$RERUN_LOG" 2>/dev/null || true)
if [[ "$evs" -eq 1 ]] && [[ "$comments" -le 1 ]]; then
    echo "  PASS (one ambient escalation, $comments operator comment — no spam)"
else
    echo "  FAIL: escalation must be bounded (1 ambient, <=1 comment); got ambient=$evs comment=$comments"
    exit 1
fi
# Idempotent: a second tick does NOT emit another comment (marker debounce).
out2=$(CHUMP_FLAKE_BUDGET=2 "$SCRIPT" 2>&1 || true)
comments2=$(grep -c COMMENT_CALLED "$RERUN_LOG" 2>/dev/null || true)
if [[ "$comments2" -le 1 ]]; then
    echo "  PASS (second tick did not re-comment: total=$comments2)"
else
    echo "  FAIL: escalation re-commented on repeat tick (spam): $comments2"
    exit 1
fi

# ── Test 9: real `gh run view --log-failed` PREFIX format is parsed ──────────
# gh prefixes each line "job<TAB>step<TAB>TIMESTAMP " — the exact shape that hid
# credible218's name from a naive parser. Proves the organ strips it and matches.
echo "Test 9: gh-prefixed log (job<TAB>step<TAB>ts) catalogued flake → would rerun"
printf 'flakes:\n  - test: proof_of_merge_tests::credible218_merge_older_than_200_commits_is_proven\n    tracking_gap: CREDIBLE-283\ncheck_flakes: []\n' > "$FIXTURE_CATALOG"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<'JSON'
[{"number":66,"title":"RESILIENT-306: gh-prefixed flake","headRefName":"chump/resilient-306b","statusCheckRollup":[{"conclusion":"FAILURE","targetUrl":"https://github.com/owner/repo/actions/runs/9999006/job/246"}]}]
JSON
        ;;
    "run view 9999006 --log-failed")
        printf 'fast-checks\tgap-store proof-of-merge guard (INFRA-1392)\t2026-08-12T13:29:43.0964331Z failures:\n'
        printf 'fast-checks\tgap-store proof-of-merge guard (INFRA-1392)\t2026-08-12T13:29:43.0964829Z     proof_of_merge_tests::credible218_merge_older_than_200_commits_is_proven\n'
        printf 'fast-checks\tgap-store proof-of-merge guard (INFRA-1392)\t2026-08-12T13:29:43.0965478Z test result: FAILED. 5 passed; 1 failed; 133 filtered out\n'
        ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"
out=$(CHUMP_KNOWN_FLAKES_FILE="$FIXTURE_CATALOG" "$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"would rerun"*"PR #66"*"9999006"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: gh-prefixed catalogued flake should rerun, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 10: CANCELLED required check → full rerun, even with EMPTY log ───────
# RESILIENT-308: the cancelled audit-shard class. A CANCELLED conclusion is an
# inherent concurrency/timeout flake — it must rerun WITHOUT needing any log
# text, and via a WHOLE-run rerun (`gh run rerun`, no `--failed`, which skips
# cancelled jobs). The stub returns an EMPTY --log-failed to prove log-independence.
echo "Test 10: CANCELLED check → would rerun mode=full with empty log"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<'JSON'
[{"number":101,"title":"AUDIT: cancelled shard","headRefName":"chump/audit-101","statusCheckRollup":[{"name":"audit-shard (2)","conclusion":"CANCELLED","targetUrl":"https://github.com/owner/repo/actions/runs/9999010/job/111"}]}]
JSON
        ;;
    "run view 9999010 --log-failed") echo "" ;;   # cancelled jobs have no failed-log
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"
out=$("$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"would rerun"*"PR #101"*"9999010"*"mode=full"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: cancelled check should rerun mode=full with empty log, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 11: live (non-dry) CANCELLED rerun calls `gh run rerun` WITHOUT --failed
# The whole point: `--failed` silently skips a cancelled job, so a cancelled shard
# would never re-execute. Assert the organ invokes the full-run form.
echo "Test 11: CANCELLED check live rerun uses full-run form (no --failed)"
export RR11="$TMP/rr11.log"; : > "$RR11"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list")
        cat <<'JSON'
[{"number":102,"title":"AUDIT: cancelled shard live","headRefName":"chump/audit-102","statusCheckRollup":[{"name":"audit-shard (4)","conclusion":"CANCELLED","targetUrl":"https://github.com/owner/repo/actions/runs/9999011/job/222"}]}]
JSON
        ;;
    "run view") echo "" ;;
    "run rerun") shift 2; echo "RERUN_ARGS:[$*]" >> "$RR11" ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"
out=$("$SCRIPT" 2>&1 || true)
rr_line=$(cat "$RR11" 2>/dev/null || true)
if [[ "$rr_line" == "RERUN_ARGS:[9999011]" ]]; then
    echo "  PASS (full-run rerun: $rr_line)"
else
    echo "  FAIL: cancelled rerun must be 'gh run rerun 9999011' (no --failed), got: '$rr_line'"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 12: audit-aggregate 'result=cancelled' log signature (FAILURE concl) ─
# The `audit` required check ends FAILURE (not CANCELLED) when its cause is a
# cancelled shard; its log carries "result=cancelled". Match it via pattern →
# rerun (mode=failed is fine here — the aggregate job itself is failed).
echo "Test 12: audit aggregate 'result=cancelled' log signature → would rerun"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<'JSON'
[{"number":103,"title":"INFRA-x: audit aggregate red","headRefName":"chump/infra-x","statusCheckRollup":[{"name":"audit","conclusion":"FAILURE","targetUrl":"https://github.com/owner/repo/actions/runs/9999012/job/333"}]}]
JSON
        ;;
    "run view 9999012 --log-failed")
        echo "::error::audit FAIL — at least one audit-shard failed (result=cancelled)" ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"
out=$("$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"would rerun"*"PR #103"*"9999012"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: audit-aggregate cancelled-shard signature should rerun, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 13: a genuine FAILURE with a real assertion log is STILL left alone ──
# Guard against over-eager rerun: a non-cancelled real failure with no flake
# fingerprint must not be reran (regression guard for the new cancelled path).
echo "Test 13: real FAILURE (non-cancelled, no fingerprint) → left alone"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<'JSON'
[{"number":104,"title":"INFRA-y: real bug","headRefName":"chump/infra-y","statusCheckRollup":[{"name":"fast-checks","conclusion":"FAILURE","targetUrl":"https://github.com/owner/repo/actions/runs/9999013/job/444"}]}]
JSON
        ;;
    "run view 9999013 --log-failed") echo "error[E0308]: mismatched types" ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"
out=$("$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" != *"would rerun"* ]] && [[ "$out" == *"leaving alone"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: real non-cancelled failure must be left alone, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

echo ""
echo "All ci-flake-rerun tests passed."
