#!/usr/bin/env bash
# scripts/ci/test-node-updater.sh — RESILIENT-345
#
# Proves scripts/ops/node-updater.sh:
#   1. Static: script present/executable, syntax clean, wired into the
#      housekeeping ORGANS table (RESILIENT-318 install path).
#   2. FRESHNESS-not-LINKAGE self-test (the core incident fix): a binary
#      that EXECUTES fine (chump --version works) but is behind
#      origin/main must FAIL self-test — proves the organ checks commit
#      freshness, not just "does the binary run". Without this check, the
#      2026-08-20 incident (3-day/114-commit-stale CJ binary that still
#      answered every call successfully) reproduces silently.
#   3. Main-moved path: pulls + rebuilds + atomically swaps the binary via
#      node-refresh-chump.sh, then RESTARTS sibling organs (proven via a
#      fake organ that records being re-executed) and the post-swap
#      self-test reports FRESH.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ops/node-updater.sh"
HOUSEKEEPING="$REPO_ROOT/scripts/setup/install-node-housekeeping.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. Static checks ────────────────────────────────────────────────────────
[[ -x "$SCRIPT" ]] || fail "node-updater.sh missing or not executable"
bash -n "$SCRIPT" || fail "syntax error in node-updater.sh"
ok "bash -n passes"

grep -q '^node-updater|scripts/ops/node-updater.sh|' "$HOUSEKEEPING" \
    || fail "node-updater not wired into the housekeeping ORGANS table"
ok "node-updater is installed via the housekeeping ORGANS table"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 2. Freshness-not-linkage self-test ──────────────────────────────────────
# Bare origin + a mirror already AT origin/main (no move needed for this
# test) so node-updater goes straight to the self-test path.
ORIGIN="$TMP/origin.git"
MIRROR="$TMP/mirror"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$MIRROR"
git -C "$MIRROR" config user.email test@example.com
git -C "$MIRROR" config user.name "Test"
echo v1 > "$MIRROR/f.txt"
git -C "$MIRROR" add f.txt
git -C "$MIRROR" commit -q -m "c1"
git -C "$MIRROR" push -q origin HEAD:main

# A binary stub that EXECUTES CLEANLY (proves --version works fine) but
# whose `self-check-staleness --json` honestly reports it is 114 commits
# behind and exits 1 (STALE) — simulating a binary that runs perfectly but
# was built before a bunch of commits landed.
STALE_BIN="$TMP/stale-chump"
cat > "$STALE_BIN" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "self-check-staleness" ]]; then
    echo '{"commits_behind":114,"classification":"stale"}'
    exit 1
fi
echo "chump 0.0.0-test (deadbeef built now) — I execute JUST FINE"
exit 0
EOF
chmod +x "$STALE_BIN"

AMBIENT="$TMP/ambient.jsonl"
CHUMP_REPO_ROOT="$MIRROR" \
CHUMP_STATE_DIR="$TMP/state" \
CHUMP_NODE_BIN="$STALE_BIN" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_UPDATER_LOGDIR="$TMP/logs1" \
HOME="$TMP/fakehome" \
    bash "$SCRIPT" > "$TMP/out1.log" 2>&1
rc=$?

[[ "$rc" -ne 0 ]] \
    || fail "node-updater exited 0 for a STALE-but-executing binary — self-test is checking linkage, not freshness (out: $(cat "$TMP/out1.log"))"
ok "node-updater exits non-zero when the binary runs fine but is commit-stale"

grep -q '"kind":"node_updater_self_test_failed"' "$AMBIENT" \
    || fail "expected node_updater_self_test_failed emitted; ambient: $(cat "$AMBIENT" 2>/dev/null)"
grep -q '"commits_behind":114' "$AMBIENT" \
    || fail "expected commits_behind:114 in the self-test-failed event; ambient: $(cat "$AMBIENT" 2>/dev/null)"
ok "self-test failure records the actual commits-behind delta, not just a pass/fail linkage check"

# ── 3. Main-moved: rebuild + restart sibling organs + self-test PASS ───────
echo v2 > "$MIRROR/f.txt"
git -C "$MIRROR" commit -q -am "c2 (advances origin/main)"
git -C "$MIRROR" push -q origin HEAD:main
NEW_SHA="$(git -C "$MIRROR" rev-parse HEAD)"
# Roll the mirror's local main back so node-updater's own `git fetch` +
# node-refresh-chump.sh's `git reset --hard` are exercised for real.
git -C "$MIRROR" reset --hard HEAD~1 -q

mkdir -p "$TMP/bin" "$MIRROR/target/release"
cat > "$TMP/bin/cargo" <<'EOF'
#!/usr/bin/env bash
# Fake `cargo build --release --bin chump`: writes a stub binary whose
# self-check-staleness computes a REAL commits-behind against origin/main
# via git, so the post-swap self-test is exercising real freshness logic,
# not a hardcoded fresh answer.
mkdir -p target/release
repo="$(pwd)"
sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
cat > target/release/chump <<INNER
#!/usr/bin/env bash
REPO="$repo"
if [[ "\$1" == "self-check-staleness" ]]; then
    behind="\$(git -C "\$REPO" rev-list HEAD..origin/main --count 2>/dev/null || echo 0)"
    if [[ "\$behind" -eq 0 ]]; then
        echo "{\"commits_behind\":0,\"classification\":\"fresh\"}"
        exit 0
    else
        echo "{\"commits_behind\":\$behind,\"classification\":\"stale\"}"
        exit 1
    fi
fi
echo "chump 0.0.0-test (\$sha built now)"
exit 0
INNER
chmod +x target/release/chump
exit 0
EOF
chmod +x "$TMP/bin/cargo"

STATE_DIR="$TMP/state2"
mkdir -p "$STATE_DIR/organs"
MARKER="$TMP/organ-ran.log"
: > "$MARKER"
cat > "$STATE_DIR/organs/test-organ.sh" <<EOF
#!/usr/bin/env bash
echo "ran pid=\$\$ at \$(date -u +%s)" >> "$MARKER"
EOF
chmod +x "$STATE_DIR/organs/test-organ.sh"
echo 999999999 > "$STATE_DIR/organs/test-organ.pid"   # stale/nonexistent pid — kill must not blow up the run

HOUSEKEEPING_FIXTURE="$TMP/fake-housekeeping.sh"
cat > "$HOUSEKEEPING_FIXTURE" <<'EOF'
ORGANS="node-updater|scripts/ops/node-updater.sh|300
test-organ|scripts/ops/test-organ.sh|900"
EOF

AMBIENT2="$TMP/ambient2.jsonl"
CHUMP_REPO_ROOT="$MIRROR" \
CHUMP_STATE_DIR="$STATE_DIR" \
CHUMP_NODE_BIN="$TMP/installed-chump" \
NODE_AMBIENT="$AMBIENT2" \
CHUMP_NODE_UPDATER_LOGDIR="$TMP/logs2" \
CHUMP_NODE_UPDATER_HOUSEKEEPING="$HOUSEKEEPING_FIXTURE" \
CHUMP_NODE_UPDATER_SYSTEMCTL_BIN="/nonexistent/systemctl-does-not-exist" \
HOME="$TMP/fakehome" \
PATH="$TMP/bin:$PATH" \
    bash "$SCRIPT" > "$TMP/out2.log" 2>&1
rc2=$?
[[ "$rc2" -eq 0 ]] || fail "main-moved run exited $rc2: $(cat "$TMP/out2.log")"
ok "main-moved run exits 0 (rebuild + restart + self-test all succeed)"

LANDED_SHA="$(git -C "$MIRROR" rev-parse HEAD)"
[[ "$LANDED_SHA" == "$NEW_SHA" ]] \
    || fail "mirror did not land on the new main sha (got $LANDED_SHA, want $NEW_SHA)"
ok "pull + build + atomic swap landed the mirror on the new origin/main commit"

grep -q '"kind":"node_updater_main_moved"' "$AMBIENT2" \
    || fail "expected node_updater_main_moved emitted; ambient: $(cat "$AMBIENT2")"

[[ -s "$MARKER" ]] \
    || fail "sibling organ (test-organ) was never re-executed after the binary swap"
ok "sibling organ was restarted after the binary swap"

grep -q '"kind":"node_updater_organs_restarted"' "$AMBIENT2" \
    || fail "expected node_updater_organs_restarted emitted; ambient: $(cat "$AMBIENT2")"
grep -q '"count":1' "$AMBIENT2" \
    || fail "expected restart count of 1 (only test-organ, node-updater excludes itself); ambient: $(cat "$AMBIENT2")"
ok "restart count reflects sibling organs only (self excluded)"

grep -q '"kind":"node_updater_self_test_passed"' "$AMBIENT2" \
    || fail "expected node_updater_self_test_passed after a successful rebuild; ambient: $(cat "$AMBIENT2")"
ok "post-swap self-test reports FRESH"

exit 0
