#!/usr/bin/env bash
# scripts/ci/test-operator-id.sh — INFRA-1297

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/coord/lib/operator-id.sh"
BROADCAST="$REPO_ROOT/scripts/coord/broadcast.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -f "$LIB" ] || fail "missing $LIB"

# Sandbox: fake repo + fake HOME so persistence is isolated.
mkdir -p "$TMP/repo/scripts/coord/lib" "$TMP/repo/.chump-locks" "$TMP/home/.chump"
cp "$LIB"       "$TMP/repo/scripts/coord/lib/operator-id.sh"
cp "$BROADCAST" "$TMP/repo/scripts/coord/broadcast.sh"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.email=t@t -c user.name=t add -A
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q -m s

export HOME="$TMP/home"

# ── Test 1: first call generates + persists ──────────────────────────────
id1=$(cd "$TMP/repo" && bash -c 'source scripts/coord/lib/operator-id.sh; operator_id')
[[ "$id1" =~ ^operator-[0-9a-f]{8}$ ]] || fail "generated id wrong shape: $id1"
[ -f "$TMP/repo/.chump/operator_id" ] || fail "repo .chump/operator_id not written"
[ -f "$HOME/.chump/operator_id" ]      || fail "home .chump/operator_id not written"
ok "first call: generates + persists to both repo + home"

# ── Test 2: second call returns the same id (stability) ──────────────────
id2=$(cd "$TMP/repo" && bash -c 'source scripts/coord/lib/operator-id.sh; operator_id')
[[ "$id1" == "$id2" ]] || fail "second call returned different id: '$id1' vs '$id2'"
ok "second call: stable (same id as first)"

# ── Test 3: env override beats files ──────────────────────────────────────
id3=$(cd "$TMP/repo" && CHUMP_OPERATOR_ID=operator-explicit \
      bash -c 'source scripts/coord/lib/operator-id.sh; operator_id')
[[ "$id3" == "operator-explicit" ]] || fail "env override ignored: $id3"
ok "CHUMP_OPERATOR_ID env override honored"

# ── Test 4: fresh repo without ~/.chump file → new generation ────────────
rm -f "$TMP/repo/.chump/operator_id" "$HOME/.chump/operator_id"
id4=$(cd "$TMP/repo" && bash -c 'source scripts/coord/lib/operator-id.sh; operator_id')
[[ "$id4" =~ ^operator-[0-9a-f]{8}$ ]] || fail "fresh gen wrong shape: $id4"
[[ "$id4" != "$id1" ]] || fail "expected NEW id after deleting both files; got same"
ok "deleting both files → fresh generation"

# ── Test 5: home file present, repo absent → backfilled to repo ──────────
rm -f "$TMP/repo/.chump/operator_id"
existing="$id4"
id5=$(cd "$TMP/repo" && bash -c 'source scripts/coord/lib/operator-id.sh; operator_id')
[[ "$id5" == "$existing" ]] || fail "expected to reuse home id: home=$existing got=$id5"
[ -f "$TMP/repo/.chump/operator_id" ] || fail "repo file should be backfilled"
ok "home-only → reuse + backfill to repo"

# ── Test 6: broadcast.sh includes operator_id field in every event ───────
out=$(cd "$TMP/repo" && bash scripts/coord/broadcast.sh STUCK INFRA-9001 "test" >/dev/null 2>&1 && \
      tail -1 .chump-locks/ambient.jsonl)
echo "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d.get('operator_id', '').startswith('operator-'), d
" || fail "STUCK missing operator_id: $out"
ok "broadcast.sh STUCK includes operator_id field"

out2=$(cd "$TMP/repo" && bash scripts/coord/broadcast.sh FEEDBACK proposal subj "x" >/dev/null 2>&1 && \
       tail -1 .chump-locks/ambient.jsonl)
echo "$out2" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d.get('operator_id', '').startswith('operator-'), d
" || fail "FEEDBACK missing operator_id: $out2"
ok "broadcast.sh FEEDBACK includes operator_id field"

echo
echo "All INFRA-1297 operator-id tests passed."
