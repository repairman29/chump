#!/usr/bin/env bash
# scripts/ci/test-node-script-host-refresh.sh — RESILIENT-1080
#
# Proves scripts/ops/node-script-host-refresh.sh keeps a worker's SCRIPT-HOST
# checkout current with origin/main WITHOUT the destructive `reset --hard` that
# node-main-sync.sh (RESILIENT-491) uses. Depth: happy-path + the safety-
# critical edges that distinguish this organ from a plain reset:
#   1. Static: present/executable, syntax clean.
#   2. no-op: HEAD already contains target -> no ff attempted, noop emitted.
#   3. main_moved (THE point): fast-forward advances HEAD AND preserves a
#      node-local TRACKED modification (the organ-manifest.txt muscle-node
#      stopgap class) AND leaves an UNTRACKED hand-deployed file in place.
#   4. divergence guard: a local commit not on origin/main -> exit 2, nothing
#      touched, diverged emitted.
#   5. refuse: HEAD is not `main` -> exit 1, skipped_worktree emitted.
# Known gaps (not covered here): stash-pop CONFLICT path (needs an upstream edit
# to the same line as the local mod); linked-worktree .git-file refusal.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ops/node-script-host-refresh.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. Static ────────────────────────────────────────────────────────────────
[[ -x "$SCRIPT" ]] || fail "node-script-host-refresh.sh missing or not executable"
bash -n "$SCRIPT" || fail "syntax error in node-script-host-refresh.sh"
ok "bash -n passes"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ORIGIN="$TMP/origin.git"
git init --bare -q -b main "$ORIGIN" 2>/dev/null || git init --bare -q "$ORIGIN"

seed_origin() {  # seed a first commit on origin/main via a throwaway clone
    local seed="$TMP/seed"
    git clone -q "$ORIGIN" "$seed"
    git -C "$seed" config user.email test@example.com
    git -C "$seed" config user.name "Test"
    printf 'v1\n' > "$seed/f.txt"
    printf 'enabled chump-cj-worker.service role=muscle\n' > "$seed/organ-manifest.txt"
    git -C "$seed" add -A && git -C "$seed" commit -q -m "c1"
    git -C "$seed" branch -M main 2>/dev/null || true
    git -C "$seed" push -q origin main
}
advance_origin() {  # add a UNIQUE commit to origin/main (touches f.txt only)
    local a="$TMP/adv-$RANDOM$RANDOM"
    git clone -q "$ORIGIN" "$a"
    git -C "$a" config user.email test@example.com
    git -C "$a" config user.name "Test"
    printf 'v2-%s-%s\n' "$(date -u +%s)" "$RANDOM" > "$a/f.txt"
    git -C "$a" add -A && git -C "$a" commit -q -m "upstream advance $RANDOM"
    git -C "$a" push -q origin main
    git -C "$a" rev-parse HEAD
}
fresh_host() {  # a script-host clone on `main`, git identity set
    local h="$1"
    git clone -q "$ORIGIN" "$h"
    git -C "$h" config user.email test@example.com
    git -C "$h" config user.name "Test"
    git -C "$h" checkout -q -B main origin/main
}

seed_origin

# ── 2. no-op path ────────────────────────────────────────────────────────────
HOST2="$TMP/host2"; fresh_host "$HOST2"
AMB2="$TMP/amb2.jsonl"
CHUMP_SCRIPT_HOST_REPO="$HOST2" CHUMP_SCRIPT_HOST_AMBIENT="$AMB2" \
CHUMP_SCRIPT_HOST_LOGDIR="$TMP/logs2" bash "$SCRIPT" >"$TMP/out2" 2>&1
rc=$?
[[ "$rc" -eq 0 ]] || fail "no-op exited $rc (want 0): $(cat "$TMP/out2")"
grep -q '"kind":"node_script_host_noop"' "$AMB2" || fail "expected noop event; ambient: $(cat "$AMB2" 2>/dev/null)"
ok "no-op: HEAD already at target -> noop, no ff attempted"

# ── 3. main_moved: ff preserves node-local tracked mod + untracked file ──────
# Clone the host FIRST (at the old base), THEN advance origin, so the host is
# genuinely behind and must fast-forward.
HOST3="$TMP/host3"; fresh_host "$HOST3"
OLD_SHA="$(git -C "$HOST3" rev-parse HEAD)"
# node-local TRACKED modification (the load-bearing manifest-stopgap class):
printf 'enabled chump-cj-worker.service role=muscle\nenabled chump-node1-worker.service role=muscle\n' > "$HOST3/organ-manifest.txt"
# node-local UNTRACKED hand-deployed helper:
printf '#!/usr/bin/env bash\necho node-local\n' > "$HOST3/node1-worker-run.sh"
NEW_SHA="$(advance_origin)"
[[ "$OLD_SHA" != "$NEW_SHA" ]] || fail "test setup broken: origin did not advance"

AMB3="$TMP/amb3.jsonl"
CHUMP_SCRIPT_HOST_REPO="$HOST3" CHUMP_SCRIPT_HOST_AMBIENT="$AMB3" \
CHUMP_SCRIPT_HOST_LOGDIR="$TMP/logs3" bash "$SCRIPT" >"$TMP/out3" 2>&1
rc=$?
[[ "$rc" -eq 0 ]] || fail "main_moved exited $rc (want 0): $(cat "$TMP/out3")"

ACT="$(git -C "$HOST3" rev-parse HEAD)"
[[ "$ACT" == "$NEW_SHA" ]] || fail "expected HEAD fast-forwarded to $NEW_SHA, got $ACT"
ok "main_moved: fast-forwarded HEAD to $NEW_SHA"

# f.txt got the upstream update (proves the ff actually applied upstream changes)
case "$(cat "$HOST3/f.txt")" in v2-*) : ;; *) fail "expected upstream f.txt=v2-* after ff, got '$(cat "$HOST3/f.txt")'";; esac
ok "ff applied the upstream change (f.txt advanced past v1)"

# THE point: node-local tracked mod SURVIVES (a reset --hard would have lost it)
grep -q 'chump-node1-worker.service' "$HOST3/organ-manifest.txt" \
    || fail "node-local tracked mod (organ-manifest.txt) was LOST — refresh clobbered it like reset --hard"
ok "node-local TRACKED modification preserved across the fast-forward"

# untracked hand-deployed file untouched
[[ -f "$HOST3/node1-worker-run.sh" ]] || fail "untracked hand-deployed file was removed"
ok "untracked hand-deployed file preserved"

grep -q '"kind":"node_script_host_mods_stashed"' "$AMB3" || fail "expected mods_stashed event"
grep -q '"kind":"node_script_host_refreshed"' "$AMB3" || fail "expected refreshed event"
grep -q "\"to\":\"$NEW_SHA\"" "$AMB3" || fail "refreshed event should record new SHA"
ok "events: mods_stashed + refreshed(to=$NEW_SHA) emitted"

# working tree clean afterward (mods re-applied, no leftover conflict/stash cruft)
[[ -z "$(git -C "$HOST3" status --porcelain=v1 | grep -E '^UU|^AA|^DD')" ]] \
    || fail "conflict markers left in working tree after refresh"
ok "no conflict markers left in the live checkout"

# ── 4. divergence guard ──────────────────────────────────────────────────────
# Host at base with a local commit, THEN origin advances elsewhere -> the two
# histories genuinely diverge (neither is an ancestor of the other).
HOST4="$TMP/host4"; fresh_host "$HOST4"
printf 'local-only\n' > "$HOST4/local.txt"
git -C "$HOST4" add -A && git -C "$HOST4" commit -q -m "node-local commit"
DIV_HEAD="$(git -C "$HOST4" rev-parse HEAD)"
advance_origin >/dev/null

AMB4="$TMP/amb4.jsonl"
CHUMP_SCRIPT_HOST_REPO="$HOST4" CHUMP_SCRIPT_HOST_AMBIENT="$AMB4" \
CHUMP_SCRIPT_HOST_LOGDIR="$TMP/logs4" bash "$SCRIPT" >"$TMP/out4" 2>&1
rc=$?
[[ "$rc" -eq 2 ]] || fail "divergence expected exit 2, got $rc: $(cat "$TMP/out4")"
grep -q '"kind":"node_script_host_diverged"' "$AMB4" || fail "expected diverged event"
[[ "$(git -C "$HOST4" rev-parse HEAD)" == "$DIV_HEAD" ]] || fail "HEAD moved despite divergence — must be untouched"
grep -q '"kind":"node_script_host_refreshed"' "$AMB4" && fail "must NOT refresh a diverged checkout"
ok "divergence: exit 2, nothing touched, diverged emitted"

# ── 5. refuse when HEAD is not main ──────────────────────────────────────────
HOST5="$TMP/host5"; fresh_host "$HOST5"
git -C "$HOST5" checkout -q -b feature/x
AMB5="$TMP/amb5.jsonl"
CHUMP_SCRIPT_HOST_REPO="$HOST5" CHUMP_SCRIPT_HOST_AMBIENT="$AMB5" \
CHUMP_SCRIPT_HOST_LOGDIR="$TMP/logs5" bash "$SCRIPT" >"$TMP/out5" 2>&1
rc=$?
[[ "$rc" -eq 1 ]] || fail "non-main HEAD expected exit 1, got $rc: $(cat "$TMP/out5")"
grep -q '"kind":"node_script_host_skipped_worktree"' "$AMB5" || fail "expected skipped_worktree event"
ok "refuse: HEAD not on main -> exit 1, skipped_worktree emitted"

echo "=== test-node-script-host-refresh.sh: ALL PASS ==="
