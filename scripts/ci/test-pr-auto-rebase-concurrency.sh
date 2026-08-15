#!/usr/bin/env bash
# scripts/ci/test-pr-auto-rebase-concurrency.sh — INFRA-2225
#
# Verifies the parallel-batch rebase behavior added to pr-auto-rebase.sh:
# with 10 BEHIND+armed PRs and MAX_CONCURRENT unset (default 5), the daemon
# must run up to 5 `gh pr update-branch` calls at once — not 1 at a time.
#
# 2026-05-29 overnight repro: 25+ PRs in flight, 8 BEHIND accumulated because
# the daemon rebased serially and couldn't keep pace with new-PR arrival.
#
# Method: stub `gh pr update-branch` to drop a marker file, sleep briefly,
# then remove the marker. A background watcher (the test's own bookkeeping,
# via marker-count sampling from every invocation) records the peak number
# of concurrently-live markers. Peak must be > 1 (proves parallelism) and
# <= MAX_CONCURRENT (proves the cap is respected).

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/pr-auto-rebase.sh"

echo "=== INFRA-2225 pr-auto-rebase concurrency tests ==="

[[ -f "$TARGET" ]] && ok "script exists" || { fail "missing $TARGET"; exit 1; }

# ── Source-contract: concurrency + throttle primitives present ────────────
for needle in \
    "MAX_CONCURRENT" \
    "CHUMP_PR_AUTO_REBASE_MAX_CONCURRENT" \
    "process_pr" \
    "wait -n" \
    "pr_auto_rebase_throttle" \
    "CHUMP_PR_AUTO_REBASE_NO_THROTTLE" \
    "avg_merge_gap_min"; do
    if grep -qF "$needle" "$TARGET"; then
        ok "contract: $needle"
    else
        fail "contract missing: $needle"
    fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/runcount"
MAXFILE="$TMP/max_concurrent"
echo 0 > "$MAXFILE"

# 10 BEHIND+armed PRs — fixture for the concurrency-batch scenario.
PR_LIST_JSON="["
for i in $(seq 1 10); do
    PR_LIST_JSON+="{\"number\": $((9100+i)), \"mergeStateStatus\": \"BEHIND\", \"autoMergeRequest\": {\"mergeMethod\": \"SQUASH\"}}"
    [[ "$i" -lt 10 ]] && PR_LIST_JSON+=","
done
PR_LIST_JSON+="]"
export PR_LIST_JSON

cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1" in
    pr)
        case "\$2" in
            list)
                cat <<JSON
$PR_LIST_JSON
JSON
                ;;
            view)
                PR_NUM="\$3"
                printf '{"headRefName":"chump/synth-concurrency-%s"}\n' "\$PR_NUM"
                ;;
            update-branch)
                MARKER="$TMP/runcount/\$\$"
                touch "\$MARKER"
                CUR="\$(ls "$TMP/runcount" | wc -l | tr -d ' ')"
                CURMAX="\$(cat "$MAXFILE" 2>/dev/null || echo 0)"
                if (( CUR > CURMAX )); then echo "\$CUR" > "$MAXFILE"; fi
                sleep 0.4
                rm -f "\$MARKER"
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$TMP/bin/gh"

# Run from a synthetic repo copy so ambient/cooldown files stay isolated.
SYN="$TMP/syn-repo"
mkdir -p "$SYN/scripts/coord" "$SYN/.chump-locks"
cp "$TARGET" "$SYN/scripts/coord/pr-auto-rebase.sh"

OUT="$(PATH="$TMP/bin:$PATH" CHUMP_PR_AUTO_REBASE_NO_LOCK=1 CHUMP_PR_AUTO_REBASE_NO_THROTTLE=1 \
    bash "$SYN/scripts/coord/pr-auto-rebase.sh" 2>&1)"

PEAK="$(cat "$MAXFILE" 2>/dev/null || echo 0)"
echo "  (peak concurrent gh update-branch calls observed: $PEAK)"

if (( PEAK > 1 )); then
    ok "ran PRs in parallel (peak concurrency=$PEAK > 1)"
else
    fail "did not observe parallelism (peak concurrency=$PEAK) — got: $OUT"
fi

if (( PEAK <= 5 )); then
    ok "respected default MAX_CONCURRENT=5 cap (peak=$PEAK)"
else
    fail "exceeded MAX_CONCURRENT=5 cap (peak=$PEAK)"
fi

REBASED_COUNT="$(echo "$OUT" | grep -cE 'OK #91[0-9]{2}')"
if [[ "$REBASED_COUNT" -eq 10 ]]; then
    ok "all 10 BEHIND PRs rebased"
else
    fail "expected 10 rebased PRs, got $REBASED_COUNT; out: $OUT"
fi

if echo "$OUT" | grep -q "rebased=10"; then
    ok "summary line reports rebased=10"
else
    fail "summary line missing rebased=10; got: $OUT"
fi

# ── Custom concurrency cap via env var ─────────────────────────────────────
echo 0 > "$MAXFILE"
OUT2="$(PATH="$TMP/bin:$PATH" CHUMP_PR_AUTO_REBASE_NO_LOCK=1 CHUMP_PR_AUTO_REBASE_NO_THROTTLE=1 \
    CHUMP_PR_AUTO_REBASE_MAX_CONCURRENT=2 \
    bash "$SYN/scripts/coord/pr-auto-rebase.sh" 2>&1)"
PEAK2="$(cat "$MAXFILE" 2>/dev/null || echo 0)"
if (( PEAK2 <= 2 )); then
    ok "CHUMP_PR_AUTO_REBASE_MAX_CONCURRENT=2 caps peak at 2 (peak=$PEAK2)"
else
    fail "CHUMP_PR_AUTO_REBASE_MAX_CONCURRENT=2 not respected (peak=$PEAK2); out: $OUT2"
fi

echo ""
echo "=== Summary: $PASS pass, $FAIL fail ==="
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
