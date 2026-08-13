#!/usr/bin/env bash
# scripts/ci/test-gh-token-guard.sh — RESILIENT-018
#
# Smoke test for scripts/ci/lib/ci-guards.sh::check_gh_token_or_skip.
#   1. GH_TOKEN/GITHUB_TOKEN unset -> guard exits 0, prints WARN, emits
#      kind=ci_gh_token_missing_skip.
#   2. GH_TOKEN set -> guard is a no-op, script continues past it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/ci/lib/ci-guards.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ -f "$LIB" ]] || fail "ci-guards.sh not found at $LIB"

# ── Fake `chump` on PATH that records ambient-emit invocations ──────────────
mkdir -p "$TMP/fakebin"
EMIT_LOG="$TMP/emit.log"
cat >"$TMP/fakebin/chump" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "ambient" && "\${2:-}" == "emit" ]]; then
  echo "\$*" >> "$EMIT_LOG"
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/fakebin/chump"

# Script under test: a minimal caller that sources ci-guards.sh, calls the
# guard, then would (if not skipped) print a marker + call `gh api`.
CALLER="$TMP/caller.sh"
cat >"$CALLER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$LIB"
check_gh_token_or_skip
echo "REACHED_GH_CALL"
EOF
chmod +x "$CALLER"

# ── 1. GH_TOKEN unset -> skip + WARN + ambient emit, exit 0 ────────────────
echo "[1. GH_TOKEN/GITHUB_TOKEN unset]"
rm -f "$EMIT_LOG"
set +e
OUT_UNSET="$(env -u GH_TOKEN -u GITHUB_TOKEN PATH="$TMP/fakebin:$PATH" "$CALLER" 2>&1)"
RC_UNSET=$?
set -e

[[ "$RC_UNSET" -eq 0 ]] || fail "guard did not exit 0 with token unset (rc=$RC_UNSET)"
echo "$OUT_UNSET" | grep -q "WARN" || fail "no WARN message printed with token unset"
echo "$OUT_UNSET" | grep -q "REACHED_GH_CALL" && fail "caller script continued past the guard with token unset"
[[ -f "$EMIT_LOG" ]] || fail "no ambient emit recorded with token unset"
grep -q "ci_gh_token_missing_skip" "$EMIT_LOG" || fail "ambient emit missing kind=ci_gh_token_missing_skip"
grep -q "workflow_name=" "$EMIT_LOG" || fail "ambient emit missing workflow_name field"
grep -q "job_name=" "$EMIT_LOG" || fail "ambient emit missing job_name field"
ok "guard skips + WARNs + emits ci_gh_token_missing_skip, exits 0"

# ── 2. GH_TOKEN set -> no skip, caller continues ────────────────────────────
echo "[2. GH_TOKEN set]"
rm -f "$EMIT_LOG"
set +e
OUT_SET="$(env GH_TOKEN="dummy-token" PATH="$TMP/fakebin:$PATH" "$CALLER" 2>&1)"
RC_SET=$?
set -e

[[ "$RC_SET" -eq 0 ]] || fail "caller exited non-zero with token set (rc=$RC_SET)"
echo "$OUT_SET" | grep -q "REACHED_GH_CALL" || fail "guard blocked the caller even though GH_TOKEN was set"
[[ ! -f "$EMIT_LOG" ]] || fail "guard emitted ambient event even though GH_TOKEN was set"
ok "guard is a no-op when GH_TOKEN is set"

echo ""
echo "=== ALL PASS ==="
