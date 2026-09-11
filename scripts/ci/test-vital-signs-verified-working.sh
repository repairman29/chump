#!/usr/bin/env bash
# CI test for RESILIENT-1103 (Outcome-Verification Track B, cockpit surface
# build item #4): vital-signs.sh must expose a `verified_working` sign that
# reads the latest organ_success_verify_tick emitted by organ-success-verifier.sh
# (RESILIENT-1108) off the ambient stream — the "did it actually succeed"
# number, distinct from `merged_not_running` (#4)'s "is it scheduled" via
# systemctl is-active, which stays green even when the payload service dies
# on every run (the CHDIR incident this whole track exists to catch).
#
# Without the change, `.signs[] | select(.key=="verified_working")` is empty —
# this test fails on main pre-fix and passes once the sign is wired in.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VITAL_SIGNS_SH="${REPO_ROOT}/scripts/ops/vital-signs.sh"

FAIL=0
ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; FAIL=1; }

echo "[test-vital-signs-verified-working] RESILIENT-1103 — verified_working sign wired into cockpit reporting path"

if [[ ! -f "$VITAL_SIGNS_SH" ]]; then
    echo "  [FAIL] scripts/ops/vital-signs.sh not found" >&2
    exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "  [FAIL] jq not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[1. no tick ever emitted -> unknown/uninstrumented, never fabricated]"
mkdir -p "$TMP/no-tick/.chump-locks"
touch "$TMP/no-tick/.chump-locks/ambient.jsonl"
out_none="$(CHUMP_REPO_ROOT="$TMP/no-tick" CHUMP_AMBIENT_LOG="$TMP/no-tick/.chump-locks/ambient.jsonl" \
            bash "$VITAL_SIGNS_SH" --dry-run 2>/dev/null)"
key_present="$(printf '%s' "$out_none" | jq -e '.signs[]|select(.key=="verified_working")' >/dev/null 2>&1 && echo yes || echo no)"
[[ "$key_present" == "yes" ]] && ok "verified_working key present with no tick" \
  || fail "verified_working key missing from vital-signs.sh --dry-run output"
status_none="$(printf '%s' "$out_none" | jq -r '.signs[]|select(.key=="verified_working")|.status // empty')"
[[ "$status_none" == "unknown" ]] && ok "status=unknown when no organ_success_verify_tick exists" \
  || fail "expected status=unknown with no tick, got '$status_none'"

echo "[2. a healthy tick (9/10 verified-ok) -> value=90.0, status=amber]"
mkdir -p "$TMP/healthy/.chump-locks"
printf '{"ts":"2026-09-11T00:00:00Z","kind":"organ_success_verify_tick","enabled_total":10,"verified_ok":9,"failed":1,"skipped_not_loaded":0,"paged":1,"dedup_skipped":0,"failed_units":"chump-foo.timer(1/exit-code)"}\n' \
  > "$TMP/healthy/.chump-locks/ambient.jsonl"
out_healthy="$(CHUMP_REPO_ROOT="$TMP/healthy" CHUMP_AMBIENT_LOG="$TMP/healthy/.chump-locks/ambient.jsonl" \
               bash "$VITAL_SIGNS_SH" --dry-run 2>/dev/null)"
value_healthy="$(printf '%s' "$out_healthy" | jq -r '.signs[]|select(.key=="verified_working")|.value // empty')"
[[ "$value_healthy" == "90" ]] && ok "value=90 (9/10 verified-ok)" \
  || fail "expected value=90, got '$value_healthy'"
status_healthy="$(printf '%s' "$out_healthy" | jq -r '.signs[]|select(.key=="verified_working")|.status // empty')"
[[ "$status_healthy" == "amber" ]] && ok "status=amber at 90%% (amber band 80-95)" \
  || fail "expected status=amber, got '$status_healthy'"

echo "[3. latest tick wins over a stale earlier tick (0/1 verified-ok)]"
{
  printf '{"ts":"2026-09-11T00:00:00Z","kind":"organ_success_verify_tick","enabled_total":1,"verified_ok":0,"failed":1,"skipped_not_loaded":0,"paged":1,"dedup_skipped":0,"failed_units":"stale.timer(1/exit-code)"}\n'
  printf '{"ts":"2026-09-11T00:10:00Z","kind":"organ_success_verify_tick","enabled_total":5,"verified_ok":5,"failed":0,"skipped_not_loaded":0,"paged":0,"dedup_skipped":0,"failed_units":""}\n'
} > "$TMP/healthy/.chump-locks/ambient.jsonl"
out_latest="$(CHUMP_REPO_ROOT="$TMP/healthy" CHUMP_AMBIENT_LOG="$TMP/healthy/.chump-locks/ambient.jsonl" \
              bash "$VITAL_SIGNS_SH" --dry-run 2>/dev/null)"
value_latest="$(printf '%s' "$out_latest" | jq -r '.signs[]|select(.key=="verified_working")|.value // empty')"
[[ "$value_latest" == "100" ]] && ok "reads the LATEST tick (100), not the stale first one" \
  || fail "expected value=100 from latest tick, got '$value_latest'"

if [[ "$FAIL" == "0" ]]; then
    echo "[test-vital-signs-verified-working] All checks passed."
    exit 0
else
    echo "[test-vital-signs-verified-working] FAILED." >&2
    exit 1
fi
