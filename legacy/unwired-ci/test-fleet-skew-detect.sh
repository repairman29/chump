#!/usr/bin/env bash
# RESILIENT-155 regression: the fleet version-skew detector must measure the
# WORKING-TREE worker.sh against origin/main — NOT HEAD.
#
# WHY: the fleet's main checkout HEAD is permanently behind origin/main (the
# dirty tree blocks ff/pull). RESILIENT-152 self-sync keeps the WORKING TREE
# current without advancing HEAD. A HEAD-based skew check therefore reports skew
# forever even when the working tree is current → the autorestart daemon loops
# endlessly (observed 2026-06-21: restart every ~60s, 0 ships). This test pins
# the working-tree semantics so the false-loop cannot regress.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.."
ROOT="$(cd "$ROOT" && pwd)"
DETECTOR="$ROOT/scripts/dev/fleet-version-skew-detect.sh"
[[ -f "$DETECTOR" ]] || { echo "FAIL: detector not found at $DETECTOR"; exit 1; }

fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
origin="$tmp/origin.git"; co="$tmp/co"

git init -q --bare "$origin"
git clone -q "$origin" "$co"
( cd "$co"
  git config user.email t@t; git config user.name t
  git checkout -q -b main
  mkdir -p scripts/dispatch
  printf 'echo V1\n' > scripts/dispatch/worker.sh
  git add scripts/dispatch/worker.sh; git commit -q -m v1
  git push -q -u origin main )

# Advance origin/main to V2 (worker.sh changed) via a 2nd clone.
c2="$tmp/c2"; git clone -q "$origin" "$c2"
( cd "$c2"
  git config user.email t@t; git config user.name t
  git checkout -q main
  printf 'echo V2\n' > scripts/dispatch/worker.sh
  git add scripts/dispatch/worker.sh; git commit -q -m v2
  git push -q origin main )

run_detector() { ( cd "$co" && bash "$DETECTOR" --quiet --no-emit >/dev/null 2>&1 ); }

# ── State 1: working-tree worker.sh = V1, origin/main = V2 → genuinely stale ──
# Detector MUST report skew (exit 1): the running fleet is on stale code.
if run_detector; then
  fail "stale working tree (V1 vs origin/main V2): detector exited 0, expected 1 (skew)"
else
  ok "stale working-tree worker.sh → detector reports skew (exit 1)"
fi

# ── State 2: deploy origin/main worker.sh into the working tree (self-sync) ────
# HEAD stays at V1 (behind origin/main) — THIS is the false-loop scenario.
( cd "$co" && git checkout origin/main -- scripts/dispatch/worker.sh && git reset -q -- scripts/dispatch/worker.sh )
behind="$(cd "$co" && git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
if [[ "$behind" -ge 1 ]]; then
  ok "HEAD still behind origin/main ($behind commit(s)) — false-loop scenario set up"
else
  fail "fixture broken: HEAD not behind origin/main (got $behind)"
fi
# Detector MUST report NO skew (exit 0): the working tree is current even though
# HEAD is behind. The OLD HEAD-based detector looped here; the fix must pass.
if run_detector; then
  ok "current working tree + behind HEAD → NO skew (exit 0) — false-loop FIXED"
else
  fail "false-loop REGRESSION: working tree current but detector still reports skew (would loop)"
fi

echo ""
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: test-fleet-skew-detect (working-tree semantics; no false-loop)"
  exit 0
else
  echo "FAIL: test-fleet-skew-detect ($fails assertion(s) failed)"
  exit 1
fi
