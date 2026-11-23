#!/usr/bin/env bash
# CI test for CREDIBLE-299 (reporting-path slice): vital-signs.sh must expose
# the per-capability lifecycle gauge (capability-lifecycle.sh) in its output,
# not just leave it as a standalone unwired tool. Proves the composition: the
# same manifest, run through capability-lifecycle.sh's stage histogram, lands
# in vital-signs.sh's `capability_lifecycle` field.
#
# Uses a synthetic organ-manifest.txt with one unit that cannot exist on any
# host, so the evidence chain is deterministically all-false (stage 0) —
# no reliance on the real fleet's systemd state.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VITAL_SIGNS_SH="${REPO_ROOT}/scripts/ops/vital-signs.sh"

FAIL=0
ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; FAIL=1; }

echo "[test-vital-signs-capability-lifecycle] CREDIBLE-299 — gauge wired into vital-signs reporting path"

if [[ ! -f "$VITAL_SIGNS_SH" ]]; then
    echo "  [FAIL] scripts/ops/vital-signs.sh not found" >&2
    exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "  [FAIL] jq not found" >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "  [SKIP] no systemctl on this host" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts/ops"
FAKE_UNIT="chump-credible-299-test-fixture-nonexistent.service"
printf 'enabled %s test-fixture organ, never installed on any host\n' "$FAKE_UNIT" \
  > "$TMP/scripts/ops/organ-manifest.txt"

echo "[1. capability_lifecycle field appears with expected shape]"
out="$(CHUMP_REPO_ROOT="$TMP" bash "$VITAL_SIGNS_SH" --dry-run 2>/dev/null)"
if printf '%s' "$out" | jq -e '.capability_lifecycle' >/dev/null 2>&1; then
    ok "capability_lifecycle key present"
else
    fail "capability_lifecycle key missing from vital-signs.sh --dry-run output"
fi

total="$(printf '%s' "$out" | jq -r '.capability_lifecycle.total // empty')"
[[ "$total" == "1" ]] && ok "total=1 (one fixture organ)" || fail "expected total=1, got '$total'"

done_count="$(printf '%s' "$out" | jq -r '.capability_lifecycle.done_count // empty')"
[[ "$done_count" == "0" ]] && ok "done_count=0 (fixture unit never installed)" \
  || fail "expected done_count=0, got '$done_count'"

stage0="$(printf '%s' "$out" | jq -r '.capability_lifecycle.by_stage."0" // empty')"
[[ "$stage0" == "1" ]] && ok "by_stage.0=1 (nonexistent unit is stage 0 / not-built)" \
  || fail "expected by_stage.0=1, got '$stage0'"

echo "[2. per-capability data agrees with capability-lifecycle.sh run standalone]"
standalone="$(CHUMP_REPO_ROOT="$TMP" bash "${REPO_ROOT}/scripts/ops/capability-lifecycle.sh" --dry-run 2>/dev/null)"
standalone_total="$(printf '%s' "$standalone" | jq -r '.total // empty')"
[[ "$standalone_total" == "$total" ]] && ok "vital-signs total matches capability-lifecycle.sh total directly" \
  || fail "vital-signs total ($total) disagrees with standalone gauge ($standalone_total) — drifted computation"

if [[ "$FAIL" == "0" ]]; then
    echo "[test-vital-signs-capability-lifecycle] All checks passed."
    exit 0
else
    echo "[test-vital-signs-capability-lifecycle] FAILED." >&2
    exit 1
fi
