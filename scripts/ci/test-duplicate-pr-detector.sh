#!/usr/bin/env bash
# scripts/ci/test-duplicate-pr-detector.sh — INFRA-1222
#
# Verifies the duplicate-PR detector groups by gap-ID, picks a winner,
# and skips groups where any PR is too fresh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/duplicate-pr-detector.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -x "$SCRIPT" ] || fail "script missing: $SCRIPT"

# Fake gh that returns canned PR JSON.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view")
        echo "fake-owner/fake-repo"; exit 0 ;;
    "api repos"*)
        [[ -f "${FAKE_PRS_FILE:-}" ]] && cat "$FAKE_PRS_FILE"
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# Helper: build a PRs JSON file. Each row: number|title|created|updated
build_prs() {
    local out="$1"; shift
    echo "[" > "$out"
    local first=1
    while [ $# -gt 0 ]; do
        IFS='|' read -r n title created updated <<< "$1"
        shift
        [[ $first -eq 0 ]] && echo "," >> "$out"
        first=0
        printf '{"number":%s,"title":"%s","created_at":"%s","updated_at":"%s"}\n' \
            "$n" "$title" "$created" "$updated" >> "$out"
    done
    echo "]" >> "$out"
}

# ── Test 1: no duplicates → nothing to do ─────────────────────────────────
old_ts="2026-01-01T00:00:00Z"
build_prs "$TMP/none.json" \
    "100|feat(INFRA-100): foo|$old_ts|$old_ts" \
    "101|feat(INFRA-101): bar|$old_ts|$old_ts"
out=$(FAKE_PRS_FILE="$TMP/none.json" "$SCRIPT" 2>&1)
echo "$out" | grep -q "no duplicate groups eligible" \
    || fail "expected 'no duplicate groups' message, got: $out"
ok "no duplicates → no-op"

# ── Test 2: two PRs for same gap (stable age) → grouped, oldest winner ────
build_prs "$TMP/dup.json" \
    "200|feat(INFRA-200): first try|2026-01-01T00:00:00Z|2026-01-01T00:00:00Z" \
    "201|feat(INFRA-200): second try|2026-01-02T00:00:00Z|2026-01-02T00:00:00Z"
out=$(FAKE_PRS_FILE="$TMP/dup.json" "$SCRIPT" 2>&1)
echo "$out" | grep -q "WINNER #200" \
    || fail "older PR should win: $out"
echo "$out" | grep -q "LOSER #201" \
    || fail "newer PR should be loser: $out"
echo "$out" | grep -q "(dry-run)" \
    || fail "default mode should be dry-run"
ok "duplicate group: oldest is winner; dry-run prints losers"

# ── Test 3: fresh PR in the group → skip entire group ─────────────────────
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
build_prs "$TMP/fresh.json" \
    "300|feat(INFRA-300): older|2026-01-01T00:00:00Z|2026-01-01T00:00:00Z" \
    "301|feat(INFRA-300): just appeared|$now_iso|$now_iso"
out=$(FAKE_PRS_FILE="$TMP/fresh.json" "$SCRIPT" 2>&1)
echo "$out" | grep -q "no duplicate groups eligible" \
    || fail "fresh PR in group should suppress action: $out"
ok "fresh PR in group → skipped (let it stabilize)"

# ── Test 4: --skip-fresh-mins 0 → fresh group fires ──────────────────────
out=$(FAKE_PRS_FILE="$TMP/fresh.json" "$SCRIPT" --skip-fresh-mins 0 2>&1)
echo "$out" | grep -q "WINNER #300" \
    || fail "--skip-fresh-mins 0 should expose group: $out"
ok "--skip-fresh-mins 0 disables freshness skip"

echo
echo "All INFRA-1222 duplicate-pr-detector tests passed."
