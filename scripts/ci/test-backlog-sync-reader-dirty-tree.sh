#!/usr/bin/env bash
# scripts/ci/test-backlog-sync-reader-dirty-tree.sh — RESILIENT-001
#
# The "forever" fix for the fleet-wide staleness deadlock: a node's mirror
# checkout accumulates GENERATED files in its working tree (untracked
# docs/gaps/<ID>.yaml gap mirrors, local chore(backlog) autocommits). When
# origin/main later carries a COMMITTED version of one of those same paths, the
# old reader's merge-based advance (`git pull`) ABORTED with
#     "untracked working tree files would be overwritten by merge"
# swallowed the error as "offline or conflict", and the node silently sat stale
# for hours/days — so no merged fix ever reached the iron (cuphead ~4h,
# mugman ~2 DAYS). This test:
#   RED   proves the old advance (`git pull`) genuinely JAMS on this fixture,
#   GREEN proves backlog-sync.sh --reader now CONVERGES over the same dirty tree
#         while PRESERVING gitignored runtime DBs (.chump/state.db).
#
# Depth: happy-path + adversarial-collision (the exact untracked/dir + local
# commit shapes that jammed live) + a preservation assertion for ignored DBs.
# Gaps: does not exercise the systemd timer wiring, offline-fetch handling, or
# the writer path — reader converge-logic only. Hermetic: bare-repo fixtures,
# stubbed `chump`, no network/root.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/backlog-sync.sh"
LIB="$REPO_ROOT/scripts/coord/lib/converge-mirror.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$SCRIPT" ] || fail "missing $SCRIPT"
[ -f "$LIB" ]    || fail "missing shared converge lib $LIB"
bash -n "$SCRIPT" || fail "syntax error in backlog-sync.sh"
bash -n "$LIB"    || fail "syntax error in converge-mirror.sh"
ok "bash -n passes for backlog-sync.sh and converge-mirror.sh"

# ── Build a fixture: bare origin + a node mirror with a DIRTY working tree ──
# Factored so the RED (git pull) and GREEN (reader) cases run on identical trees.
build_fixture() {
    local root="$1" origin node up
    origin="$root/origin.git"; node="$root/node"; up="$root/up"
    git init --bare -q "$origin"
    git clone -q "$origin" "$up"
    git -C "$up" config user.email t@t.co; git -C "$up" config user.name t
    mkdir -p "$up/docs/gaps" "$up/.chump"
    echo "id: A-1"                 > "$up/docs/gaps/A-1.yaml"
    printf '%s\n' ".chump/state.db" ".chump/state.db-wal" > "$up/.gitignore"
    echo "-- seed sql"             > "$up/.chump/state.sql"
    git -C "$up" add -A && git -C "$up" commit -q -m "seed"
    git -C "$up" push -q origin HEAD:main

    git clone -q "$origin" "$node"
    git -C "$node" config user.email t@t.co; git -C "$node" config user.name t
    mkdir -p "$node/docs/gaps" "$node/.chump"
    # (1) ignored runtime DB with a sentinel — a live process could be writing it;
    #     the converge MUST NOT touch it.
    echo "LIVE-DB-SENTINEL"        > "$node/.chump/state.db"
    # (2) untracked gap mirror that origin is about to commit at the SAME path
    #     — this is the file that made `git pull` abort.
    echo "id: NEW-9 (local, untracked)" > "$node/docs/gaps/NEW-9.yaml"
    # (3) a divergent local chore(backlog) autocommit on top of main.
    echo "local mirror scratch"    > "$node/.chump/scratch.txt"
    git -C "$node" add .chump/scratch.txt
    git -C "$node" commit -q -m "chore(backlog): local autocommit"

    # origin advances: commits the SAME gap-yaml path + regenerates state.sql.
    echo "id: NEW-9 (canonical from origin)" > "$up/docs/gaps/NEW-9.yaml"
    echo "-- regenerated sql"       > "$up/.chump/state.sql"
    git -C "$up" add -A && git -C "$up" commit -q -m "backlog-sync: add NEW-9, regen state.sql"
    git -C "$up" push -q origin HEAD:main
}

# ── RED: the OLD advance (git pull) must JAM on this fixture ────────────────
R="$TMP/red"; mkdir -p "$R"; build_fixture "$R"
git -C "$R/node" fetch -q origin main
if git -C "$R/node" pull --no-edit --quiet origin main >/dev/null 2>&1; then
    fail "control: 'git pull' unexpectedly SUCCEEDED — fixture no longer reproduces the jam"
fi
if [ "$(git -C "$R/node" rev-parse HEAD)" = "$(git -C "$R/node" rev-parse origin/main)" ]; then
    fail "control: 'git pull' left the node CONVERGED — jam not reproduced"
fi
ok "RED: the old merge-based advance ('git pull') jams and leaves the node stale"

# ── GREEN: backlog-sync.sh --reader must CONVERGE over the same dirty tree ──
G="$TMP/green"; mkdir -p "$G"; build_fixture "$G"
NODE="$G/node"
ORIGIN_HEAD="$(git -C "$NODE" rev-parse origin/main 2>/dev/null || true)"
# refresh the remote-tracking ref the same way a live node would have it
git -C "$NODE" fetch -q origin main
ORIGIN_HEAD="$(git -C "$NODE" rev-parse origin/main)"

# Stub `chump` so `restore --from-sql` is a no-op success (this test is about
# the git converge, not the DB rebuild).
mkdir -p "$G/bin"
cat > "$G/bin/chump" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$G/bin/chump"

CHUMP_REPO="$NODE" CHUMP_BIN="$G/bin/chump" PATH="$G/bin:$PATH" \
    bash "$SCRIPT" --reader > "$G/reader.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "reader exited $rc: $(cat "$G/reader.log")"

NODE_HEAD="$(git -C "$NODE" rev-parse HEAD)"
[ "$NODE_HEAD" = "$ORIGIN_HEAD" ] \
    || fail "reader did NOT converge: HEAD=$NODE_HEAD origin/main=$ORIGIN_HEAD (log: $(cat "$G/reader.log"))"
ok "GREEN: --reader converges the dirty node to origin/main (no jam)"

got="$(cat "$NODE/docs/gaps/NEW-9.yaml")"
[ "$got" = "id: NEW-9 (canonical from origin)" ] \
    || fail "colliding untracked gap yaml not converged to canonical: '$got'"
ok "GREEN: the untracked docs/gaps collision is overwritten with origin's canonical copy"

db="$(cat "$NODE/.chump/state.db" 2>/dev/null || echo MISSING)"
[ "$db" = "LIVE-DB-SENTINEL" ] \
    || fail "gitignored .chump/state.db was clobbered (got '$db') — converge must preserve ignored DBs"
ok "GREEN: gitignored .chump/state.db is preserved untouched (no DB corruption)"

# The converge must be LOUD about discarding local divergence (the old path was
# silent, which is why the jam went unnoticed for days).
grep -q '\[converge-mirror\] discarding' "$G/reader.log" \
    || fail "expected a loud '[converge-mirror] discarding N local commit(s)' audit line: $(cat "$G/reader.log")"
ok "GREEN: discarded local divergence is logged loudly (auditable, not a silent no-op)"

# Idempotency: a second reader pass on the now-current tree is a clean no-op.
CHUMP_REPO="$NODE" CHUMP_BIN="$G/bin/chump" PATH="$G/bin:$PATH" \
    bash "$SCRIPT" --reader > "$G/reader2.log" 2>&1 \
    || fail "second reader pass failed: $(cat "$G/reader2.log")"
[ "$(git -C "$NODE" rev-parse HEAD)" = "$ORIGIN_HEAD" ] \
    || fail "second reader pass drifted off origin/main"
ok "GREEN: reader is idempotent (already-current tree converges to a clean no-op)"

echo "ALL PASS — RESILIENT-001 reader converges over a dirty tree instead of jamming"
exit 0
