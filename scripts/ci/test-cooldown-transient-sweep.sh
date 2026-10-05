#!/usr/bin/env bash
# test-cooldown-transient-sweep.sh — INFRA-471
#
# Regression test for scripts/ops/cooldown-transient-sweep.sh — the audit that
# re-enables gaps benched on TRANSIENT infra failures (timeout / wedge) while
# keeping genuine repeat-failers (ordinary rc!=0, repeat offenders) benched.
#
# Asserts (network-free, hermetic fixture repo):
#   1. cooldown files: kind=timeout and kind=wedge count as transient; kind=rc=*
#      is kept.
#   2. auto-blocked gaps: last kind=timeout is transient; last kind=rc=* is kept;
#      a gap with 2+ auto-block stamps is kept as a repeat offender.
#   3. --apply removes ONLY the transient cooldown files and leaves rc= ones.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOL="$REPO_ROOT/scripts/ops/cooldown-transient-sweep.sh"

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-cooldown-transient-sweep.sh (INFRA-471) ==="
[ -f "$TOOL" ] || { fail "tool missing: $TOOL"; echo "FAIL"; exit 1; }
[ -x "$TOOL" ] || fail "tool not executable"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-sweep-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
CD="$TMP/.chump-locks/cooldown"
mkdir -p "$CD" "$TMP/.chump"

printf '{"gap_id":"G-TO","rc":124,"kind":"timeout","until":9999999999,"agent":"1"}' > "$CD/1-G-TO.json"
printf '{"gap_id":"G-WD","rc":124,"kind":"wedge","until":9999999999,"agent":"1"}'   > "$CD/1-G-WD.json"
printf '{"gap_id":"G-RC","rc":1,"kind":"rc=1","until":9999999999,"agent":"1"}'      > "$CD/1-G-RC.json"

HAVE_SQLITE=0
if command -v sqlite3 >/dev/null 2>&1; then
  HAVE_SQLITE=1
  DB="$TMP/.chump/state.db"
  sqlite3 "$DB" "create table gaps(id text, status text, notes text);"
  sqlite3 "$DB" "insert into gaps values('AB-TO','blocked','[ts] INFRA-3832 auto-block: 3 consecutive non-ship cycles (last kind=timeout, rc=124)');"
  sqlite3 "$DB" "insert into gaps values('AB-RC','blocked','[ts] INFRA-3832 auto-block: 3 consecutive non-ship cycles (last kind=rc=1, rc=1)');"
  sqlite3 "$DB" "insert into gaps values('AB-REP','blocked','INFRA-3832 auto-block: one. later INFRA-3832 auto-block: 3 (last kind=timeout, rc=124)');"
fi

# ── 1 + 2. report classification ────────────────────────────────────────────
REP="$(CHUMP_REPO="$TMP" bash "$TOOL" 2>&1)"
echo "$REP" | grep -Eq 'total=3 +transient\(timeout/wedge\)=2 +kept\(rc/other\)=1' \
  && pass "cooldown files: 2 transient (timeout+wedge), 1 kept (rc)" \
  || fail "cooldown classification wrong; got: $(echo "$REP" | grep -A0 'PART A' -A1 | tail -1)"

if [ "$HAVE_SQLITE" = 1 ]; then
  echo "$REP" | grep -Eq 'total=3 +transient\(timeout/wedge\)=1 +kept-rc/other=1 +kept-repeat-offender=1' \
    && pass "auto-blocked: 1 transient, 1 kept-rc, 1 repeat-offender" \
    || fail "auto-block classification wrong; got: $(echo "$REP" | grep 'total=3' | tail -1)"
else
  pass "sqlite3 unavailable — Part B skipped (SKIP, not a failure)"
fi

# ── 3. --apply removes only transient cooldown files ────────────────────────
CHUMP_REPO="$TMP" bash "$TOOL" --apply >/dev/null 2>&1 || true
[ ! -e "$CD/1-G-TO.json" ] && pass "apply removed timeout cooldown file" || fail "timeout cooldown file not removed"
[ ! -e "$CD/1-G-WD.json" ] && pass "apply removed wedge cooldown file"   || fail "wedge cooldown file not removed"
[   -e "$CD/1-G-RC.json" ] && pass "apply KEPT rc= cooldown file"        || fail "rc= cooldown file was wrongly removed"

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS: cooldown-transient-sweep (0 failures)"; exit 0
else
  echo "FAIL: cooldown-transient-sweep ($fails failure(s))"; exit 1
fi
