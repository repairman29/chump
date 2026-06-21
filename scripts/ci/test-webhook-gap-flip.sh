#!/usr/bin/env bash
# CREDIBLE-092 regression guard.
#
# The webhook receiver (runs LOCALLY, has .chump/state.db access) must flip a
# merged PR's referenced gaps to status=done. This fixes the root cause that
# .github/workflows/auto-flip-on-merge.yml could not: CI has no canonical
# state.db, so merged gaps stayed 'open' and got re-claimed (ghost-gap waste).
#
# Asserts: (a) the flip fn exists + is wired into the merged-PR handler; (b) a
# merged PR flips its gap to done with closed_pr set; (c) a closed-UNMERGED PR
# does NOT flip (no regression).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # scripts/
RECV="$ROOT/ops/github-webhook-receiver.py"
[[ -f "$RECV" ]] || { echo "FAIL: receiver not found at $RECV"; exit 1; }

fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

# (a) static wiring
grep -q 'def _auto_flip_gaps_done' "$RECV" && ok "flip fn defined" || fail "no _auto_flip_gaps_done"
grep -q '"set", gid' "$RECV" && grep -q '"--status",' "$RECV" && grep -q '"done"' "$RECV" \
  && ok "flip calls chump gap set --status done" || fail "flip does not call chump gap set --status done"
grep -q '_auto_flip_gaps_done(pr, payload)' "$RECV" && ok "wired into merged-PR handler" || fail "not wired into handler"

# (b)/(c) behavioral: stub chump, importlib-load receiver, exercise both paths
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/chump" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CHUMP_STUB_CALLS"
exit 0
STUB
chmod +x "$tmp/chump"
export CHUMP_STUB_CALLS="$tmp/calls"
: > "$CHUMP_STUB_CALLS"

python3 - "$RECV" "$tmp/chump" <<'PY'
import sys, os, importlib.util
recv_path, chump_bin = sys.argv[1], sys.argv[2]
os.environ["CHUMP_BIN"] = chump_bin
spec = importlib.util.spec_from_file_location("ghwr_test", recv_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
# merged PR carrying a gap id in title + branch
pr = {"number": 9999, "merged": True,
      "title": "fix(MISSION-9001): something",
      "body": "Gap: MISSION-9001",
      "head": {"ref": "chump/mission-9001-claim"}}
print("merged_flip_count=%d" % mod._auto_flip_gaps_done(pr, {"action": "closed", "pull_request": pr}))
# closed-UNMERGED PR — must NOT flip
pr2 = {"number": 9998, "merged": False,
       "title": "fix(MISSION-9002): x", "body": "Gap: MISSION-9002",
       "head": {"ref": "chump/mission-9002-claim"}}
print("unmerged_flip_count=%d" % mod._auto_flip_gaps_done(pr2, {"action": "closed", "pull_request": pr2}))
PY

grep -q 'gap set MISSION-9001 --status done --closed-pr 9999' "$CHUMP_STUB_CALLS" \
  && ok "merged PR flipped MISSION-9001 -> done (closed-pr 9999)" \
  || fail "merged-PR flip call wrong/missing. calls: [$(tr '\n' '|' <"$CHUMP_STUB_CALLS")]"
grep -q 'MISSION-9002' "$CHUMP_STUB_CALLS" \
  && fail "closed-UNMERGED PR wrongly flipped MISSION-9002" \
  || ok "closed-unmerged PR did NOT flip (no regression)"

echo ""
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: test-webhook-gap-flip.sh (merged gaps auto-flip locally; unmerged left open)"
  exit 0
else
  echo "FAIL: test-webhook-gap-flip.sh ($fails assertion(s) failed)"
  exit 1
fi
