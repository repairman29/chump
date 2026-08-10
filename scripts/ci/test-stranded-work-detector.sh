#!/usr/bin/env bash
# test-stranded-work-detector.sh — ZERO-WASTE-039
#
# Fixture test: seeds a synthetic repo with (a) a backdated dirty tracked
# file, (b) an ahead-branch carrying an old unmerged commit, (c) an aged
# stash — asserts the detector fires on it and writes a zero-loss patch
# BEFORE reporting. Then asserts it stays quiet on a freshly cloned clean
# tree.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/stranded-work-detector.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
hdr()  { printf '\n--- %s ---\n' "$*"; }

[[ -f "$DETECTOR" ]] || fail "detector script missing: $DETECTOR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

hdr "Seed fixture: origin + dirty/ahead-branch/aged-stash repo + clean clone"

ORIGIN="$TMP/origin.git"
git init --bare -q "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main

REPO="$TMP/repo"
git init -q -b main "$REPO"
(
    cd "$REPO"
    git remote add origin "$ORIGIN"
    echo hello > file.txt
    git add file.txt
    git -c user.email=t@t -c user.name=t commit -q -m init
    git push -q origin main

    old2d="@$(date -d '2 days ago' +%s) +0000"
    old10d="@$(date -d '10 days ago' +%s) +0000"

    # (b) ahead-branch: unmerged commit > 24h old
    git checkout -q -b feature-old
    echo x >> file2.txt
    git add file2.txt
    GIT_AUTHOR_DATE="$old2d" GIT_COMMITTER_DATE="$old2d" \
        git -c user.email=t@t -c user.name=t commit -q -m "old work"
    git checkout -q main

    # (d) aged stash: > 7d old
    echo stashme >> file3.txt
    GIT_AUTHOR_DATE="$old10d" GIT_COMMITTER_DATE="$old10d" \
        git -c user.email=t@t -c user.name=t stash push -q -u -m "old stash" -- file3.txt

    # (a) dirty tracked file, backdated mtime > 24h
    echo change >> file.txt
    touch -d "48 hours ago" file.txt
)

CLEAN="$TMP/clean"
git clone -q "$ORIGIN" "$CLEAN"

OUT_DIR="$(mktemp -d)"

hdr "Round 1: fires on the seeded fixture"

RESULT="$(CHUMP_STRANDED_ROOTS="$TMP" timeout 60 bash "$DETECTOR" --root "$TMP" --json --out-dir "$OUT_DIR")"
echo "$RESULT"

SUMMARY_LINE="$(printf '%s\n' "$RESULT" | grep '"summary":true')"
[[ -n "$SUMMARY_LINE" ]] || fail "no summary line emitted"

python3 - "$SUMMARY_LINE" <<'PYEOF' || fail "summary assertions failed"
import json, sys
d = json.loads(sys.argv[1])
assert d["stranded_checkouts"] >= 1, f"expected >=1 stranded checkout, got {d}"
assert d["dirty"] >= 1, f"expected dirty>=1, got {d}"
assert d["ahead_branches"] >= 1, f"expected ahead_branches>=1, got {d}"
assert d["aged_stashes"] >= 1, f"expected aged_stashes>=1, got {d}"
assert d["patches_written"] >= 1, f"expected patches_written>=1, got {d}"
PYEOF
ok "AC #1: detector fires on seeded fixture (dirty=1+, ahead_branches=1+, aged_stashes=1+)"

hdr "Round 2: zero-loss patch was written, contains the dirty diff"

PATCH_FILE="$(find "$OUT_DIR" -type f -name '*.patch' | head -1)"
[[ -n "$PATCH_FILE" ]] || fail "no patch file found under $OUT_DIR"
grep -q '^+change$' "$PATCH_FILE" || fail "patch file does not contain the dirty diff: $PATCH_FILE"
ok "AC #3: dated zero-loss patch written under out-dir, contains the dirty diff"

hdr "Round 3: no auto-commit, no auto-filed gap"

# The detector must never stage/commit inside the scanned repo, and must
# never shell out to `chump gap reserve` / `gap ship`.
grep -qE 'gap (reserve|ship)' "$DETECTOR" && fail "detector must never auto-file/ship gaps"
grep -qE '\bgit (commit|add)\b' "$DETECTOR" && fail "detector must never auto-commit"
ok "AC #5: no auto-commit / auto-file-gap code paths in the detector"

STATUS_AFTER="$(git -C "$REPO" status --porcelain)"
[[ "$STATUS_AFTER" == " M file.txt" ]] || fail "detector mutated the scanned repo's working tree: $STATUS_AFTER"
ok "AC #5 (runtime): scanned repo's working tree untouched by the scan"

hdr "Round 4: stays quiet on a clean tree"

CLEAN_RESULT="$(CHUMP_STRANDED_ROOTS="$TMP/clean" timeout 60 bash "$DETECTOR" --json --out-dir "$OUT_DIR")"
echo "$CLEAN_RESULT"
python3 - "$CLEAN_RESULT" <<'PYEOF' || fail "clean-tree assertions failed"
import json, sys
d = json.loads(sys.argv[1].strip().splitlines()[-1])
assert d["stranded_checkouts"] == 0, f"expected 0 stranded checkouts on clean tree, got {d}"
PYEOF
ok "clean tree stays quiet (stranded_checkouts=0)"

hdr "Round 5: EVENT_REGISTRY.yaml has kind: stranded_work registered"

REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -qE '^\s*-\s+kind:\s*stranded_work\s*$' "$REGISTRY" || fail "stranded_work not registered in $REGISTRY"
ok "AC #2: kind=stranded_work registered in EVENT_REGISTRY.yaml"

grep -q '"kind":"stranded_work"' "$DETECTOR" || fail "detector does not emit the literal stranded_work JSON kind (coverage-gate parity)"
ok "AC #2: detector emits literal \"kind\":\"stranded_work\" (CI parity with the coverage gate)"

printf '\n\033[0;32mALL PASS\033[0m — stranded-work-detector fixture test\n'
