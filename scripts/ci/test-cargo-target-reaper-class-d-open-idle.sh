#!/usr/bin/env bash
# test-cargo-target-reaper-class-d-open-idle.sh — RESILIENT-1635
#
# Validates the RESILIENT-1635 extension of cargo-target-reaper Class D: a
# dispatch worktree whose PR is still OPEN also has its build output reaped when
# it is IDLE, and stale bot-merge-active-dispatch-*.path markers are removed.
#
#   (a) an idle open-PR worktree older than 2h loses target/ + .cargo-test-target/,
#       and its source files are byte-unchanged;
#   (b) a worktree with a live lease, a process cwd inside, OR a running dispatch
#       for that gap is never touched (one case each);
#   (c) a stale bot-merge-active-dispatch-*.path marker is removed, a fresh one kept;
#   (d) an open-PR worktree with build activity under 2h old is kept;
#   plus a dirty-source open-PR worktree is kept (Chief rule 2026-10-19 11:55Z).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="${REPO_ROOT}/scripts/ops/cargo-target-reaper.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-cargo-target-reaper-class-d-open-idle.sh ==="

TMP="$(mktemp -d)"
declare -a BG_PIDS=()
cleanup() {
    local p
    for p in "${BG_PIDS[@]+"${BG_PIDS[@]}"}"; do kill "$p" 2>/dev/null || true; done
    rm -rf "$TMP"
}
trap cleanup EXIT

FAKE_REPO="$TMP/repo"
WT_BASE="$FAKE_REPO/.claude/worktrees"
LOCKS="$FAKE_REPO/.chump-locks"
mkdir -p "$WT_BASE" "$LOCKS"
AMBIENT="$LOCKS/ambient.jsonl"
: > "$AMBIENT"

# stub gh: `gh pr list --head <branch> ...` → OPEN for any branch with "open".
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
branch=""
prev=""
for a in "$@"; do
    [[ "$prev" == "--head" ]] && branch="$a"
    prev="$a"
done
case "$branch" in
    *merged*|*closed*) echo '[{"number":111,"state":"MERGED"}]' ;;
    *open*)            echo '[{"number":222,"state":"OPEN"}]' ;;
    *)                 echo '[]' ;;
esac
GH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export CHUMP_CACHE_DB="$TMP/nonexistent-cache.db"  # force gh fallback

# Backdate build dirs so the 2h idle window treats them as stale (idle).
STALE_TOUCH="3 hours ago"

# mk_wt <name> <branch> — a real git repo on <branch> with committed source and
# backdated build dirs. Echoes the worktree path.
mk_wt() {
    local name="$1" branch="$2" wt="$WT_BASE/$1"
    mkdir -p "$wt"
    git -C "$wt" init -q
    git -C "$wt" config user.email t@t.t
    git -C "$wt" config user.name t
    git -C "$wt" checkout -q -b "$branch"
    echo "fn main() {}" > "$wt/main.rs"
    git -C "$wt" add -A
    git -C "$wt" -c commit.gpgsign=false commit -q -m init
    mkdir -p "$wt/target/debug" "$wt/.cargo-test-target/debug"
    echo artifact > "$wt/target/debug/chump"
    echo artifact > "$wt/.cargo-test-target/debug/chump"
    touch -d "$STALE_TOUCH" "$wt/target" "$wt/.cargo-test-target"
    printf '%s' "$wt"
}

# Distinct gap-id-shaped names (digit suffix) so the dispatch/activity matchers
# can't false-match each other or the parent dispatch's prompt.
WT_REAP="$(mk_wt resilient-1801 chump/resilient-1801-open)"
WT_LEASE="$(mk_wt resilient-1802 chump/resilient-1802-open)"
WT_CWD="$(mk_wt resilient-1803 chump/resilient-1803-open)"
WT_DISPATCH="$(mk_wt resilient-1804 chump/resilient-1804-open)"
WT_DIRTY="$(mk_wt resilient-1805 chump/resilient-1805-open)"
WT_ACTIVE="$(mk_wt resilient-1806 chump/resilient-1806-open)"

# (b) live lease naming WT_LEASE.
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$LOCKS/lease-1802.json" <<EOF
{"worktree":"$WT_LEASE","gap_id":"RESILIENT-1802","heartbeat_at":"$NOW_ISO","taken_at":"$NOW_ISO"}
EOF

# (b) a live process whose cwd is inside WT_CWD.
( cd "$WT_CWD" && exec sleep 300 ) &
BG_PIDS+=("$!")

# (b) a running `chump dispatch` for WT_DISPATCH's gap (argv names RESILIENT-1804).
( exec -a "chump dispatch RESILIENT-1804 --backend headless" sleep 300 ) &
BG_PIDS+=("$!")

# (c) markers: one stale (> grace), one fresh (within grace).
MARK_STALE="$LOCKS/bot-merge-active-dispatch-stale.path"
MARK_FRESH="$LOCKS/bot-merge-active-dispatch-fresh.path"
echo "/tmp/log-stale" > "$MARK_STALE"
echo "/tmp/log-fresh" > "$MARK_FRESH"
touch -d "1 hour ago" "$MARK_STALE"   # > 15m grace → reap

# (d) WT_ACTIVE: build activity within 2h → keep. Un-backdate its build dirs.
touch "$WT_ACTIVE/target" "$WT_ACTIVE/.cargo-test-target"

# (dirty) WT_DIRTY: a tracked change in the source tree → keep.
echo "fn main() { /* edited */ }" > "$WT_DIRTY/main.rs"

# Record source checksums to prove the reaper never touches source bytes.
src_sum() { git -C "$1" hash-object main.rs; }
REAP_SRC_BEFORE="$(src_sum "$WT_REAP")"

# Regression pin (as in the RESILIENT-1620 test): env lock store points at a
# foreign dir so Class D must find the lease in the SCANNED repo's own store.
FOREIGN_LOCKS="$TMP/foreign-locks"
mkdir -p "$FOREIGN_LOCKS"

run_reaper() {
    CHUMP_LOCK_DIR="$FOREIGN_LOCKS" \
    CHUMP_STATE_DB="$TMP/foreign-state.db" \
    REAPER_REPO_ROOT="$FAKE_REPO" \
    CHUMP_WORKTREE_BASE="$WT_BASE" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_REAPER_SAFETY_CHECK=1 \
    CHUMP_REAPER_BOT_MERGE_GRACE_MIN=15 \
        bash "$REAPER" --class-d-only --execute 2>&1
}

echo "--- Class D open-PR idle reap ---"
OUT="$(run_reaper)" || fail "reaper exited non-zero"
echo "$OUT" | sed 's/^/    /'

# (a) idle open-PR worktree reaped; source byte-identical.
[[ ! -d "$WT_REAP/target" ]]             || fail "(a) idle open-PR target/ not reaped"
[[ ! -d "$WT_REAP/.cargo-test-target" ]] || fail "(a) idle open-PR .cargo-test-target/ not reaped"
[[ -f "$WT_REAP/main.rs" ]]              || fail "(a) idle open-PR source removed!"
[[ -d "$WT_REAP/.git" ]]                 || fail "(a) idle open-PR .git removed!"
[[ "$(src_sum "$WT_REAP")" == "$REAP_SRC_BEFORE" ]] || fail "(a) source bytes changed!"
pass "(a) idle open-PR worktree: build output reaped, source byte-unchanged"

# (b) live lease → kept.
[[ -d "$WT_LEASE/target" ]]              || fail "(b) live-lease open-PR target/ was reaped"
pass "(b) live-lease worktree kept"

# (b) process cwd inside → kept.
[[ -d "$WT_CWD/target" ]]                || fail "(b) cwd-held open-PR target/ was reaped"
pass "(b) process-cwd-inside worktree kept"

# (b) running dispatch for the gap → kept.
[[ -d "$WT_DISPATCH/target" ]]           || fail "(b) running-dispatch open-PR target/ was reaped"
pass "(b) running-dispatch worktree kept"

# (dirty) tracked source change → kept.
[[ -d "$WT_DIRTY/target" ]]              || fail "(dirty) dirty-source open-PR target/ was reaped"
pass "(dirty) dirty-source worktree kept"

# (d) build activity under 2h → kept.
[[ -d "$WT_ACTIVE/target" ]]             || fail "(d) activity<2h open-PR target/ was reaped"
pass "(d) activity-within-2h worktree kept"

# (c) stale marker removed, fresh marker kept.
[[ ! -f "$MARK_STALE" ]]                 || fail "(c) stale marker not removed"
[[ -f "$MARK_FRESH" ]]                   || fail "(c) fresh marker was removed"
grep -Fq "bot-merge-active-dispatch-stale.path" "$AMBIENT" \
    || fail "(c) stale-marker removal not logged to ambient"
pass "(c) stale active-dispatch marker removed + logged, fresh marker kept"

# class=D emitted for the open-PR reap.
grep -q '"class":"D"' "$AMBIENT" || fail "no class=D event emitted"
pass "cargo_target_reaped class=D emitted"

echo "=== all Class-D open-idle tests passed ==="
