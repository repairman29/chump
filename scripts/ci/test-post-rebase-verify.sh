#!/usr/bin/env bash
# scripts/ci/test-post-rebase-verify.sh — INFRA-1526
#
# Behavioural tests for scripts/coord/post-rebase-verify.sh.
# Creates synthetic git repos to exercise the hunk-drop detector without
# touching live remotes.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/post-rebase-verify.sh"

echo "=== INFRA-1526 post-rebase-verify tests ==="

# ── Source contract ───────────────────────────────────────────────────────────
[[ -f "$TARGET" ]] && ok "script exists" || { fail "missing $TARGET"; exit 1; }
[[ -x "$TARGET" ]] && ok "script executable" || fail "$TARGET not executable"

for needle in \
    "ORIG_HEAD" \
    "rebase_hunk_dropped" \
    "lines_dropped" \
    "original_commit" \
    "rebased_commit" \
    "CHUMP_REBASE_VERIFY_SKIP" \
    "CHUMP_REBASE_VERIFY_THRESHOLD" \
    "merge-base"; do
    if grep -qF "$needle" "$TARGET"; then
        ok "contract: $needle"
    else
        fail "contract missing: $needle"
    fi
done

# ── Behavioural tests using synthetic git repos ───────────────────────────────

setup_repo() {
    # Create a minimal git repo with an origin remote and return the worktree path.
    # $1 = tmpdir prefix
    local base
    base="$(mktemp -d -t "test-prv-${1}-XXXXXX")"

    # "origin" bare repo
    local origin="$base/origin.git"
    git init --bare "$origin" -b main >/dev/null 2>&1

    # main checkout
    local main_wt="$base/main"
    git clone "$origin" "$main_wt" -q 2>/dev/null
    git -C "$main_wt" config user.email "ci@chump"
    git -C "$main_wt" config user.name "CI"

    # Initial commit on main
    printf '%s\n' "line1" > "$main_wt/base.txt"
    git -C "$main_wt" add base.txt
    git -C "$main_wt" commit -m "init" -q
    git -C "$main_wt" push origin main -q 2>/dev/null

    echo "$base"
}

# ── Test 1: SKIP when no ORIG_HEAD ───────────────────────────────────────────
T="skip-no-orig-head"
base="$(setup_repo "$T")"
main_wt="$base/main"
out="$(cd "$main_wt" && CHUMP_REPO_ROOT="$main_wt" AMBIENT="/dev/null" bash "$TARGET" 2>&1)"
rc=$?
if [[ $rc -eq 0 ]] && echo "$out" | grep -q "SKIP"; then
    ok "$T: exits 0 with SKIP when ORIG_HEAD absent"
else
    fail "$T: expected exit 0 + SKIP, got rc=$rc output='$out'"
fi
rm -rf "$base"

# ── Test 2: SKIP when CHUMP_REBASE_VERIFY_SKIP=1 ─────────────────────────────
T="skip-env-bypass"
base="$(setup_repo "$T")"
main_wt="$base/main"
out="$(cd "$main_wt" && CHUMP_REPO_ROOT="$main_wt" AMBIENT="/dev/null" CHUMP_REBASE_VERIFY_SKIP=1 bash "$TARGET" 2>&1)"
rc=$?
if [[ $rc -eq 0 ]] && echo "$out" | grep -q "SKIP"; then
    ok "$T: exits 0 with SKIP when env bypass set"
else
    fail "$T: expected exit 0 + SKIP, got rc=$rc"
fi
rm -rf "$base"

# ── Test 3: OK when all large files survive rebase ───────────────────────────
T="clean-rebase"
base="$(setup_repo "$T")"
origin="$base/origin.git"
main_wt="$base/main"

# Feature branch: add a large file (>50 lines)
feat_wt="$base/feat"
git clone "$origin" "$feat_wt" -q 2>/dev/null
git -C "$feat_wt" config user.email "ci@chump"
git -C "$feat_wt" config user.name "CI"
git -C "$feat_wt" checkout -b feature -q
seq 1 80 > "$feat_wt/bigfile.rs"
git -C "$feat_wt" add bigfile.rs
git -C "$feat_wt" commit -m "add bigfile" -q
git -C "$feat_wt" push origin feature -q 2>/dev/null

# Main advances (unrelated file)
echo "main-advance" >> "$main_wt/base.txt"
git -C "$main_wt" add base.txt
git -C "$main_wt" commit -m "main advance" -q
git -C "$main_wt" push origin main -q 2>/dev/null

# Simulate rebase: fetch + rebase feature onto main
git -C "$feat_wt" fetch origin main -q 2>/dev/null
git -C "$feat_wt" rebase origin/main -q 2>/dev/null
ORIG_HEAD="$(git -C "$feat_wt" rev-parse ORIG_HEAD 2>/dev/null)"

out="$(cd "$feat_wt" && CHUMP_REPO_ROOT="$feat_wt" AMBIENT="/dev/null" bash "$TARGET" "$ORIG_HEAD" 2>&1)"
rc=$?
if [[ $rc -eq 0 ]] && echo "$out" | grep -q "OK"; then
    ok "$T: exits 0 when bigfile.rs survives rebase"
else
    fail "$T: expected exit 0 + OK, got rc=$rc output='$out'"
fi
rm -rf "$base"

# ── Test 4: FAIL + ambient event when large file is dropped ──────────────────
T="hunk-drop-detected"
base="$(setup_repo "$T")"
origin="$base/origin.git"
main_wt="$base/main"
AMBIENT_LOG="$base/ambient.jsonl"

# Feature branch: add bigfile.rs with >50 lines
feat_wt="$base/feat"
git clone "$origin" "$feat_wt" -q 2>/dev/null
git -C "$feat_wt" config user.email "ci@chump"
git -C "$feat_wt" config user.name "CI"
git -C "$feat_wt" checkout -b feature -q
seq 1 80 > "$feat_wt/bigfile.rs"
git -C "$feat_wt" add bigfile.rs
git -C "$feat_wt" commit -m "add bigfile" -q
ORIG_HEAD_SHA="$(git -C "$feat_wt" rev-parse HEAD)"
git -C "$feat_wt" push origin feature -q 2>/dev/null

# Main advances AND replaces bigfile.rs with something tiny (simulating a
# merge driver that ate our content):
echo "tiny" > "$main_wt/bigfile.rs"
git -C "$main_wt" add bigfile.rs
git -C "$main_wt" commit -m "main clobbers bigfile" -q
git -C "$main_wt" push origin main -q 2>/dev/null

# Simulate rebase with -X ours (takes main's version on conflict): bigfile.rs
# ends up with only "tiny" from main, all 80 lines gone.
# In git rebase: "ours" = base (main side), "theirs" = feature commits being replayed.
git -C "$feat_wt" fetch origin main -q 2>/dev/null
git -C "$feat_wt" rebase -X ours origin/main -q 2>/dev/null || true
REBASED_HEAD="$(git -C "$feat_wt" rev-parse HEAD)"

# Manually set ORIG_HEAD to the original feature commit so the script sees the drop
echo "$ORIG_HEAD_SHA" > "$feat_wt/.git/ORIG_HEAD"

out="$(cd "$feat_wt" && CHUMP_REPO_ROOT="$feat_wt" AMBIENT="$AMBIENT_LOG" bash "$TARGET" 2>&1)"
rc=$?

if [[ $rc -eq 1 ]] && echo "$out" | grep -q "HUNK DROP"; then
    ok "$T: exits 1 with HUNK DROP message"
else
    fail "$T: expected exit 1 + HUNK DROP, got rc=$rc output='$out'"
fi

if [[ -f "$AMBIENT_LOG" ]] && grep -q '"kind":"rebase_hunk_dropped"' "$AMBIENT_LOG"; then
    ok "$T: emits rebase_hunk_dropped event to ambient"
else
    fail "$T: no rebase_hunk_dropped event in ambient log"
fi

if [[ -f "$AMBIENT_LOG" ]] && grep -q '"file"' "$AMBIENT_LOG" && grep -q '"lines_dropped"' "$AMBIENT_LOG"; then
    ok "$T: event contains file + lines_dropped fields"
else
    fail "$T: event missing required fields"
fi
rm -rf "$base"

# ── Test 5: OK when file is small (below threshold) ──────────────────────────
T="small-file-no-alarm"
base="$(setup_repo "$T")"
origin="$base/origin.git"
main_wt="$base/main"

feat_wt="$base/feat"
git clone "$origin" "$feat_wt" -q 2>/dev/null
git -C "$feat_wt" config user.email "ci@chump"
git -C "$feat_wt" config user.name "CI"
git -C "$feat_wt" checkout -b feature -q
# Only 10 lines — below default threshold of 50
seq 1 10 > "$feat_wt/smallfile.rs"
git -C "$feat_wt" add smallfile.rs
git -C "$feat_wt" commit -m "small file" -q
git -C "$feat_wt" push origin feature -q 2>/dev/null

# Main clobbers smallfile.rs
echo "clobbered" > "$main_wt/smallfile.rs"
git -C "$main_wt" add smallfile.rs
git -C "$main_wt" commit -m "clobber smallfile" -q
git -C "$main_wt" push origin main -q 2>/dev/null

git -C "$feat_wt" fetch origin main -q 2>/dev/null
git -C "$feat_wt" rebase -X theirs origin/main -q 2>/dev/null || true
ORIG_HEAD="$(git -C "$feat_wt" rev-parse ORIG_HEAD 2>/dev/null || echo "")"
[[ -z "$ORIG_HEAD" ]] && git -C "$feat_wt" rev-parse HEAD~ 2>/dev/null > "$feat_wt/.git/ORIG_HEAD" || true

out="$(cd "$feat_wt" && CHUMP_REPO_ROOT="$feat_wt" AMBIENT="/dev/null" bash "$TARGET" 2>&1)"
rc=$?
if [[ $rc -eq 0 ]]; then
    ok "$T: exits 0 for file below threshold (no false alarm)"
else
    fail "$T: expected exit 0 for small file drop, got rc=$rc output='$out'"
fi
rm -rf "$base"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    echo "Failed:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
