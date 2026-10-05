#!/usr/bin/env bash
# test-mission-scoreboard-deploy-freshness-sla.sh — CREDIBLE-293.
#
# Proves axis ③ of mission-scoreboard.sh is a FRESHNESS SLA, not an instant
# binary-SHA-vs-origin/main snapshot. Before this fix, any moment main was
# ahead of the last auto-deploy cycle (i.e. most of the time, since main
# moves every ~10-20 min and auto-deploy runs every ~20 min) flipped ③ to
# "NO auto-deploy" on ordinary timing luck. The fix: pass if the binary is
# current OR the lag since the last main-move is within the SLA window;
# fail only once the lag exceeds the SLA (a real deploy regression).
#
# Hermetic: builds a scratch git repo + fake `chump`/`gh` binaries on PATH;
# no network, no dependency on the real .chump/state.db.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="$REPO_ROOT/scripts/dev/mission-scoreboard.sh"
[ -f "$SB" ] || { echo "[test] FAIL: $SB missing"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR"
# Stub gh: no merged PRs anywhere — keeps ①②④ inert so only ③ is under test.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"--json number"*) echo "0" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name test

fail=0

commit_at() {  # commit_at <epoch>
  local ep="$1"
  local iso
  iso="$(date -u -r "$ep" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$ep" +%Y-%m-%dT%H:%MZ)"
  date -u > "$REPO/f.txt"
  git -C "$REPO" add f.txt
  GIT_AUTHOR_DATE="$iso" GIT_COMMITTER_DATE="$iso" git -C "$REPO" commit -q -m "commit at $ep"
}

run_with_binep() {  # run_with_binep <binary-epoch>
  local binep="$1"
  local chump_path="$STUB_DIR/chump"
  cat > "$chump_path" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$chump_path"
  touch -d "@$binep" "$chump_path" 2>/dev/null || touch -t "$(date -u -r "$binep" +%Y%m%d%H%M.%S)" "$chump_path"
  (cd "$REPO" && PATH="$STUB_DIR:$PATH" timeout 90 bash "$SB" 2>/dev/null)
}

now="$(date -u +%s)"

# (a) binary built AFTER the latest main-move → current, PASS.
commit_at "$((now - 3600))"
out="$(run_with_binep "$now")"
if echo "$out" | grep -q '✅ within freshness SLA'; then
  echo "[test] (a) binary newer than latest main-move → ③ PASS: OK"
else
  echo "[test] (a) FAIL: expected PASS when binary is current"; echo "$out" | grep -A2 '③ Deploy'; fail=1
fi

# (b) main moved 60s ago, binary is stale but well within the SLA cadence
#     window (default 1800s) → transient lag, still PASS.
commit_at "$((now - 60))"
out="$(run_with_binep "$((now - 3600))")"
if echo "$out" | grep -q '✅ within freshness SLA'; then
  echo "[test] (b) transient lag (60s since main-move) → ③ PASS: OK"
else
  echo "[test] (b) FAIL: expected PASS for lag within SLA window"; echo "$out" | grep -A2 '③ Deploy'; fail=1
fi

# (c) main moved 3600s ago (well beyond the 1800s SLA) and binary is still
#     older than that move → real regression, FAIL.
commit_at "$((now - 3600))"
out="$(run_with_binep "$((now - 7200))")"
if echo "$out" | grep -q '❌ STALE'; then
  echo "[test] (c) lag beyond SLA (3600s since main-move) → ③ FAIL: OK"
else
  echo "[test] (c) FAIL: expected STALE verdict for lag beyond SLA"; echo "$out" | grep -A2 '③ Deploy'; fail=1
fi

[ "$fail" -eq 0 ] && echo "[test-mission-scoreboard-deploy-freshness-sla] PASS" || { echo "[test-mission-scoreboard-deploy-freshness-sla] FAIL"; exit 1; }
