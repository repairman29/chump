#!/usr/bin/env bash
# test-mutants-organ.sh — RESILIENT-2219
#
# Proves, with stub gh + stub cargo-mutants:
#   1. mutants-organ-tick.sh posts a record for a review-needs-mutants PR whose
#      head touches a Rust ship-gate file;
#   2. review-organ-tick.sh's mutant_record_satisfies ACCEPTS that exact output
#      (trusted author, matching patch-id, >=1 KILLED/SURVIVED line);
#   3. it REJECTS the same record against a stale patch-id, an untrusted author,
#      and a record that names no mutant;
#   4. the organ is idempotent (a second tick posts nothing) and posts nothing
#      when cargo-mutants yields no outcomes or the gate files are not Rust.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MUTANTS="$REPO_ROOT/scripts/dispatch/mutants-organ-tick.sh"
REVIEW="$REPO_ROOT/scripts/dispatch/review-organ-tick.sh"

PASS=0; FAIL=0
ok()   { echo "PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
FIX="$TMP/fix"; mkdir -p "$FIX" "$TMP/bin"

# Fixture repo: origin with refs/pull/7/head, cloned as the organ's checkout.
git init -q "$TMP/origin" && cd "$TMP/origin" || exit 1
git config user.email t@t; git config user.name t
mkdir -p crates/chump-preflight/src && echo 'fn f() -> i32 { 1 }' > crates/chump-preflight/src/x.rs
git add -A && git commit -q -m base
HEAD_SHA="$(git rev-parse HEAD)"
git update-ref refs/pull/7/head "$HEAD_SHA"
git clone -q "$TMP/origin" "$TMP/home/chump"; cd "$REPO_ROOT" || exit 1

DIFF='diff --git a/crates/chump-preflight/src/x.rs b/crates/chump-preflight/src/x.rs
index 1111111..2222222 100644
--- a/crates/chump-preflight/src/x.rs
+++ b/crates/chump-preflight/src/x.rs
@@ -1 +1 @@
-fn f() -> i32 { 0 }
+fn f() -> i32 { 1 }'
PID="$(printf '%s\n' "$DIFF" | git patch-id --stable | awk 'NR==1{print $1}')"
printf '%s\n' "$DIFF" > "$FIX/diff.txt"
printf 'crates/chump-preflight/src/x.rs\n' > "$FIX/names.txt"
echo '{"comments":[]}' > "$FIX/comments.json"
echo "$HEAD_SHA" > "$FIX/head.txt"
: > "$FIX/posted.txt"

cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
FIX="$FIX"
case "\$1 \$2" in
  "api user") echo repairman29 ;;
  "pr list")  echo 7 ;;
  "pr diff")  if [[ " \$* " == *" --name-only "* ]]; then cat "\$FIX/names.txt"; else cat "\$FIX/diff.txt"; fi ;;
  "pr view")  if [[ " \$* " == *" comments "* ]]; then cat "\$FIX/comments.json"; else cat "\$FIX/head.txt"; fi ;;
  "pr comment") while [[ \$# -gt 0 ]]; do [[ "\$1" == --body ]] && { printf '%s' "\$2" > "\$FIX/posted.txt"; break; }; shift; done ;;
esac
EOF
cat > "$TMP/bin/cargo-mutants" <<EOF
#!/usr/bin/env bash
out=""; while [[ \$# -gt 0 ]]; do [[ "\$1" == --output ]] && out="\$2"; shift; done
[[ -f "$FIX/no-outcomes" ]] && exit 0
mkdir -p "\$out/mutants.out"
echo 'crates/chump-preflight/src/x.rs:1:14: replace f -> i32 with 0' > "\$out/mutants.out/caught.txt"
echo 'crates/chump-preflight/src/x.rs:1:14: replace f -> i32 with 1' > "\$out/mutants.out/missed.txt"
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/cargo-mutants"
export PATH="$TMP/bin:$PATH"

tick() { bash "$MUTANTS" --pr 7 --checkout "$HOME/chump" --budget-secs 60 >"$TMP/tick.log" 2>&1; }

# review-organ's parser, extracted verbatim and driven with a stub GH.
eval "$(awk '/^mutant_record_satisfies\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$REVIEW")"
REPO=""; GH() { gh "$@"; }
satisfies() { # <expected-pid> <trusted-login>
    ORGAN_LOGIN="$2" mutant_record_satisfies 7 "$HEAD_SHA" "$1"
}
store_record() { # <author> ; wraps $FIX/posted.txt as a PR comment
    python3 -c '
import json, sys
print(json.dumps({"comments":[{"author":{"login":sys.argv[1]},"body":open(sys.argv[2]).read()}]}))
' "$1" "$FIX/posted.txt" > "$FIX/comments.json"
}

# 1. the organ posts a record
tick
if grep -q "^patch-id: $PID" "$FIX/posted.txt" && grep -q ': KILLED$' "$FIX/posted.txt" \
   && grep -q ': SURVIVED$' "$FIX/posted.txt" && ! grep -qi 'VERDICT' "$FIX/posted.txt"; then
    ok "organ posted a record with patch-id, KILLED + SURVIVED lines, and no VERDICT"
else fail "record shape wrong: $(cat "$FIX/posted.txt")"; cat "$TMP/tick.log" >&2; fi

# 2. the review organ's parser accepts it
store_record repairman29
satisfies "$PID" repairman29 && ok "parser accepts the organ's output (trusted author, matching patch-id)" \
    || fail "parser rejected the organ's own record"

# 3. rejections
satisfies "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" repairman29 \
    && fail "parser accepted a STALE patch-id" || ok "parser rejects a stale patch-id"
store_record someone-else
satisfies "$PID" repairman29 && fail "parser accepted an untrusted author" || ok "parser rejects an untrusted author"
printf 'head: %s\npatch-id: %s\n- nothing here\n' "$HEAD_SHA" "$PID" > "$FIX/posted.txt"
store_record repairman29
satisfies "$PID" repairman29 && fail "parser accepted a record naming no mutant" || ok "parser rejects a record naming no mutant"

# 4. idempotent: with a valid record already present, a second tick posts nothing
bash "$MUTANTS" --pr 7 --checkout "$HOME/chump" >/dev/null 2>&1   # regenerate record
store_record repairman29
: > "$FIX/posted.txt"; tick
[[ ! -s "$FIX/posted.txt" ]] && ok "second tick posts nothing when a record for the patch-id exists" \
    || fail "organ re-posted a duplicate record"

# 5. no outcomes -> nothing posted
echo '{"comments":[]}' > "$FIX/comments.json"; touch "$FIX/no-outcomes"; : > "$FIX/posted.txt"; tick
[[ ! -s "$FIX/posted.txt" ]] && ok "no cargo-mutants outcomes -> no record posted" || fail "posted a record with no mutants"
rm -f "$FIX/no-outcomes"

# 6. non-Rust gate file -> nothing posted
printf '.github/workflows/ci.yml\n' > "$FIX/names.txt"; : > "$FIX/posted.txt"; tick
[[ ! -s "$FIX/posted.txt" ]] && ok "non-Rust gate files -> no record posted" || fail "posted a record for a non-Rust gate PR"

# 7. heartbeat emitted
grep -q '"kind":"mutants_organ_tick"' "$CHUMP_AMBIENT_LOG" && ok "tick heartbeat emitted to ambient" || fail "no mutants_organ_tick heartbeat"

echo "--- $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
