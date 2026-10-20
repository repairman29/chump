#!/usr/bin/env bash
# test-cargo-target-reaper-class-d-open-idle.sh — RESILIENT-1635
#
# Validates the RESILIENT-1635 extension of cargo-target-reaper Class D: a
# dispatch worktree whose PR is still OPEN also has its build output reaped when
# it is IDLE, and stale bot-merge-active-dispatch-*.path markers are removed.
#
#   (a) an idle open-PR worktree older than 2h loses target/ + .cargo-test-target/,
#       its source files are byte-unchanged, and the class=D reap event carries
#       that path and its byte count;
#   (b) a worktree with a live lease, a process cwd inside, OR a running dispatch
#       for that gap is never touched (one case each);
#   (c) a stale bot-merge-active-dispatch-*.path marker is removed, a fresh one
#       kept, and a stale one whose bot-merge PID is still alive kept;
#   (d) an open-PR worktree with build activity under 2h old is kept, including
#       activity deep in target/ that leaves the top-level mtime old;
#   plus a dirty-source open-PR worktree is kept (Chief rule 2026-10-19 11:55Z).
#
# Fail-closed fixtures (review of 5c75329dc), each killed by its own mutant:
#   (e) unknown / no-PR state is kept (not treated as open);
#   (f) gh failing is kept, even when it printed an OPEN line before failing;
#   (g) a symlinked .claude/worktrees entry is kept and the checkout it points
#       at keeps its target/ byte-for-byte;
#   (h) a suffixed worktree name (resilient-1828-fleet-1-<ts>) with a running
#       `chump dispatch RESILIENT-1828` is kept;
#   (i) a process with CARGO_TARGET_DIR inside the worktree (cwd elsewhere, the
#       pre-push nextest shape) keeps it;
#   (j) a process holding an open file under target/ (cwd elsewhere) keeps it;
#   (k) with the node build lane lock held by another process, nothing at all is
#       deleted; likewise when `chump admit cargo` refuses;
#   (l) an open-PR worktree whose name and branch yield no gap id is kept;
#   (m) a worktree whose target/ is a symlink is kept, link and pointee intact;
#   (n) a symlinked worktree entry that resolves INSIDE the base (an alias of a
#       nested checkout) is still kept: the -L check stands on its own.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="${REPO_ROOT}/scripts/ops/cargo-target-reaper.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-cargo-target-reaper-class-d-open-idle.sh ==="

command -v flock >/dev/null 2>&1 || fail "flock is required (Class D takes the node build lane lock)"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

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

# stub gh: `gh pr list --head <branch> ...` → OPEN for any branch with "open";
# a branch with "ghfail" prints an OPEN line and then FAILS (exit 1).
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
    *ghfail*)          echo '[{"number":333,"state":"OPEN"}]'; echo "gh: HTTP 502" >&2; exit 1 ;;
    *merged*|*closed*) echo '[{"number":111,"state":"MERGED"}]' ;;
    *open*)            echo '[{"number":222,"state":"OPEN"}]' ;;
    *)                 echo '[]' ;;
esac
GH
chmod +x "$BIN/gh"
# stub chump: `chump admit cargo` admits unless the refuse flag file exists.
ADMIT_REFUSE="$TMP/admit-refuse"
cat > "$BIN/chump" <<CHUMP
#!/usr/bin/env bash
if [[ "\${1:-} \${2:-}" == "admit cargo" ]]; then
    [[ -e "$ADMIT_REFUSE" ]] && exit 75
    exit 0
fi
exit 0
CHUMP
chmod +x "$BIN/chump"
export PATH="$BIN:$PATH"
export CHUMP_CACHE_DB="$TMP/nonexistent-cache.db"  # force gh fallback
# The node build lane lock Class D takes; a fixture path, never ~/.chump.
LANE_LOCK="$TMP/architect-lane.lock"

# backdate <seconds-ago> <path>... — portable (GNU + BSD) mtime backdate.
backdate() {
    local secs="$1" e ts
    shift
    e=$(( $(date +%s) - secs ))
    ts="$(date -d "@$e" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$e" +%Y%m%d%H%M.%S)"
    touch -t "$ts" "$@"
}
THREE_H=$(( 3 * 3600 ))

# mk_repo <dir> <branch> — a real git repo on <branch> with committed source and
# fully backdated build dirs (every file and dir 3h old).
mk_repo() {
    local wt="$1" branch="$2"
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
    local p
    while IFS= read -r p; do backdate "$THREE_H" "$p"; done < <(
        find "$wt/target" "$wt/.cargo-test-target" -depth)
}
# mk_wt <name> <branch> — mk_repo under the scanned worktree base; echoes path.
mk_wt() {
    mk_repo "$WT_BASE/$1" "$2"
    printf '%s' "$WT_BASE/$1"
}

# Distinct gap-id-shaped names (digit suffix) so the dispatch/activity matchers
# can't false-match each other or the parent dispatch's prompt.
WT_REAP="$(mk_wt resilient-1801 chump/resilient-1801-open)"
WT_LEASE="$(mk_wt resilient-1802 chump/resilient-1802-open)"
WT_CWD="$(mk_wt resilient-1803 chump/resilient-1803-open)"
WT_DISPATCH="$(mk_wt resilient-1804 chump/resilient-1804-open)"
WT_DIRTY="$(mk_wt resilient-1805 chump/resilient-1805-open)"
WT_ACTIVE="$(mk_wt resilient-1806 chump/resilient-1806-open)"
WT_NOPR="$(mk_wt resilient-1807 chump/resilient-1807-nopr)"
WT_GHFAIL="$(mk_wt resilient-1808 chump/resilient-1808-ghfail)"
WT_SUFFIX="$(mk_wt resilient-1828-fleet-1-20261019t000000 chump/resilient-1828-fleet-1-20261019t000000-open)"
WT_CTD="$(mk_wt resilient-1810 chump/resilient-1810-open)"
WT_OPENFILE="$(mk_wt resilient-1811 chump/resilient-1811-open)"
WT_DEEP="$(mk_wt resilient-1812 chump/resilient-1812-open)"
WT_NOGAP="$(mk_wt scratch-wt chump/scratch-open)"
WT_LINKTGT="$(mk_wt resilient-1813 chump/resilient-1813-open)"

# (m) WT_LINKTGT/target is a symlink to a build dir that is not this worktree's.
ELSEWHERE="$TMP/elsewhere-target"
mkdir -p "$ELSEWHERE/debug"
echo shared-artifact > "$ELSEWHERE/debug/chump"
backdate "$THREE_H" "$ELSEWHERE/debug/chump" "$ELSEWHERE/debug" "$ELSEWHERE"
rm -rf "$WT_LINKTGT/target"
ln -s "$ELSEWHERE" "$WT_LINKTGT/target"
# The link's own mtime is old too, so only the symlink guard can keep it.
_e=$(( $(date +%s) - THREE_H ))
touch -h -t "$(date -d "@$_e" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$_e" +%Y%m%d%H%M.%S)" "$WT_LINKTGT/target"

# (n) .claude/worktrees/resilient-1814 is a symlink to a checkout nested under
# the base (nest/ itself has no build dirs, so the scan never reaps it directly).
NESTED="$WT_BASE/nest/resilient-1814"
mk_repo "$NESTED" chump/resilient-1814-open
ln -s "$NESTED" "$WT_BASE/resilient-1814"

# (g) a symlinked worktree entry pointing at ANOTHER checkout (outside the base).
OTHER="$TMP/other-checkout/resilient-1809"
mk_repo "$OTHER" chump/resilient-1809-open
ln -s "$OTHER" "$WT_BASE/resilient-1809"

# (b) live lease naming WT_LEASE.
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$LOCKS/lease-1802.json" <<EOF
{"worktree":"$WT_LEASE","gap_id":"RESILIENT-1802","heartbeat_at":"$NOW_ISO","taken_at":"$NOW_ISO"}
EOF

# (b) a live process whose cwd is inside WT_CWD.
( cd "$WT_CWD" && exec sleep 300 ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (b) a running `chump dispatch` for WT_DISPATCH's gap (argv names RESILIENT-1804).
( exec -a "chump dispatch RESILIENT-1804 --backend headless" sleep 300 ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (h) a running dispatch for the suffixed worktree's gap, RESILIENT-1828.
( exec -a "chump dispatch RESILIENT-1828 --backend headless" sleep 300 ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (i) the pre-push nextest shape: CARGO_TARGET_DIR inside WT_CTD, cwd elsewhere.
# python3 (not /bin/sleep): macOS hides a platform binary's environment.
( cd "$TMP" && CARGO_TARGET_DIR="$WT_CTD/.cargo-test-target" \
    exec python3 -c 'import time; time.sleep(300)' ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (j) a process holding a file open under WT_OPENFILE/target, cwd elsewhere.
( cd "$TMP" && exec 3<"$WT_OPENFILE/target/debug/chump" && exec sleep 300 ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (c) markers: one stale (> grace), one fresh (within grace), one stale whose
# bot-merge PID (named in its log path) is still running.
MARK_STALE="$LOCKS/bot-merge-active-dispatch-stale.path"
MARK_FRESH="$LOCKS/bot-merge-active-dispatch-fresh.path"
MARK_LIVE="$LOCKS/bot-merge-active-dispatch-live.path"
( exec -a "bash scripts/coord/bot-merge.sh --gap RESILIENT-1899 --auto-merge" sleep 300 ) >/dev/null 2>&1 &
BM_PID="$!"
BG_PIDS+=("$BM_PID")
echo "/tmp/log-stale" > "$MARK_STALE"
echo "/tmp/log-fresh" > "$MARK_FRESH"
echo "$LOCKS/bot-merge-${BM_PID}.log" > "$MARK_LIVE"
backdate 3600 "$MARK_STALE" "$MARK_LIVE"   # > 15m grace

# (d) WT_ACTIVE: build activity within 2h → keep. Un-backdate its build dirs.
touch "$WT_ACTIVE/target" "$WT_ACTIVE/.cargo-test-target"
# (d) WT_DEEP: only a file deep in target/ is fresh; top-level dirs stay 3h old.
touch "$WT_DEEP/target/debug/chump"

# (dirty) WT_DIRTY: a tracked change in the source tree → keep.
echo "fn main() { /* edited */ }" > "$WT_DIRTY/main.rs"

# Record source checksums to prove the reaper never touches source bytes.
src_sum() { git -C "$1" hash-object main.rs; }
REAP_SRC_BEFORE="$(src_sum "$WT_REAP")"
OTHER_TARGET_BEFORE="$(cat "$OTHER/target/debug/chump")"
REAP_REAL="$(cd -P "$WT_REAP" && pwd -P)"
REAP_TARGET_BYTES="$(du -sk "$REAP_REAL/target" | awk '{print $1 * 1024}')"
REAP_CTT_BYTES="$(du -sk "$REAP_REAL/.cargo-test-target" | awk '{print $1 * 1024}')"

# Regression pin (as in the RESILIENT-1620 test): env lock store points at a
# foreign dir so Class D must find the lease in the SCANNED repo's own store.
FOREIGN_LOCKS="$TMP/foreign-locks"
mkdir -p "$FOREIGN_LOCKS"
sleep 0.5   # let the fixture processes exec

run_reaper() {
    CHUMP_LOCK_DIR="$FOREIGN_LOCKS" \
    CHUMP_STATE_DB="$TMP/foreign-state.db" \
    REAPER_REPO_ROOT="$FAKE_REPO" \
    CHUMP_WORKTREE_BASE="$WT_BASE" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_REAPER_SAFETY_CHECK=1 \
    CHUMP_REAPER_BOT_MERGE_GRACE_MIN=15 \
    CHUMP_ARCH_LANE_LOCK="$LANE_LOCK" \
        bash "$REAPER" --class-d-only --execute 2>&1
}

# nothing_deleted <label> — every fixture's build dirs and every marker intact.
nothing_deleted() {
    local w
    for w in "$WT_REAP" "$WT_LEASE" "$WT_CWD" "$WT_DISPATCH" "$WT_DIRTY" "$WT_ACTIVE" \
             "$WT_NOPR" "$WT_GHFAIL" "$WT_SUFFIX" "$WT_CTD" "$WT_OPENFILE" "$WT_DEEP" "$OTHER" \
             "$WT_NOGAP" "$WT_LINKTGT" "$NESTED"; do
        [[ -d "$w/target" && -d "$w/.cargo-test-target" ]] || fail "$1: $w build output was deleted"
    done
    [[ -f "$MARK_STALE" && -f "$MARK_FRESH" && -f "$MARK_LIVE" ]] || fail "$1: a marker was deleted"
    if grep -q '"class":"D"' "$AMBIENT"; then
        fail "$1: a class=D reap event was emitted"
    fi
}

# ── (k) node build lane lock held by another process → nothing deleted ──────
echo "--- (k) lane lock held: whole Class D tick skipped ---"
# The holder execs sleep with the lock fd, so killing that PID drops the lock.
( exec 7>>"$LANE_LOCK" && flock 7 && exec sleep 300 ) >/dev/null 2>&1 &
LOCK_HOLDER="$!"
BG_PIDS+=("$LOCK_HOLDER")
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if flock -n "$LANE_LOCK" true 2>/dev/null; then sleep 0.2; else break; fi
done
OUT="$(run_reaper)" || fail "reaper exited non-zero (lock held)"
echo "$OUT" | sed 's/^/    /'
nothing_deleted "(k) lock held"
[[ "$OUT" == *"lane lock held"* ]] || fail "(k) skip reason for the held lane lock not logged"
pass "(k) lane lock held by another process: nothing deleted, reason logged"
kill "$LOCK_HOLDER" 2>/dev/null || true
wait "$LOCK_HOLDER" 2>/dev/null || true

# ── (k) chump admit cargo refuses → nothing deleted ─────────────────────────
echo "--- (k) chump admit cargo refused: whole Class D tick skipped ---"
: > "$ADMIT_REFUSE"
OUT="$(run_reaper)" || fail "reaper exited non-zero (admit refused)"
echo "$OUT" | sed 's/^/    /'
nothing_deleted "(k) admit refused"
[[ "$OUT" == *"chump admit cargo refused"* ]] || fail "(k) skip reason for the admit refusal not logged"
pass "(k) chump admit cargo refused: nothing deleted, reason logged"
rm -f "$ADMIT_REFUSE"

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

# (a) the class=D REAP event itself (not the marker event) names the reaped
# build dir and its byte count.
python3 - "$AMBIENT" "$REAP_REAL/target" "$REAP_TARGET_BYTES" \
          "$REAP_REAL/.cargo-test-target" "$REAP_CTT_BYTES" <<'PY' || fail "(a) class=D reap event path/bytes mismatch"
import json, sys
amb, want = sys.argv[1], dict(zip(sys.argv[2::2], (int(b) for b in sys.argv[3::2])))
seen = {}
for line in open(amb):
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("kind") == "cargo_target_reaped" and e.get("class") == "D" and "branch" in e:
        seen[e["path"]] = e
for path, nbytes in want.items():
    e = seen.get(path)
    if e is None:
        sys.exit(f"no class=D reap event for {path}; saw {sorted(seen)}")
    if e["bytes_freed"] != nbytes or nbytes <= 0:
        sys.exit(f"{path}: bytes_freed={e['bytes_freed']} want {nbytes}")
    if e.get("dry_run") is not False:
        sys.exit(f"{path}: dry_run={e.get('dry_run')}")
PY
pass "(a) class=D reap event carries the reaped path and its bytes_freed"

# no_reap_event <wt> — no class=D reap event names this worktree's build dirs.
no_reap_event() {
    local real
    real="$(cd -P "$1" && pwd -P)"
    if grep -Fq "\"path\":\"${real}/target\"" "$AMBIENT" \
        || grep -Fq "\"path\":\"${real}/.cargo-test-target\"" "$AMBIENT"; then
        fail "$2: a class=D reap event names $real"
    fi
}

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
[[ -d "$WT_DEEP/target" && -d "$WT_DEEP/.cargo-test-target" ]] \
    || fail "(d) deep-file activity<2h (top-level mtime 3h old) open-PR build output was reaped"
no_reap_event "$WT_DEEP" "(d) deep activity"
pass "(d) activity deep in target/ (top-level mtime old) kept"

# (e) no PR / unknown state → kept.
[[ -d "$WT_NOPR/target" && -d "$WT_NOPR/.cargo-test-target" ]] \
    || fail "(e) unknown/no-PR worktree build output was reaped"
no_reap_event "$WT_NOPR" "(e) no-PR"
pass "(e) unknown/no-PR state kept (not treated as open)"

# (f) gh failing → kept, even though it printed an OPEN line first.
[[ -d "$WT_GHFAIL/target" && -d "$WT_GHFAIL/.cargo-test-target" ]] \
    || fail "(f) gh-failing worktree build output was reaped"
no_reap_event "$WT_GHFAIL" "(f) gh failing"
pass "(f) gh failing kept"

# (g) symlinked worktree entry → kept; the other checkout's target untouched.
[[ -L "$WT_BASE/resilient-1809" ]]       || fail "(g) symlinked entry removed"
[[ -d "$OTHER/target" && -d "$OTHER/.cargo-test-target" ]] \
    || fail "(g) the symlinked-to checkout's build output was deleted"
[[ "$(cat "$OTHER/target/debug/chump")" == "$OTHER_TARGET_BEFORE" ]] \
    || fail "(g) the symlinked-to checkout's target bytes changed"
no_reap_event "$OTHER" "(g) symlink"
pass "(g) symlinked worktree entry kept; the other checkout's target byte-unchanged"

# (h) suffixed name with a running dispatch for its gap → kept.
[[ -d "$WT_SUFFIX/target" && -d "$WT_SUFFIX/.cargo-test-target" ]] \
    || fail "(h) suffixed worktree under a live chump dispatch RESILIENT-1828 was reaped"
no_reap_event "$WT_SUFFIX" "(h) suffixed dispatch"
pass "(h) suffixed resilient-1828-fleet-1-<ts> with a running dispatch kept"

# (i) CARGO_TARGET_DIR inside the worktree, cwd elsewhere → kept.
[[ -d "$WT_CTD/target" && -d "$WT_CTD/.cargo-test-target" ]] \
    || fail "(i) CARGO_TARGET_DIR-busy worktree build output was reaped"
no_reap_event "$WT_CTD" "(i) CARGO_TARGET_DIR"
pass "(i) CARGO_TARGET_DIR-busy worktree (cwd elsewhere) kept"

# (j) open file under target/, cwd elsewhere → kept.
[[ -d "$WT_OPENFILE/target" && -d "$WT_OPENFILE/.cargo-test-target" ]] \
    || fail "(j) open-file-busy worktree build output was reaped"
no_reap_event "$WT_OPENFILE" "(j) open file"
pass "(j) open-file-busy worktree (cwd elsewhere) kept"

# (l) no derivable gap id → kept (cannot rule out a running dispatch).
[[ -d "$WT_NOGAP/target" && -d "$WT_NOGAP/.cargo-test-target" ]] \
    || fail "(l) open-PR worktree with no derivable gap id was reaped"
no_reap_event "$WT_NOGAP" "(l) no gap id"
pass "(l) open-PR worktree with no derivable gap id kept"

# (m) symlinked build dir → worktree kept; the link and what it points at intact.
[[ -L "$WT_LINKTGT/target" ]]            || fail "(m) symlinked target/ link was removed"
[[ "$(cat "$ELSEWHERE/debug/chump")" == "shared-artifact" ]] \
    || fail "(m) the symlinked target's pointee changed"
[[ -d "$WT_LINKTGT/.cargo-test-target" ]] || fail "(m) worktree with a symlinked target/ had .cargo-test-target reaped"
no_reap_event "$WT_LINKTGT" "(m) symlinked build dir"
pass "(m) symlinked build dir: worktree kept, link + pointee intact"

# (n) symlinked entry resolving inside the base → kept; nested checkout intact.
[[ -L "$WT_BASE/resilient-1814" ]]       || fail "(n) symlinked alias entry removed"
[[ -d "$NESTED/target" && -d "$NESTED/.cargo-test-target" ]] \
    || fail "(n) build output reaped through a symlinked alias entry inside the base"
no_reap_event "$NESTED" "(n) in-base symlink alias"
pass "(n) symlinked alias entry resolving inside the base kept"

# (c) stale marker removed, fresh marker kept, live-PID marker kept.
[[ ! -f "$MARK_STALE" ]]                 || fail "(c) stale marker not removed"
[[ -f "$MARK_FRESH" ]]                   || fail "(c) fresh marker was removed"
[[ -f "$MARK_LIVE" ]]                    || fail "(c) stale-mtime marker with a live bot-merge PID was removed"
grep -Fq "bot-merge-active-dispatch-stale.path" "$AMBIENT" \
    || fail "(c) stale-marker removal not logged to ambient"
pass "(c) stale active-dispatch marker removed + logged, fresh and live-PID markers kept"

# class=D emitted for the open-PR reap.
grep -q '"class":"D"' "$AMBIENT" || fail "no class=D event emitted"
pass "cargo_target_reaped class=D emitted"

echo "=== all Class-D open-idle tests passed ==="
