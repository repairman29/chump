#!/usr/bin/env bash
# scripts/ci/test-node-refresh-worker-path-verify.sh — INFRA-8051
#
# node-refresh-chump.sh must verify the binary a worker's PATH resolves
# (RESILIENT-408), not just CHUMP_NODE_BIN. CHUMP_NODE_BIN gets installed
# current while an earlier-on-PATH chump stays stale -> expect exit 1 and a
# binary_auto_deploy_failed reason=worker_binary_sha_mismatch ambient event.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ops/node-refresh-chump.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; exit 1; }

bash -n "$SCRIPT" || fail "syntax error"
ORIGIN="$TMP/origin.git"; MIRROR="$TMP/mirror"
git init --bare -q "$ORIGIN"; git clone -q "$ORIGIN" "$MIRROR"
git -C "$MIRROR" config user.email t@example.com; git -C "$MIRROR" config user.name T
echo v1 > "$MIRROR/f.txt"; git -C "$MIRROR" add f.txt; git -C "$MIRROR" commit -q -m green
git -C "$MIRROR" push -q origin HEAD:main
GREEN_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/cargo" <<'INNER'
#!/usr/bin/env bash
mkdir -p target/release
sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
printf '#!/usr/bin/env bash\necho "chump 0.0.0-test (%s built now)"\n' "$sha" > target/release/chump
chmod +x target/release/chump
INNER
chmod +x "$TMP/bin/cargo"

mkdir -p "$TMP/stale"
printf '#!/usr/bin/env bash\necho "chump 0.0.0-test (staleaaaaaaaa built old)"\n' > "$TMP/stale/chump"
chmod +x "$TMP/stale/chump"
mkdir -p "$TMP/home" "$TMP/.chump-locks"

run() { # $1=worker bin
    env CHUMP_NODE_BIN="$TMP/installed/chump" CHUMP_WORKER_BIN="$1" CHUMP_NODE_CONVERGE_BINS=0 \
        CHUMP_NODE_REPO="$MIRROR" NODE_AMBIENT="$TMP/.chump-locks/ambient.jsonl" \
        CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs" CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA" \
        HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" bash "$SCRIPT" > "$TMP/out.log" 2>&1
}

run "$TMP/stale/chump"; rc=$?
[ "$rc" -ne 0 ] || fail "stale worker-PATH binary should fail the refresh (rc=0): $(cat "$TMP/out.log")"
grep -q '"reason":"worker_binary_sha_mismatch"' "$TMP/.chump-locks/ambient.jsonl" \
    || fail "no worker_binary_sha_mismatch event: $(cat "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null)"
ok "stale earlier-on-PATH chump -> rc!=0 + worker_binary_sha_mismatch event"

: > "$TMP/.chump-locks/ambient.jsonl"
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"
run "$TMP/installed/chump"; rc=$?
[ "$rc" -eq 0 ] || fail "current worker binary should pass (rc=$rc): $(cat "$TMP/out.log")"
! grep -q worker_binary_sha_mismatch "$TMP/.chump-locks/ambient.jsonl" || fail "false-positive mismatch event"
ok "current worker-PATH binary -> passes"
