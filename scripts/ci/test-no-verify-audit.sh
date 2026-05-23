#!/usr/bin/env bash
# scripts/ci/test-no-verify-audit.sh — INFRA-1834
#
# Verifies the --no-verify audit guard:
#   1. chump-commit.sh + bot-merge.sh both have the guard wired
#   2. Empty/whitespace CHUMP_NO_VERIFY_REASON → reject + non-zero exit
#   3. Valid reason → emit kind=audit_no_verify to ambient + dedicated
#      no-verify-audit.jsonl with {session, branch, caller, reason}
#   4. Allowlist entries present in env-vars-internal.txt + event-registry-reserved.txt

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMIT_SH="$REPO_ROOT/scripts/coord/chump-commit.sh"
BOTMERGE_SH="$REPO_ROOT/scripts/coord/bot-merge.sh"
ENVVARS="$REPO_ROOT/scripts/ci/env-vars-internal.txt"
EVENTREG="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"

echo "=== INFRA-1834 --no-verify audit guard tests ==="

# ── Source contract ──────────────────────────────────────────────────────────
for needle in \
    "INFRA-1834: --no-verify audit guard" \
    "CHUMP_NO_VERIFY_REASON" \
    "audit_no_verify" \
    "no-verify-audit.jsonl"; do
    if grep -qF "$needle" "$COMMIT_SH"; then
        ok "chump-commit.sh contract: $needle"
    else
        fail "chump-commit.sh missing: $needle"
    fi
done
for needle in \
    "INFRA-1834: --no-verify audit guard" \
    "CHUMP_BOT_MERGE_NO_VERIFY" \
    "CHUMP_NO_VERIFY_REASON" \
    "audit_no_verify"; do
    if grep -qF "$needle" "$BOTMERGE_SH"; then
        ok "bot-merge.sh contract: $needle"
    else
        fail "bot-merge.sh missing: $needle"
    fi
done

# ── Allowlist entries ────────────────────────────────────────────────────────
if grep -qE "^CHUMP_NO_VERIFY_REASON$" "$ENVVARS"; then
    ok "env-vars-internal.txt: CHUMP_NO_VERIFY_REASON listed"
else
    fail "env-vars-internal.txt: CHUMP_NO_VERIFY_REASON missing"
fi
if grep -qE "^CHUMP_BOT_MERGE_NO_VERIFY$" "$ENVVARS"; then
    ok "env-vars-internal.txt: CHUMP_BOT_MERGE_NO_VERIFY listed"
else
    fail "env-vars-internal.txt: CHUMP_BOT_MERGE_NO_VERIFY missing"
fi
if grep -qE "^audit_no_verify" "$EVENTREG"; then
    ok "event-registry-reserved.txt: audit_no_verify listed"
else
    fail "event-registry-reserved.txt: audit_no_verify missing"
fi

# ── Behaviour smoke ──────────────────────────────────────────────────────────
# Build a synthetic repo, run chump-commit with --no-verify + various reasons.
# Stub git-commit via PATH so we don't actually commit anything.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SYN="$TMP/syn"
mkdir -p "$SYN/.chump-locks" "$SYN/.git"
# Minimal git layout so git rev-parse works inside the synthetic repo.
(cd "$SYN" && git init --quiet >/dev/null 2>&1 || true)
touch "$SYN/dummy-file.txt"

# Test 1: --no-verify with EMPTY reason → exit 3, no event emitted.
OUT="$(cd "$SYN" && CHUMP_NO_VERIFY_REASON='' bash "$COMMIT_SH" dummy-file.txt -m "test" --no-verify 2>&1)"
RC=$?
if [[ $RC -eq 3 ]]; then
    ok "empty CHUMP_NO_VERIFY_REASON → exit 3 (got: $RC)"
else
    fail "empty CHUMP_NO_VERIFY_REASON → expected exit 3, got: $RC; out: $OUT"
fi
if echo "$OUT" | grep -q "INFRA-1834.*requires CHUMP_NO_VERIFY_REASON"; then
    ok "empty reason: error message names INFRA-1834 + env var"
else
    fail "empty reason: missing diagnostic; got: $OUT"
fi
if [[ ! -s "$SYN/.chump-locks/no-verify-audit.jsonl" ]]; then
    ok "empty reason: no audit event emitted (no log file)"
else
    fail "empty reason: audit event emitted unexpectedly"
fi

# Test 2: --no-verify with WHITESPACE-ONLY reason → exit 3.
OUT="$(cd "$SYN" && CHUMP_NO_VERIFY_REASON='   ' bash "$COMMIT_SH" dummy-file.txt -m "test" --no-verify 2>&1)"
RC=$?
if [[ $RC -eq 3 ]]; then
    ok "whitespace-only CHUMP_NO_VERIFY_REASON → exit 3 (got: $RC)"
else
    fail "whitespace-only CHUMP_NO_VERIFY_REASON → expected exit 3, got: $RC"
fi

# Test 3: NO --no-verify in args → guard skipped, no audit emitted (commit
# itself may fail downstream — we only care that the guard isn't tripped).
rm -f "$SYN/.chump-locks/no-verify-audit.jsonl"
OUT="$(cd "$SYN" && CHUMP_NO_VERIFY_REASON='' bash "$COMMIT_SH" dummy-file.txt -m "test" 2>&1 || true)"
if echo "$OUT" | grep -q "INFRA-1834.*requires"; then
    fail "non-bypass invocation tripped the audit guard unexpectedly"
else
    ok "non-bypass invocation: guard not tripped"
fi

# Test 4: --no-verify WITH valid reason → guard passes, audit event emitted.
# The commit itself will likely fail (no real index/HEAD), but the guard
# should fire its event BEFORE the git commit attempt.
rm -f "$SYN/.chump-locks/no-verify-audit.jsonl" "$SYN/.chump-locks/ambient.jsonl"
OUT="$(cd "$SYN" && CHUMP_NO_VERIFY_REASON='emergency rescue per INFRA-1834 smoke' bash "$COMMIT_SH" dummy-file.txt -m "test" --no-verify 2>&1 || true)"
if [[ -s "$SYN/.chump-locks/no-verify-audit.jsonl" ]] && grep -q "audit_no_verify" "$SYN/.chump-locks/no-verify-audit.jsonl"; then
    ok "valid reason: audit_no_verify event emitted to no-verify-audit.jsonl"
else
    fail "valid reason: no audit event in no-verify-audit.jsonl; out: $OUT"
fi
if [[ -s "$SYN/.chump-locks/ambient.jsonl" ]] && grep -q "audit_no_verify" "$SYN/.chump-locks/ambient.jsonl"; then
    ok "valid reason: audit_no_verify event also mirrored to ambient.jsonl"
else
    fail "valid reason: audit event missing from ambient.jsonl"
fi
if grep -q '"reason":"emergency rescue per INFRA-1834 smoke"' "$SYN/.chump-locks/no-verify-audit.jsonl"; then
    ok "valid reason: reason field carried into audit event verbatim"
else
    fail "valid reason: reason field garbled in event"
fi
if grep -qE '"caller":"chump-commit.sh"' "$SYN/.chump-locks/no-verify-audit.jsonl"; then
    ok "valid reason: caller=chump-commit.sh recorded"
else
    fail "valid reason: caller field missing/wrong"
fi

# Test 5: short-form -n flag also tripped the guard.
rm -f "$SYN/.chump-locks/no-verify-audit.jsonl"
OUT="$(cd "$SYN" && CHUMP_NO_VERIFY_REASON='' bash "$COMMIT_SH" dummy-file.txt -m "test" -n 2>&1)"
RC=$?
if [[ $RC -eq 3 ]]; then
    ok "short-form -n also tripped guard (got exit 3)"
else
    fail "short-form -n bypass: expected exit 3, got: $RC"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
