#!/usr/bin/env bash
# scripts/ci/test-resilient-1215-converge-reconciles-organs.sh — RESILIENT-1215
#
# RESILIENT-1205 slice: wires the role-organ reconcile (RESILIENT-1035, already
# present in node-refresh-chump.sh) into node-converge.sh — the auto-converge
# organ — so a newly-merged organ (manifest line + installer roster entry)
# reaches the installer the INSTANT this organ's own converge lands it, rather
# than waiting on the separate, slower chump-organ-reconcile.timer cadence.
#
# Proves:
#   1. after a converge that actually moves HEAD, node-converge.sh invokes
#      chump-node-install.sh --role <role> --reconcile-organs-only against the
#      just-converged tree, and emits node_organs_reconciled;
#   2. an idempotent no-op converge (tree already current — nothing new
#      merged) does NOT fire the reconcile.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ops/node-converge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$SCRIPT" ] || fail "missing $SCRIPT"
bash -n "$SCRIPT" || fail "syntax error in $SCRIPT"
ok "bash -n passes"

# ── Fixture: bare origin + a checkout clone, origin advanced with a merged ──
# organ (manifest line + fake installer roster entry) ------------------------
ORIGIN="$TMP/origin.git"
CHECKOUT="$TMP/checkout"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$CHECKOUT"
git -C "$CHECKOUT" config user.email test@example.com
git -C "$CHECKOUT" config user.name "Test"

mkdir -p "$CHECKOUT/scripts/ops" "$CHECKOUT/scripts/setup"
echo "# organ manifest (pre)" > "$CHECKOUT/scripts/ops/organ-manifest.txt"

# Fake chump-node-install.sh: records every --reconcile-organs-only invocation
# (args + whether the manifest it reads has the new organ line) to $RECONCILE_MARKER.
cat > "$CHECKOUT/scripts/setup/chump-node-install.sh" <<'EOF'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")/.." && pwd)"
marker="${RECONCILE_MARKER:?}"
role="unknown"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role) role="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if grep -q "chump-node-converge" "$dir/ops/organ-manifest.txt" 2>/dev/null; then
    echo "reconciled:role=$role:organ-present" >> "$marker"
else
    echo "reconciled:role=$role:organ-missing" >> "$marker"
fi
exit 0
EOF
chmod +x "$CHECKOUT/scripts/setup/chump-node-install.sh"

git -C "$CHECKOUT" add .
git -C "$CHECKOUT" commit -q -m "base"
git -C "$CHECKOUT" push -q origin HEAD:main
BASE_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"

# Advance origin/main with the organ's merge: manifest now declares it.
echo "enabled     chump-node-converge.timer  role=muscle requires=bin:git" >> "$CHECKOUT/scripts/ops/organ-manifest.txt"
git -C "$CHECKOUT" commit -q -am "merge: add chump-node-converge organ"
git -C "$CHECKOUT" push -q origin HEAD:main
NEW_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"

# Roll the checkout's working tree back to base so it is genuinely behind.
git -C "$CHECKOUT" reset --hard -q "$BASE_SHA"

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"
RECONCILE_MARKER="$TMP/reconcile-marker.log"
: > "$RECONCILE_MARKER"

run_converge() {
    CHUMP_NODE_REPO="$CHECKOUT" \
    CHUMP_NODE_ROLE="muscle" \
    NODE_AMBIENT="$AMBIENT" \
    CHUMP_NODE_CONVERGE_LOGDIR="$TMP/logs" \
    RECONCILE_MARKER="$RECONCILE_MARKER" \
    HOME="$TMP/fakehome" \
    CHUMP_STATE_DIR="$TMP/fakehome/.chump" \
        bash "$SCRIPT" > "$1" 2>&1
}

# ── Test 1: a converge that lands the organ's merge reconciles role organs ──
run_converge "$TMP/out1.log" || fail "converge run 1 exited non-zero: $(cat "$TMP/out1.log")"
[ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$NEW_SHA" ] \
    || fail "checkout did not converge to origin/main HEAD"

grep -q '"kind":"node_organs_reconciled"' "$AMBIENT" \
    || fail "expected node_organs_reconciled after a converge that moved HEAD: $(cat "$AMBIENT" 2>/dev/null)"
ok "converge that lands a merge emits node_organs_reconciled"

[ -s "$RECONCILE_MARKER" ] || fail "chump-node-install.sh --reconcile-organs-only never ran (no marker written)"
grep -q "^reconciled:role=muscle:organ-present$" "$RECONCILE_MARKER" \
    || fail "reconcile did not see the newly-merged organ in the converged tree — marker says: $(cat "$RECONCILE_MARKER")"
ok "role-organ reconcile ran against the just-converged tree and saw the merged organ"

# ── Test 2: idempotent no-op converge does NOT re-fire the reconcile ────────
: > "$AMBIENT"
: > "$RECONCILE_MARKER"
run_converge "$TMP/out2.log" || fail "converge run 2 (idempotent) exited non-zero: $(cat "$TMP/out2.log")"
grep -q '"kind":"node_converge_skipped"' "$AMBIENT" \
    || fail "expected node_converge_skipped on an already-current tree: $(cat "$AMBIENT" 2>/dev/null)"
[ ! -s "$RECONCILE_MARKER" ] \
    || fail "reconcile fired on a no-op converge (nothing new merged): $(cat "$RECONCILE_MARKER")"
ok "idempotent no-op converge does not re-fire the role-organ reconcile"

printf '\033[0;32mALL PASS\033[0m scripts/ci/test-resilient-1215-converge-reconciles-organs.sh\n'
