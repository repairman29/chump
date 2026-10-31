#!/usr/bin/env bash
# scripts/ci/test-mutant-run.sh — CREDIBLE-1650 AC4: proves the sandboxed
# mutant runner (scripts/review/mutant-run.sh) actually finds BOTH outcomes on
# a fixture diff — a mutant its own test catches (KILLED) and a mutant its own
# test does not exercise (SURVIVED) — and that the probe + CLI contract the
# review organ depends on (scripts/dispatch/review-organ-tick.sh) hold:
#   (a) --self-test (the organ's REVIEW_MUTANT_RUNNER_AVAILABLE probe) exits 0
#       and reports >=1 KILLED and >=1 SURVIVED;
#   (b) the default (diff) mode reproduces the same killed+survived split
#       end to end against a hand-built fixture repo, with a record carrying
#       `head:` / `patch-id:` / a KILLED line / a SURVIVED line — the exact
#       shape scripts/dispatch/review-organ-tick.sh's mutant_record_satisfies()
#       parses;
#   (c) a file with no recognized mutation operator in its added lines fails
#       closed (non-zero exit, nothing printed) rather than reporting zero
#       mutants as "all clear";
#   (d) missing required args (--test omitted) fails closed, not silently.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/review/mutant-run.sh"

PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

[[ -x "$RUNNER" ]] || { echo "FAIL: $RUNNER missing or not executable" >&2; exit 1; }

# (a) --self-test — the organ's availability probe.
if "$RUNNER" --self-test >/dev/null 2>&1; then
    ok "CREDIBLE-1650: --self-test exits 0 (review organ's availability probe passes)"
else
    bad "CREDIBLE-1650: --self-test did not exit 0"
fi
SELF_OUT="$("$RUNNER" --self-test 2>&1)"
if grep -q 'killed=[1-9]' <<< "$SELF_OUT" && grep -q 'survived=[1-9]' <<< "$SELF_OUT"; then
    ok "CREDIBLE-1650: --self-test reports >=1 killed AND >=1 survived"
else
    bad "CREDIBLE-1650: --self-test did not report both outcomes: $SELF_OUT"
fi

# (b) default diff mode against a hand-built fixture repo — same shape, driven
# through the public --repo/--head/--base/--file/--test/--patch-id contract
# rather than the internal self-test fixture.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
git -C "$TMP" config user.email "test-mutant-run@example.com"
git -C "$TMP" config user.name "test-mutant-run"
: > "$TMP/.keep"
git -C "$TMP" add .keep
git -C "$TMP" commit -q -m base
BASE_SHA="$(git -C "$TMP" rev-parse HEAD)"

cat > "$TMP/gate.sh" <<'FIXEOF'
#!/usr/bin/env bash
is_allowed() {
    local n="$1"
    if [[ "$n" -ge 100 ]]; then
        echo "allowed"
    else
        echo "denied"
    fi
}

is_special() {
    local n="$1"
    if [[ "$n" == "42" ]]; then
        echo "special"
    else
        echo "ordinary"
    fi
}
FIXEOF
cat > "$TMP/test-gate.sh" <<'TESTEOF'
#!/usr/bin/env bash
set -euo pipefail
source ./gate.sh
out="$(is_allowed 100)"
[[ "$out" == "allowed" ]]
TESTEOF
chmod +x "$TMP/gate.sh" "$TMP/test-gate.sh"
git -C "$TMP" add gate.sh test-gate.sh
git -C "$TMP" commit -q -m "add gate fixture"
HEAD_SHA="$(git -C "$TMP" rev-parse HEAD)"
PATCH_ID="$(git -C "$TMP" diff "$BASE_SHA" "$HEAD_SHA" -- gate.sh | git patch-id --stable | awk '{print $1}')"

RECORD="$("$RUNNER" --repo "$TMP" --head "$HEAD_SHA" --base "$BASE_SHA" \
    --file gate.sh --test "bash test-gate.sh" --pr 9999 --patch-id "$PATCH_ID")"
RC=$?

if [[ "$RC" -eq 0 ]]; then
    ok "CREDIBLE-1650: diff-mode run exits 0 on the fixture diff"
else
    bad "CREDIBLE-1650: diff-mode run exited $RC"
fi
if grep -q "^head: $HEAD_SHA\$" <<< "$RECORD"; then
    ok "CREDIBLE-1650: record carries 'head: <sha>'"
else
    bad "CREDIBLE-1650: record missing 'head: <sha>' line: $RECORD"
fi
if grep -qE "^patch-id: ${PATCH_ID}\$" <<< "$RECORD"; then
    ok "CREDIBLE-1650: record carries 'patch-id: <id>' matching the fixture diff"
else
    bad "CREDIBLE-1650: record missing matching 'patch-id:' line: $RECORD"
fi
if grep -q 'gate.sh.*-ge.*KILLED' <<< "$RECORD"; then
    ok "CREDIBLE-1650: the -ge mutant (caught by test-gate.sh) is reported KILLED"
else
    bad "CREDIBLE-1650: expected a KILLED -ge mutant line, got: $RECORD"
fi
if grep -q 'gate.sh.*SURVIVED' <<< "$RECORD"; then
    ok "CREDIBLE-1650: the is_special mutant (never exercised by test-gate.sh) is reported SURVIVED"
else
    bad "CREDIBLE-1650: expected a SURVIVED mutant line, got: $RECORD"
fi

# (c) no recognized mutation operator anywhere in the added lines -> fail
# closed (non-zero, nothing on stdout) — never "zero mutants, all clear".
cat > "$TMP/plain.sh" <<'PLAINEOF'
#!/usr/bin/env bash
echo "hello"
PLAINEOF
git -C "$TMP" add plain.sh
git -C "$TMP" commit -q -m "add plain file"
PLAIN_HEAD="$(git -C "$TMP" rev-parse HEAD)"
PLAIN_PID="$(git -C "$TMP" diff "$HEAD_SHA" "$PLAIN_HEAD" -- plain.sh | git patch-id --stable | awk '{print $1}')"
PLAIN_OUT=""
if PLAIN_OUT="$("$RUNNER" --repo "$TMP" --head "$PLAIN_HEAD" --base "$HEAD_SHA" \
        --file plain.sh --test "true" --pr 9999 --patch-id "$PLAIN_PID" 2>/dev/null)"; then
    bad "CREDIBLE-1650: a file with no mutable operator must fail closed (exited 0 with output '$PLAIN_OUT')"
else
    if [[ -z "$PLAIN_OUT" ]]; then
        ok "CREDIBLE-1650: no mutable operator -> non-zero exit, nothing on stdout (fail closed)"
    else
        bad "CREDIBLE-1650: no mutable operator run printed output on a non-zero exit: '$PLAIN_OUT'"
    fi
fi

# (d) missing required args fails closed.
if "$RUNNER" --repo "$TMP" --head "$HEAD_SHA" --file gate.sh --pr 1 --patch-id "$PATCH_ID" >/dev/null 2>&1; then
    bad "CREDIBLE-1650: a run with no --test must fail closed (exited 0)"
else
    ok "CREDIBLE-1650: a run with no --test fails closed (non-zero exit)"
fi

echo
echo "=== test-mutant-run: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
