#!/usr/bin/env bash
# repro-ship-count-zero.sh — CREDIBLE-597 (slice of CREDIBLE-129)
#
# Reproduces, in a disposable sandbox repo, the exact mechanism behind
# fleet-brief.sh intermittently reporting "Ships: 0" while the fleet is
# actively shipping.
#
# Root cause demonstrated here: fleet-brief.sh's _git_log_24h() does
#   git -C "$MAIN_REPO" log --format="%s" --after="24 hours ago" origin/main \
#       2>/dev/null || true
# `origin/main` is a loose ref file. During a real `git fetch`'s internal
# ref-consolidation step (git migrates a loose ref into packed-refs and then
# removes the loose file — this also fires from `git gc --auto`, which
# fetch triggers opportunistically once loose-object/ref counts cross a
# threshold), there is a window where the loose ref file has been removed
# but the read path hasn't fallen back to packed-refs yet, OR (as forced
# here for determinism) the ref is simply unavailable for the duration of a
# stalled/timed-out fetch. `git log <rev>` against an unresolvable rev exits
# 128. The `2>/dev/null` swallows the "unknown revision" error and `|| true`
# swallows the non-zero exit — so the caller sees an empty string, and
# `grep -c .` on empty input reports 0. No error surfaces anywhere: the
# brief just silently prints "Ships: 0".
#
# Usage: bash scripts/dev/repro-ship-count-zero.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLEET_BRIEF="$REPO_ROOT/scripts/dispatch/fleet-brief.sh"
WORK="$(mktemp -d /tmp/credible597-repro.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "=== 1. Build a sandbox repo with 3 real 'ships' on origin/main ==="
git init --bare -q "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/work"
cd "$WORK/work"
git config user.email test@test.com
git config user.name test
git branch -m master main 2>/dev/null || true
for i in 1 2 3; do
    echo "commit $i" >"f$i.txt"
    git add "f$i.txt"
    git commit -q -m "chore(TEST-$i): CREDIBLE — test commit $i"
done
git push -q origin main
mkdir -p .chump-locks

echo ""
echo "=== 2. Ground truth: fleet-brief.sh with an intact origin/main ref ==="
bash "$FLEET_BRIEF" | head -3

REF_FILE=".git/refs/remotes/origin/main"
BACKUP="$WORK/main-ref-backup"
cp "$REF_FILE" "$BACKUP"

echo ""
echo "=== 3. Force the failure window: origin/main transiently unresolvable"
echo "    (this is what a real fetch's loose-ref -> packed-refs migration,"
echo "    or a timed-out/killed fetch mid ref-update, produces) ==="
rm "$REF_FILE"

echo "--- git log against the missing ref (stderr shown, undoctored) ---"
git log --format="%s" --after="24 hours ago" origin/main
echo "exit=$?"

echo ""
echo "--- same call exactly as fleet-brief.sh's _git_log_24h() runs it"
echo "    (stderr silenced, failure swallowed by || true) ---"
subjects="$(git -C "$WORK/work" log --format="%s" --after="24 hours ago" origin/main 2>/dev/null || true)"
echo "captured subjects: '<${subjects}>' (empty)"

echo ""
echo "=== 4. fleet-brief.sh during the failure window ==="
bash "$FLEET_BRIEF" | head -3

echo ""
echo "=== 5. Restore the ref — fleet-brief.sh recovers with no state changed ==="
cp "$BACKUP" "$REF_FILE"
bash "$FLEET_BRIEF" | head -3
