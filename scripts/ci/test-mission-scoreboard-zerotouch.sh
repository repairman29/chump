#!/usr/bin/env bash
# test-mission-scoreboard-zerotouch.sh — COTG-3.3 / INFRA-3496.
#
# Proves axis ① of mission-scoreboard.sh classifies a BEAST merge by the
# `Chump-Agent:` commit trailer (the fleet's autonomous signature), not by a raw
# merge count. Depth: correctness — a stub `gh` injects one merged BEAST PR whose
# commit body either carries the trailer (→ zero-touch YES) or doesn't (→ NO,
# human-in-loop). Hermetic: no network; stub `gh` on PATH.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="$REPO_ROOT/scripts/dev/mission-scoreboard.sh"
[ -f "$SB" ] || { echo "[test] FAIL: $SB missing"; exit 1; }

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

# Stub gh: one merged BEAST PR (#999); its commit body comes from $STUB_BODY.
# Every other gh call returns empty (the rest of the scoreboard degrades cleanly).
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"pr list"*"--json number"*) echo "999" ;;
  *"pr view"*commits*)          printf '%s\n' "${STUB_BODY:-}" ;;
  *)                            : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

run() { PATH="$STUB_DIR:$PATH" STUB_BODY="$1" timeout 90 bash "$SB" 2>/dev/null; }

fail=0

# (a) commit WITH the Chump-Agent trailer → zero-touch YES
out="$(run 'implement the thing

Chump-Agent: Widget@test-machine')"
if echo "$out" | grep -qE '① THE BINARY.*'; then :; fi
if echo "$out" | grep -q 'zero-touch (Chump-Agent) of'; then
  echo "[test] (a) trailered merge → ① reports zero-touch: OK"
else
  echo "[test] (a) FAIL: trailered merge not reported as zero-touch"; echo "$out" | grep -A1 '① THE BINARY'; fail=1
fi

# (b) commit WITHOUT the trailer → NOT zero-touch (human-in-loop)
out="$(run 'a human fixed this

Co-Authored-By: Somebody <x@y.z>')"
if echo "$out" | grep -qE 'human-in-loop, not zero-touch'; then
  echo "[test] (b) untrailered merge → ① reports human-in-loop NO: OK"
else
  echo "[test] (b) FAIL: untrailered merge not reported as human-in-loop"; echo "$out" | grep -A1 '① THE BINARY'; fail=1
fi

[ "$fail" -eq 0 ] && echo "[test-mission-scoreboard-zerotouch] PASS" || { echo "[test-mission-scoreboard-zerotouch] FAIL"; exit 1; }
