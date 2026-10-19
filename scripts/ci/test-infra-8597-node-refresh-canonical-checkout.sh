#!/usr/bin/env bash
# scripts/ci/test-infra-8597-node-refresh-canonical-checkout.sh — INFRA-8597 (PHASE-R R5)
#
# Proves install-node-refresh-systemd.sh bakes the node's CANONICAL checkout into
# the rendered units' ExecStart — never the disposable `.claude/worktrees/*`
# linked worktree it may have been invoked from.
#
# LIVE ROOT CAUSE (cuphead, since ~2026-10-17): the installer ran from inside a
# claimed worktree and the old `$(dirname "$0")/..` candidate baked that path:
#   ExecStart=.../.claude/worktrees/infra-8571/scripts/ops/node-refresh-chump.sh
# The worktree was later reaped, so chump-node-refresh.service exited 127 every
# 30 min and the installed binary only moved when the architect chain ran a local
# cargo build --release (ICE risk on a damaged shared target tree).
#
# Fails without INFRA-8597: the pre-change candidate loop resolves
# `$(dirname "$0")/../ops/node-refresh-chump.sh` to the worktree copy, so the
# canonical-path assertion below trips.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/setup/install-node-refresh-systemd.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$INSTALLER" ] || fail "missing installer: $INSTALLER"
bash -n "$INSTALLER" || fail "syntax error in installer"
ok "bash -n passes"

# ── Fixture: a canonical checkout with a linked worktree under .claude/worktrees ──
CANON="$TMP/chump"           # the canonical, durable node checkout
mkdir -p "$CANON"
git init -q "$CANON"
git -C "$CANON" config user.email test@example.com
git -C "$CANON" config user.name "Test"

# Minimal tree the installer resolves + copies of the real installer and the
# three ExecStart targets, so we exercise the shipped resolver logic.
mkdir -p "$CANON/scripts/setup" "$CANON/scripts/ops" "$CANON/scripts/coord"
cp "$INSTALLER" "$CANON/scripts/setup/install-node-refresh-systemd.sh"
for s in scripts/ops/node-refresh-chump.sh scripts/ops/node-script-host-refresh.sh scripts/coord/node-deploy-lag-watchdog.sh; do
    printf '#!/usr/bin/env bash\n: node refresh target stub\n' > "$CANON/$s"
    chmod +x "$CANON/$s"
done
git -C "$CANON" add -A
git -C "$CANON" commit -q -m "fixture"

# The reaped-worktree trap: invoke the installer from INSIDE a linked worktree.
WT="$CANON/.claude/worktrees/infra-test"
git -C "$CANON" worktree add -q "$WT" HEAD 2>/dev/null \
    || { git -C "$CANON" worktree add -q -b infra-test-wt "$WT" HEAD; }
[ -f "$WT/scripts/setup/install-node-refresh-systemd.sh" ] || fail "worktree missing installer copy"
ok "linked worktree created under .claude/worktrees/"

# ── Stub systemctl/loginctl/chump so the installer renders without touching the host ──
STUB="$TMP/bin"
mkdir -p "$STUB"
for c in systemctl loginctl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/$c"; chmod +x "$STUB/$c"
done
# No `chump` on PATH → install target falls through to the ~/.local/bin default.

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"

# Run the installer FROM the worktree, with CHUMP_NODE_REPO UNSET so resolution
# must fall through to the git-common-dir (main worktree) path — the exact
# cuphead condition.
( cd "$WT" && \
  env -u CHUMP_NODE_REPO HOME="$FAKE_HOME" PATH="$STUB:$PATH" \
      bash "$WT/scripts/setup/install-node-refresh-systemd.sh" ) \
  > "$TMP/install.log" 2>&1 \
  || { cat "$TMP/install.log"; fail "installer exited non-zero"; }
ok "installer rendered units from inside a worktree"

UNIT_DIR="$FAKE_HOME/.config/systemd/user"
assert_canonical_unit() {
    local unit="$1"
    local f="$UNIT_DIR/$unit"
    [ -f "$f" ] || fail "$unit not rendered"
    local execline
    execline="$(grep -E '^ExecStart=' "$f" || true)"
    [ -n "$execline" ] || fail "$unit has no ExecStart"
    case "$execline" in
        *".claude/worktrees/"*) fail "$unit ExecStart baked a disposable worktree path: $execline" ;;
    esac
    case "$execline" in
        *"$CANON/scripts/"*) ok "$unit ExecStart points at the canonical checkout" ;;
        *) fail "$unit ExecStart does not point at canonical checkout $CANON: $execline" ;;
    esac
}

assert_canonical_unit chump-node-refresh.service
assert_canonical_unit chump-node-deploy-lag-watchdog.service
assert_canonical_unit chump-script-host-refresh.service

# Belt-and-suspenders: NO rendered unit anywhere may carry a worktree path.
if grep -RE '^(ExecStart|WorkingDirectory)=' "$UNIT_DIR" 2>/dev/null | grep -q '\.claude/worktrees/'; then
    fail "a rendered unit carries a .claude/worktrees/ path"
fi
ok "no rendered unit carries a .claude/worktrees/ path"

echo "ALL PASS — install-node-refresh-systemd.sh renders canonical ExecStart paths (INFRA-8597)"
