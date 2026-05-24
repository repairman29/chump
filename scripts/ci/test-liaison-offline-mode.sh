#!/usr/bin/env bash
# test-liaison-offline-mode.sh — INFRA-1876
#
# Verifies the offline-mode hard gate:
#   1. github-liaison.sh daemon refuses + emits liaison_offline_mode_gated when CHUMP_GITHUB_MODE=offline
#   2. cache helpers emit liaison_cache_offline_read when CHUMP_GITHUB_MODE=offline
#   3. Debounce: second call within window does NOT re-emit
#   4. Unset / non-offline values pass through unchanged

set -uo pipefail

REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"

TMP_AMBIENT="$(mktemp -t chump-test-offline-XXXXXX).jsonl"
TMP_TMPDIR="$(mktemp -d -t chump-test-offline-marker-XXXXXX)"

cleanup() { rm -f "$TMP_AMBIENT"; rm -rf "$TMP_TMPDIR"; }
trap cleanup EXIT

PASS=0
FAIL=0
note() { printf '  %s\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }

# ── (a) daemon refuses with offline mode ────────────────────────────────────
printf '== a) github-liaison.sh daemon refuses CHUMP_GITHUB_MODE=offline ==\n'
out_file="$(mktemp)"
err_file="$(mktemp)"
CHUMP_AMBIENT_LOG="$TMP_AMBIENT" \
CHUMP_GITHUB_MODE=offline \
CHUMP_LIAISON_ENABLED=1 \
    bash scripts/ops/github-liaison.sh >"$out_file" 2>"$err_file"
rc=$?
if [[ "$rc" -eq 0 ]]; then ok "exit 0"; else ko "expected exit 0, got $rc"; fi
if grep -q "offline mode — Liaison disabled" "$err_file"; then
    ok "stderr message present"
else
    ko "stderr missing 'offline mode — Liaison disabled' (got: $(cat "$err_file"))"
fi
if grep -q '"kind":"liaison_offline_mode_gated"' "$TMP_AMBIENT"; then
    ok "liaison_offline_mode_gated emitted"
else
    ko "liaison_offline_mode_gated NOT emitted (ambient: $(cat "$TMP_AMBIENT"))"
fi
rm -f "$out_file" "$err_file"

# ── (b) cache helper tag emission ────────────────────────────────────────────
printf '\n== b) cache_lookup_pr emits liaison_cache_offline_read in offline mode ==\n'
: > "$TMP_AMBIENT"
rm -f "$TMP_TMPDIR"/chump-liaison-offline-*.marker
# shellcheck source=../coord/lib/github_cache.sh
source "$REPO/scripts/coord/lib/github_cache.sh"
# Override the ambient path so emit goes to our sandbox.
_cache_ambient_path() { printf '%s' "$TMP_AMBIENT"; }
TMPDIR="$TMP_TMPDIR" CHUMP_GITHUB_MODE=offline \
    cache_lookup_pr 999999 >/dev/null 2>&1 || true
if grep -q '"kind":"liaison_cache_offline_read"' "$TMP_AMBIENT" && \
   grep -q '"helper":"cache_lookup_pr"' "$TMP_AMBIENT"; then
    ok "cache_lookup_pr emitted liaison_cache_offline_read"
else
    ko "cache_lookup_pr did NOT emit liaison_cache_offline_read (ambient: $(cat "$TMP_AMBIENT"))"
fi

# ── (c) debounce: second call within window does NOT emit ───────────────────
printf '\n== c) debounce — second call within window is silent ==\n'
count_before=$(grep -c '"kind":"liaison_cache_offline_read"' "$TMP_AMBIENT" 2>/dev/null || echo 0)
TMPDIR="$TMP_TMPDIR" CHUMP_GITHUB_MODE=offline \
    cache_lookup_pr 999998 >/dev/null 2>&1 || true
count_after=$(grep -c '"kind":"liaison_cache_offline_read"' "$TMP_AMBIENT" 2>/dev/null || echo 0)
if [[ "$count_after" -eq "$count_before" ]]; then
    ok "second call within 60s debounce window did not re-emit (count stayed at $count_before)"
else
    ko "debounce failed: count went $count_before -> $count_after"
fi

# ── (c.2) debounce: second helper emits separately ──────────────────────────
TMPDIR="$TMP_TMPDIR" CHUMP_GITHUB_MODE=offline \
    cache_lookup_checks abc123 >/dev/null 2>&1 || true
if grep -q '"helper":"cache_lookup_checks"' "$TMP_AMBIENT"; then
    ok "cache_lookup_checks emitted separately (per-helper debounce)"
else
    ko "cache_lookup_checks did NOT emit (per-helper debounce broken)"
fi

# ── (d) unset / non-offline values pass through silently ────────────────────
printf '\n== d) CHUMP_GITHUB_MODE unset or non-offline — silent ==\n'
: > "$TMP_AMBIENT"
rm -f "$TMP_TMPDIR"/chump-liaison-offline-*.marker
TMPDIR="$TMP_TMPDIR" \
    cache_query_open_prs >/dev/null 2>&1 || true
TMPDIR="$TMP_TMPDIR" CHUMP_GITHUB_MODE=online \
    cache_query_open_prs >/dev/null 2>&1 || true
TMPDIR="$TMP_TMPDIR" CHUMP_GITHUB_MODE= \
    cache_query_open_prs >/dev/null 2>&1 || true
if ! grep -q '"kind":"liaison_cache_offline_read"' "$TMP_AMBIENT"; then
    ok "no liaison_cache_offline_read events emitted (unset/online/empty)"
else
    ko "unexpected offline event in non-offline mode (ambient: $(cat "$TMP_AMBIENT"))"
fi

printf '\n== Summary: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
