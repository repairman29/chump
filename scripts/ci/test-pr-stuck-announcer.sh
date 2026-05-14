#!/usr/bin/env bash
# scripts/ci/test-pr-stuck-announcer.sh — INFRA-1251

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/pr-stuck-announcer.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -x "$SCRIPT" ] || fail "missing"

# Fake gh: scripted PR data.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view") echo "fake/repo"; exit 0 ;;
    "api repos/fake/repo/pulls?state=open"*)
        cat "${FAKE_LIST_FILE:-/dev/null}" 2>/dev/null
        exit 0 ;;
    "api repos/fake/repo/pulls/"*)
        # request like: gh api repos/fake/repo/pulls/123 --jq ...
        # $1=api, $2=repos/fake/repo/pulls/123 — extract trailing number.
        pr="${2##*/}"
        cat "${FAKE_DETAILS_DIR:-/dev/null}/$pr" 2>/dev/null
        exit 0 ;;
    "api repos/fake/repo/commits/"*)
        echo '{"check_runs":[]}'
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# Build a fake LOCK_DIR for the announcer's dedup stamps + a fake repo so
# REPO_ROOT resolves under our control.
mkdir -p "$TMP/repo/scripts/coord" "$TMP/repo/.chump-locks"
cp "$SCRIPT" "$TMP/repo/scripts/coord/pr-stuck-announcer.sh"
chmod +x "$TMP/repo/scripts/coord/pr-stuck-announcer.sh"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.email=t@t -c user.name=t add -A
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q -m s

mkdir -p "$TMP/details"
export FAKE_DETAILS_DIR="$TMP/details"

# old PR (mergeable_state=dirty, updated 3h ago) → should be ELIGIBLE
old_ts="$(date -u -v -3H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)"
echo "100|$old_ts|sha-A|feat(INFRA-3001): old dirty PR|chump/foo" > "$TMP/list.json"
echo '"dirty"' > "$TMP/details/100"
# fresh PR (1h ago) — should be SKIPPED
fresh_ts="$(date -u -v -1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
echo "200|$fresh_ts|sha-B|feat(INFRA-3002): fresh dirty|chump/bar" >> "$TMP/list.json"
echo '"dirty"' > "$TMP/details/200"
# clean PR (old) — not eligible since detail != dirty/blocked
echo "300|$old_ts|sha-C|feat(INFRA-3003): clean|chump/baz" >> "$TMP/list.json"
echo '"clean"' > "$TMP/details/300"

export FAKE_LIST_FILE="$TMP/list.json"

# ── Test 1: dry-run identifies only the eligible PR ────────────────────────
out=$(cd "$TMP/repo" && bash scripts/coord/pr-stuck-announcer.sh 2>&1)
echo "$out" | grep -q "WOULD STUCK #100" \
    || fail "expected to identify #100 dirty + old: $out"
if echo "$out" | grep -q "WOULD STUCK #200"; then
    fail "fresh PR (#200) must be skipped"
fi
if echo "$out" | grep -q "WOULD STUCK #300"; then
    fail "clean PR (#300) must be skipped"
fi
ok "identifies only old dirty PRs; skips fresh + clean"

# ── Test 2: --apply writes the dedup stamp ────────────────────────────────
# Stub broadcast.sh so the announce path doesn't try to actually broadcast.
mkdir -p "$TMP/repo/scripts/coord"
cat > "$TMP/repo/scripts/coord/broadcast.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/repo/scripts/coord/broadcast.sh"
out2=$(cd "$TMP/repo" && bash scripts/coord/pr-stuck-announcer.sh --apply 2>&1)
echo "$out2" | grep -q "STUCK #100" \
    || fail "apply mode should announce #100: $out2"
[ -f "$TMP/repo/.chump-locks/.stuck-sent/100.ts" ] \
    || fail "dedup stamp missing after apply"
ok "--apply announces + writes dedup stamp"

# ── Test 3: re-run within cooldown skips ──────────────────────────────────
out3=$(cd "$TMP/repo" && bash scripts/coord/pr-stuck-announcer.sh --apply 2>&1)
echo "$out3" | grep -q "skipped-dedup=1" \
    || fail "second run should report 1 skipped via dedup: $out3"
ok "dedup cooldown prevents resend"

# ── Test 4: cooldown=0 → resend allowed ───────────────────────────────────
out4=$(cd "$TMP/repo" && bash scripts/coord/pr-stuck-announcer.sh --apply --cooldown 0 2>&1)
echo "$out4" | grep -q "announced=1" \
    || fail "--cooldown 0 must let resend through: $out4"
ok "--cooldown 0 disables dedup"

echo
echo "All INFRA-1251 pr-stuck-announcer tests passed."
