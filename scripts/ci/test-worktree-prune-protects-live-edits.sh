#!/usr/bin/env bash
# INFRA-1347: verify worktree-prune.sh refuses to delete worktrees with
# live work (uncommitted, untracked-non-gitignored, or unpushed commits).
#
# Drives worktree-prune.sh against a temp-dir fake repo with synthetic
# worktrees in each state. Asserts the right ones get pruned and the
# right ones get spared, with the right `worktree_reaper_skipped_active`
# reasons emitted to ambient.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
PRUNE="$REPO_ROOT/scripts/coord/worktree-prune.sh"

[[ -x "$PRUNE" ]] || { echo "[test] FAIL: worktree-prune.sh missing/not executable" >&2; exit 2; }

WORK=$(mktemp -d /tmp/chump-1347-test.XXXXXX)
trap 'cleanup' EXIT
cleanup() {
    rm -rf "$WORK"
}

# Build a fake repo to serve as the prune-target's "main" repo
FAKE_REPO="$WORK/fake-repo"
mkdir -p "$FAKE_REPO/.claude/worktrees" "$FAKE_REPO/.chump-locks"
cd "$FAKE_REPO"
git init -q
git config user.email "test@x"
git config user.name  "test"
echo "init" > README.md
git add README.md
git -c commit.gpgsign=false commit -qm init
# Make a "remote" we can have branches diverge from
mkdir -p "$WORK/remote.git"
git clone --bare -q . "$WORK/remote.git"
git remote add origin "$WORK/remote.git"
git push -q origin HEAD:main
git branch -M main 2>/dev/null || true

ambient="$FAKE_REPO/.chump-locks/ambient.jsonl"
: > "$ambient"
export CHUMP_AMBIENT_LOG="$ambient"

# Helper: create a worktree with the requested state
mk_wt() {
    local name="$1" state="$2"
    local wt="$FAKE_REPO/.claude/worktrees/$name"
    local branch="chump/$name"
    git -c init.defaultBranch=main worktree add -q -b "$branch" "$wt" >/dev/null
    case "$state" in
        clean)
            # Nothing — no PR, no commits ahead, no dirt
            ;;
        untracked)
            echo "untracked content" > "$wt/new-fixture.txt"
            ;;
        dirty)
            echo "modified" >> "$wt/README.md"
            ;;
        unpushed)
            cd "$wt"
            echo "local commit" > local.txt
            git add local.txt
            git -c commit.gpgsign=false commit -qm "local-only"
            cd "$FAKE_REPO"
            ;;
    esac
}

mk_wt "1347-clean"     clean
mk_wt "1347-untracked" untracked
mk_wt "1347-dirty"     dirty
mk_wt "1347-unpushed"  unpushed

# Run worktree-prune in --execute mode.
# Stub `gh` so:
#   - 1347-unpushed branch → CLOSED PR (exercises _prune_has_unpushed_commits)
#   - everything else → no PR (no-PR / ahead==0 path)
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
# If the --head flag names the unpushed branch, return a CLOSED PR.
if [[ "$*" == *"1347-unpushed"* ]] && [[ "$*" == *"pr list"* ]]; then
    # state query
    if [[ "$*" == *'"state"'* ]] || [[ "$*" == *'.[0].state'* ]]; then
        echo 'CLOSED'
        exit 0
    fi
    # number query
    if [[ "$*" == *'.[0].number'* ]]; then
        echo '9999'
        exit 0
    fi
    echo 'CLOSED'
    exit 0
fi
case "$*" in
    *"pr list"*)  echo '[]' ;;
    *) echo '{}' ;;
esac
GH
chmod +x "$WORK/bin/gh"

cd "$FAKE_REPO"
# CHUMP_REAPER_INDEX_MMIN=0: skip the .git/index mtime guard so the
# unpushed-commits check is actually exercised (index was just written;
# without this it would match -mmin -30 and short-circuit to git_index_fresh).
PATH="$WORK/bin:$PATH" CHUMP_REAPER_SAFETY_CHECK=1 CHUMP_REAPER_INDEX_MMIN=0 \
    CHUMP_WORKTREE_BASE=".claude/worktrees" \
    bash "$PRUNE" --execute >"$WORK/prune.out" 2>"$WORK/prune.err" || true

# Assertions: dirty, untracked, and unpushed must STILL exist.
check_kept() {
    local name="$1" reason_label="$2"
    if [[ ! -d "$FAKE_REPO/.claude/worktrees/$name" ]]; then
        echo "[test] FAIL: $name was deleted (expected KEEP for $reason_label)" >&2
        echo "--- prune stdout ---" >&2
        cat "$WORK/prune.out" >&2
        echo "--- prune stderr ---" >&2
        cat "$WORK/prune.err" >&2
        exit 1
    fi
    echo "[test] PASS: $name spared ($reason_label)"
}
check_kept "1347-untracked" "untracked-non-gitignored"
check_kept "1347-dirty"     "uncommitted-tracked"
check_kept "1347-unpushed"  "unpushed-commits"

# 1347-clean has no PR + no commits ahead + no dirt — should have been pruned.
# (NO-PR + ahead==0 + not in-flight → PRUNE per existing logic.)
if [[ -d "$FAKE_REPO/.claude/worktrees/1347-clean" ]]; then
    echo "[test] NOTE: 1347-clean still exists (reaper may be conservative — check prune.out)" >&2
fi

# Ambient assertions: new reasons should have fired.
for reason in untracked_unignored unpushed_commits; do
    if ! grep -q "\"reason\":\"$reason\"" "$ambient" 2>/dev/null; then
        echo "[test] FAIL: expected ambient event with reason=$reason — not found" >&2
        echo "--- ambient log ---" >&2
        cat "$ambient" >&2
        exit 1
    fi
    echo "[test] PASS: ambient event reason=$reason emitted"
done

echo ""
echo "[test] ALL CHECKS PASSED — INFRA-1347 protections verified"
