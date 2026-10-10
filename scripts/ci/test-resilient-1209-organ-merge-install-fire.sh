#!/usr/bin/env bash
# scripts/ci/test-resilient-1209-organ-merge-install-fire.sh — RESILIENT-1209
#
# Regression slice of RESILIENT-1205 (see docs/RESILIENT-1207-NOTES.md for the
# root-cause writeup). Proves "Problem A" from that note end-to-end: once the
# green-main BINARY pin lags behind raw HEAD (routine — a coherence-sync
# commit with no build artifact), node-refresh-chump.sh must still converge
# the SOURCE TREE to origin/main HEAD *before* the binary-idempotency skip, so
# a merged organ (its manifest line + installer roster entry) is present on
# disk when _reconcile_role_organs fires chump-node-install.sh
# --reconcile-organs-only. Pre-RESILIENT-1205, the tree itself was reset to
# the (lagging) green pin, so the organ's own merge never reached the
# checkout the installer reads — it structurally could not install/fire.
#
# Fixture: a mirror with two commits —
#   PRE  (green pin):  organ-manifest.txt has NO chump-node-converge entry
#   POST (origin/main HEAD): organ-manifest.txt HAS the entry (simulates the
#                             merge that added the organ)
# A fake chump-node-install.sh (shipped in both commits) reports whether the
# organ line is present in ITS OWN checkout at --reconcile-organs-only time —
# i.e. whichever commit the SOURCE TREE actually landed on, not the binary pin.
#
# Assertion: with the RESILIENT-1205 fix (tree always converges to HEAD),
# reconcile sees the POST tree and reports organ-installed, even though the
# green-pinned binary is still the PRE sha. If node-refresh-chump.sh regressed
# to pinning the tree itself to green (pre-fix behavior), the tree would stay
# on PRE and reconcile would report organ-missing — this test would fail.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ops/node-refresh-chump.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -x "$SCRIPT" ] || fail "missing or not executable: $SCRIPT"
bash -n "$SCRIPT" || fail "syntax error"
ok "bash -n passes"

# ── Fixture: bare origin + mirror clone ─────────────────────────────────────
ORIGIN="$TMP/origin.git"
MIRROR="$TMP/mirror"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$MIRROR"
git -C "$MIRROR" config user.email test@example.com
git -C "$MIRROR" config user.name "Test"

mkdir -p "$MIRROR/scripts/setup" "$MIRROR/scripts/ops"

# Fake chump-node-install.sh: reports organ presence in ITS OWN checkout
# (i.e. the tree it's running from at invocation time) to $INSTALL_MARKER.
cat > "$MIRROR/scripts/setup/chump-node-install.sh" <<'EOF'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")/.." && pwd)"
marker="${INSTALL_MARKER:?}"
if grep -q "chump-node-converge" "$dir/ops/organ-manifest.txt" 2>/dev/null; then
    echo "organ-installed:chump-node-converge" >> "$marker"
else
    echo "organ-missing:chump-node-converge" >> "$marker"
fi
exit 0
EOF
chmod +x "$MIRROR/scripts/setup/chump-node-install.sh"

# PRE commit: organ not yet merged — manifest has no chump-node-converge line.
echo "# organ manifest (pre)" > "$MIRROR/scripts/ops/organ-manifest.txt"
git -C "$MIRROR" add scripts/setup/chump-node-install.sh scripts/ops/organ-manifest.txt
git -C "$MIRROR" commit -q -m "pre-organ baseline"
git -C "$MIRROR" push -q origin HEAD:main
PRE_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

# POST commit (origin/main HEAD): the organ's merge lands — manifest now
# declares chump-node-converge. Simulates the real #4640 merge.
echo "enabled     chump-node-converge.timer  role=muscle requires=bin:git" >> "$MIRROR/scripts/ops/organ-manifest.txt"
git -C "$MIRROR" commit -q -am "merge: add chump-node-converge organ"
git -C "$MIRROR" push -q origin HEAD:main
POST_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

# Roll the mirror's local main back to PRE so the script's own fetch+reset is
# exercised against a real remote-ahead-of-local state (same as the sibling
# node-refresh tests).
git -C "$MIRROR" checkout -q -B main "$PRE_SHA"

# ── Fake binary: already reports the PRE (green-pinned) sha, so the ─────────
# idempotency skip fires immediately after the tree converge and we exercise
# _reconcile_role_organs via the "SKIP: binary already current" path.
PRE_SHORT="$(git -C "$MIRROR" rev-parse --short=12 "$PRE_SHA")"
INSTALLED_BIN="$TMP/installed-chump"
printf '#!/usr/bin/env bash\necho "chump 0.0.0-test (%s built earlier)"\n' "$PRE_SHORT" > "$INSTALLED_BIN"
chmod +x "$INSTALLED_BIN"

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"
INSTALL_MARKER="$TMP/install-marker.log"
: > "$INSTALL_MARKER"

CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_BIN="$INSTALLED_BIN" \
CHUMP_NODE_ROLE="muscle" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$PRE_SHA" \
INSTALL_MARKER="$INSTALL_MARKER" \
HOME="$TMP/fakehome" \
    bash "$SCRIPT" > "$TMP/out.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "node-refresh-chump.sh exited $rc: $(cat "$TMP/out.log")"

# RESILIENT-1205: the SOURCE tree converges to origin/main HEAD (POST) even
# though the binary stays pinned to the lagging green sha (PRE).
LANDED_SHA="$(git -C "$MIRROR" rev-parse HEAD)"
[ "$LANDED_SHA" = "$POST_SHA" ] \
    || fail "source tree landed on $LANDED_SHA, expected origin/main HEAD $POST_SHA (green pin was $PRE_SHA)"
ok "source tree converges to origin/main HEAD despite a lagging green pin"

grep -q '"kind":"node_organs_reconciled"' "$AMBIENT" \
    || fail "expected node_organs_reconciled emitted: $(cat "$AMBIENT")"
ok "role-organ reconcile fired (node_organs_reconciled)"

# RESILIENT-1209 (this gap): because the tree landed on POST, the reconcile's
# own install script read a manifest that DOES declare the organ — install/fire
# succeeds. Pre-RESILIENT-1205, the tree would have stayed on PRE and this
# would read organ-missing instead.
[ -s "$INSTALL_MARKER" ] || fail "chump-node-install.sh --reconcile-organs-only never ran (no marker written)"
grep -q "^organ-installed:chump-node-converge$" "$INSTALL_MARKER" \
    || fail "organ merge/install did not fire — marker says: $(cat "$INSTALL_MARKER")"
ok "organ merge reaches the installer and install/fire succeeds (RESILIENT-1205 fix holds)"

exit 0
