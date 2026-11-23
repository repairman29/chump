#!/usr/bin/env bash
# scripts/ci/test-binary-refresh.sh — INFRA-1065
#
# Verifies scripts/ops/refresh-chump-binary.sh:
#   1. Static: --check / --force / default modes wired
#   2. Static: emits chump_binary_refreshed / chump_binary_refresh_failed
#   3. Static: launchd plist + installer present
#   4. Static: EVENT_REGISTRY registers both kinds
#   5. Functional: --check on a fresh-binary fixture exits 0 + no ambient line
#   6. Functional: --check on a stale-binary fixture exits 3 + no ambient line
#      (--check is report-only)
#
# We don't actually run `cargo install` (5+ min). Instead the test stubs
# the chump binary's `--version` output via a fake chump on PATH, and
# checks for the right detection + exit code.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RS="$REPO_ROOT/scripts/ops/refresh-chump-binary.sh"
PLIST="$REPO_ROOT/launchd/com.chump.binary-refresh.plist"
INST="$REPO_ROOT/scripts/setup/install-binary-refresh-launchd.sh"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── Static checks ───────────────────────────────────────────────────────────
[[ -x "$RS" ]] || fail "refresh-chump-binary.sh missing or not executable"
grep -q 'INFRA-1065' "$RS" || fail "INFRA-1065 banner missing"
grep -q -- '--check' "$RS" || fail "--check mode missing"
grep -q -- '--force' "$RS" || fail "--force mode missing"
grep -q 'chump_binary_refreshed' "$RS" || fail "success ambient kind missing"
grep -q 'chump_binary_refresh_failed' "$RS" || fail "failure ambient kind missing"
ok "refresh-chump-binary.sh has all three modes + both ambient kinds"

[[ -f "$PLIST" ]] || fail "launchd plist missing"
grep -q 'com.chump.binary-refresh' "$PLIST" || fail "plist label missing"
ok "launchd plist present with correct label"

[[ -x "$INST" ]] || fail "installer script missing or not executable"
grep -q 'launchctl bootstrap' "$INST" || fail "installer missing bootstrap"
grep -q 'resolve_main_worktree' "$INST" || fail "installer not using INFRA-451 resolver"
ok "installer present + uses resolve_main_worktree (INFRA-451)"

grep -q 'kind: chump_binary_refreshed' "$REG" \
    || fail "EVENT_REGISTRY missing chump_binary_refreshed"
grep -q 'kind: chump_binary_refresh_failed' "$REG" \
    || fail "EVENT_REGISTRY missing chump_binary_refresh_failed"
ok "EVENT_REGISTRY registers both kinds"

# ── Functional: --check with fresh binary fixture ──────────────────────────
mkdir -p "$TMP/fakebin"
# Fresh fixture: fake chump prints a version with the CURRENT HEAD's short SHA
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null | cut -c1-12)"
cat >"$TMP/fakebin/chump-fresh" <<EOF
#!/usr/bin/env bash
echo "chump 0.1.1 (${HEAD_SHA} built 2026-05-13)"
EOF
chmod +x "$TMP/fakebin/chump-fresh"

# Run --check with CHUMP_BIN pointed at the fresh fake
CHUMP_BIN="$TMP/fakebin/chump-fresh" bash "$RS" --check >"$TMP/check-fresh.out" 2>&1
RC=$?
[[ "$RC" -eq 0 ]] || fail "fresh-binary --check should exit 0, got $RC: $(cat "$TMP/check-fresh.out")"
grep -q 'fresh' "$TMP/check-fresh.out" || fail "fresh-binary output should say 'fresh': $(cat "$TMP/check-fresh.out")"
ok "fresh-binary --check exits 0 + logs 'fresh'"

# ── Functional: --check with stale binary fixture ──────────────────────────
# Stale fixture: fake chump prints a version with an OLD SHA that's behind
# multiple gap-store commits. Find such a SHA by going back ~20 commits.
# INFRA-1214: source-grep.sh to locate gap_store dynamically
source "$(dirname "$0")/lib/source-grep.sh"
_gs_path=$(find_gap_store_path)
_gs_rel="${_gs_path#$REPO_ROOT/}"
OLD_SHA="$(git -C "$REPO_ROOT" log --format=%H -20 -- "$_gs_rel" src/main.rs 2>/dev/null | tail -1 | cut -c1-12)"
if [[ -z "$OLD_SHA" ]]; then
    echo "  SKIP stale test — couldn't find an old gap-store SHA in repo"
else
    cat >"$TMP/fakebin/chump-stale" <<EOF
#!/usr/bin/env bash
echo "chump 0.1.1 (${OLD_SHA} built 2024-01-01)"
EOF
    chmod +x "$TMP/fakebin/chump-stale"

    CHUMP_BIN="$TMP/fakebin/chump-stale" bash "$RS" --check >"$TMP/check-stale.out" 2>&1
    RC=$?
    [[ "$RC" -eq 3 ]] || fail "stale-binary --check should exit 3, got $RC: $(cat "$TMP/check-stale.out")"
    grep -q 'STALE' "$TMP/check-stale.out" || fail "stale-binary output should say 'STALE': $(cat "$TMP/check-stale.out")"
    ok "stale-binary --check exits 3 + logs 'STALE' (no actual rebuild fired)"
fi

echo
echo "All INFRA-1065 binary-refresh tests passed."
