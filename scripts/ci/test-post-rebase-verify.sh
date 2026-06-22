#!/usr/bin/env bash
# scripts/ci/test-post-rebase-verify.sh — INFRA-1526
#
# Smoke tests for scripts/coord/post-rebase-verify.sh.
# Creates synthetic git repos to verify drop detection and clean-pass logic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRV="${SCRIPT_DIR}/../coord/post-rebase-verify.sh"

pass=0
fail=0

_pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
_fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

_init_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -b main --quiet
    git -C "$d" config user.email "test@chump"
    git -C "$d" config user.name "test"
}

# Generate N lines of content into a file inside the repo
_bigfile() {
    local repo="$1" name="$2" n="${3:-60}"
    python3 -c "print('\n'.join('line {}'.format(i) for i in range($n)))" > "$repo/$name"
}

# ── T1: no ORIG_HEAD → exit 0 ────────────────────────────────────────────────
{
    r="${_tmp}/t1"
    _init_repo "$r"
    printf 'hello\n' > "$r/file.txt"
    git -C "$r" add file.txt && git -C "$r" commit -m "init" --quiet

    rc=0
    CHUMP_REPO_ROOT="$r" CHUMP_AMBIENT_LOG="/dev/null" \
        "$PRV" --base main 2>/dev/null || rc=$?
    [[ "$rc" -eq 0 ]] && _pass "T1: no ORIG_HEAD → exit 0" \
                      || _fail "T1: no ORIG_HEAD → expected 0, got $rc"
}

# ── T2: clean rebase (file survives) → exit 0 ────────────────────────────────
{
    r="${_tmp}/t2"
    _init_repo "$r"

    printf 'base\n' > "$r/base.txt"
    git -C "$r" add base.txt && git -C "$r" commit -m "base" --quiet

    git -C "$r" checkout -b feature --quiet
    _bigfile "$r" feature.txt 60
    git -C "$r" add feature.txt && git -C "$r" commit -m "feature: add feature.txt" --quiet
    ORIG_HEAD="$(git -C "$r" rev-parse HEAD)"

    git -C "$r" checkout main --quiet
    printf 'main-extra\n' >> "$r/base.txt"
    git -C "$r" add base.txt && git -C "$r" commit -m "main: extra" --quiet

    git -C "$r" checkout feature --quiet
    git -C "$r" rebase main --quiet

    rc=0
    CHUMP_REPO_ROOT="$r" CHUMP_AMBIENT_LOG="/dev/null" \
        "$PRV" --orig-head "$ORIG_HEAD" --base main 2>/dev/null || rc=$?
    [[ "$rc" -eq 0 ]] && _pass "T2: clean rebase → exit 0" \
                      || _fail "T2: clean rebase → expected 0, got $rc"
}

# ── T3: hunk drop → exit 2 + ambient event emitted ───────────────────────────
{
    r="${_tmp}/t3"
    _init_repo "$r"

    printf 'base\n' > "$r/base.txt"
    git -C "$r" add base.txt && git -C "$r" commit -m "base" --quiet

    git -C "$r" checkout -b feature --quiet
    _bigfile "$r" big.txt 60
    git -C "$r" add big.txt && git -C "$r" commit -m "feature: big.txt" --quiet
    ORIG_HEAD="$(git -C "$r" rev-parse HEAD)"

    # Simulate a silent drop: undo the commit, remove big.txt, commit without it
    git -C "$r" reset --soft HEAD~1 --quiet
    git -C "$r" restore --staged big.txt 2>/dev/null \
        || git -C "$r" reset HEAD big.txt 2>/dev/null || true
    git -C "$r" checkout -- big.txt 2>/dev/null || rm -f "$r/big.txt"
    printf 'tiny\n' > "$r/tiny.txt"
    git -C "$r" add tiny.txt && git -C "$r" commit -m "rebased: big.txt silently dropped" --quiet

    AMBIENT_OUT="${_tmp}/t3-ambient.jsonl"
    rc=0
    CHUMP_REPO_ROOT="$r" CHUMP_AMBIENT_LOG="$AMBIENT_OUT" \
        "$PRV" --orig-head "$ORIG_HEAD" --base main 2>/dev/null || rc=$?

    [[ "$rc" -eq 2 ]] && _pass "T3: drop detected → exit 2" \
                      || _fail "T3: drop detected → expected 2, got $rc"

    if [[ -f "$AMBIENT_OUT" ]] && grep -q '"kind":"rebase_hunk_dropped"' "$AMBIENT_OUT" 2>/dev/null; then
        _pass "T3: rebase_hunk_dropped emitted to ambient"
    else
        _fail "T3: rebase_hunk_dropped NOT in ambient (file: $AMBIENT_OUT)"
        [[ -f "$AMBIENT_OUT" ]] && cat "$AMBIENT_OUT" >&2 || true
    fi

    if [[ -f "$AMBIENT_OUT" ]] && grep -q '"file":"big.txt"' "$AMBIENT_OUT" 2>/dev/null; then
        _pass "T3: ambient event names the correct dropped file"
    else
        _fail "T3: ambient event missing correct file field"
    fi
}

# ── T4: --dry-run → exits 0 even when drop present ───────────────────────────
{
    r="${_tmp}/t4"
    _init_repo "$r"

    printf 'base\n' > "$r/base.txt"
    git -C "$r" add base.txt && git -C "$r" commit -m "base" --quiet

    git -C "$r" checkout -b feature --quiet
    _bigfile "$r" big.txt 60
    git -C "$r" add big.txt && git -C "$r" commit -m "feature" --quiet
    ORIG_HEAD="$(git -C "$r" rev-parse HEAD)"

    git -C "$r" reset --soft HEAD~1 --quiet
    git -C "$r" restore --staged big.txt 2>/dev/null \
        || git -C "$r" reset HEAD big.txt 2>/dev/null || true
    git -C "$r" checkout -- big.txt 2>/dev/null || rm -f "$r/big.txt"
    printf 'tiny\n' > "$r/tiny.txt"
    git -C "$r" add tiny.txt && git -C "$r" commit -m "rebased (drop simulated)" --quiet

    rc=0
    CHUMP_REPO_ROOT="$r" CHUMP_AMBIENT_LOG="/dev/null" \
        "$PRV" --orig-head "$ORIG_HEAD" --base main --dry-run 2>/dev/null || rc=$?
    [[ "$rc" -eq 0 ]] && _pass "T4: --dry-run exits 0 on drop" \
                      || _fail "T4: --dry-run → expected 0, got $rc"
}

# ── T5: file under threshold (10 lines) is not flagged ───────────────────────
{
    r="${_tmp}/t5"
    _init_repo "$r"

    printf 'base\n' > "$r/base.txt"
    git -C "$r" add base.txt && git -C "$r" commit -m "base" --quiet

    git -C "$r" checkout -b feature --quiet
    _bigfile "$r" small.txt 10  # under default threshold of 50
    git -C "$r" add small.txt && git -C "$r" commit -m "feature: small file" --quiet
    ORIG_HEAD="$(git -C "$r" rev-parse HEAD)"

    # Drop the small file
    git -C "$r" reset --soft HEAD~1 --quiet
    git -C "$r" restore --staged small.txt 2>/dev/null \
        || git -C "$r" reset HEAD small.txt 2>/dev/null || true
    git -C "$r" checkout -- small.txt 2>/dev/null || rm -f "$r/small.txt"
    printf 'other\n' > "$r/other.txt"
    git -C "$r" add other.txt && git -C "$r" commit -m "rebased (small dropped)" --quiet

    rc=0
    CHUMP_REPO_ROOT="$r" CHUMP_AMBIENT_LOG="/dev/null" \
        "$PRV" --orig-head "$ORIG_HEAD" --base main 2>/dev/null || rc=$?
    [[ "$rc" -eq 0 ]] && _pass "T5: sub-threshold drop not flagged → exit 0" \
                      || _fail "T5: sub-threshold → expected 0, got $rc"
}

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
