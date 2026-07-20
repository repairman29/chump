#!/usr/bin/env bash
# scripts/ci/test-pr-stuck-observability.sh — INFRA-2728
#
# Smoke test: pr-stuck-announcer.sh emits the observability surface added by
# INFRA-2728 — failure_class on pr_stuck_announced, a pr_stuck_announcer_summary
# event on every run (cost: api_calls, duration_s), and pr_stuck_announcer_error
# on abort. Companion to test-pr-stuck-announcer.sh (behavior); this file only
# checks the ambient event contract.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/pr-stuck-announcer.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -x "$SCRIPT" ] || fail "missing $SCRIPT"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view") echo "fake/repo"; exit 0 ;;
    "api repos/fake/repo/pulls?state=open"*)
        cat "${FAKE_LIST_FILE:-/dev/null}" 2>/dev/null
        exit 0 ;;
    "api repos/fake/repo/pulls/"*)
        pr="${2##*/}"
        cat "${FAKE_DETAILS_DIR:-/dev/null}/$pr" 2>/dev/null
        exit 0 ;;
    "api repos/fake/repo/commits/"*)
        cat "${FAKE_CHECKS_FILE:-/dev/null}" 2>/dev/null || echo '{"check_runs":[]}'
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

mkdir -p "$TMP/repo/scripts/coord/lib" "$TMP/repo/.chump-locks"
cp "$SCRIPT" "$TMP/repo/scripts/coord/pr-stuck-announcer.sh"
cp "$REPO_ROOT/scripts/coord/lib/ambient-write.sh" "$TMP/repo/scripts/coord/lib/ambient-write.sh"
chmod +x "$TMP/repo/scripts/coord/pr-stuck-announcer.sh"
cat > "$TMP/repo/scripts/coord/broadcast.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/repo/scripts/coord/broadcast.sh"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.email=t@t -c user.name=t add -A
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q -m s

AMBIENT="$TMP/repo/.chump-locks/ambient.jsonl"
touch "$AMBIENT"

mkdir -p "$TMP/details"
export FAKE_DETAILS_DIR="$TMP/details"

# PR #100: blocked with a known-flaky failing check → failure_class=transient.
old_ts="$(date -u -v -3H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)"
echo "100|$old_ts|sha-A|feat(INFRA-3001): flaky-blocked PR|chump/foo" > "$TMP/list.json"
echo '"blocked"' > "$TMP/details/100"
export FAKE_LIST_FILE="$TMP/list.json"
export FAKE_CHECKS_FILE="$TMP/checks.json"
echo '{"check_runs":[{"conclusion":"failure","name":"ci-flake-rerun-me"}]}' > "$TMP/checks.json"

out=$(cd "$TMP/repo" && bash scripts/coord/pr-stuck-announcer.sh --apply 2>&1)
echo "$out" | grep -q "\[transient\]" || fail "expected transient classification in stdout: $out"
ok "flaky-named failing check classifies as transient"

grep -q '"kind":"pr_stuck_announced"' "$AMBIENT" || fail "pr_stuck_announced not emitted"
grep '"kind":"pr_stuck_announced"' "$AMBIENT" | grep -q '"failure_class":"transient"' \
    || fail "pr_stuck_announced missing failure_class=transient: $(grep 'pr_stuck_announced' "$AMBIENT")"
ok "pr_stuck_announced carries failure_class"

grep -q '"kind":"pr_stuck_announcer_summary"' "$AMBIENT" || fail "pr_stuck_announcer_summary not emitted"
summary_line="$(grep '"kind":"pr_stuck_announcer_summary"' "$AMBIENT" | tail -1)"
for field in eligible announced skipped_dedup api_calls duration_s; do
    echo "$summary_line" | grep -q "\"$field\":" || fail "summary missing field $field: $summary_line"
done
ok "pr_stuck_announcer_summary reports cost (api_calls, duration_s) + reach"

# ── dirty (real merge conflict) → permanent ────────────────────────────────
rm -f "$TMP/repo/.chump-locks/.stuck-sent"/*.ts 2>/dev/null || true
echo "200|$old_ts|sha-B|feat(INFRA-3002): dirty PR|chump/bar" > "$TMP/list.json"
echo '"dirty"' > "$TMP/details/200"
echo '{"check_runs":[]}' > "$TMP/checks.json"
out2=$(cd "$TMP/repo" && bash scripts/coord/pr-stuck-announcer.sh --apply --cooldown 0 2>&1)
echo "$out2" | grep -q "\[permanent\]" || fail "dirty (merge conflict) must classify as permanent: $out2"
ok "merge conflict (dirty) classifies as permanent"

# ── error path: no repo nwo → pr_stuck_announcer_error ─────────────────────
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view") exit 0 ;;  # empty output → no nameWithOwner
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
out3=$(cd "$TMP/repo" && bash scripts/coord/pr-stuck-announcer.sh --apply 2>&1 || true)
grep -q '"kind":"pr_stuck_announcer_error"' "$AMBIENT" || fail "pr_stuck_announcer_error not emitted on repo-lookup failure: $out3"
ok "repo-lookup failure emits pr_stuck_announcer_error"

echo
echo "All INFRA-2728 pr-stuck observability tests passed."
