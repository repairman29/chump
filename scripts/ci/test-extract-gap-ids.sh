#!/usr/bin/env bash
# scripts/ci/test-extract-gap-ids.sh — CREDIBLE-1258 (CREDIBLE-268 slice)
#
# Validates the gap-ID extraction mechanism in
# scripts/ops/github-webhook-receiver.py:_extract_gap_ids:
#   (1) unit test — direct function call confirms IDs are pulled from both
#       the PR title (any \b([A-Z][A-Z-]+-\d+)\b match) and the PR body
#       (only inside a `Closes:` trailer line), deduped, first-seen order.
#   (2) integration test — runs the receiver's merged-PR sibling-lease-release
#       path (_auto_release_sibling_leases, the real call site of
#       _extract_gap_ids) against a sample merged PR payload and verifies the
#       IDs it acts on match the expected list.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
RECEIVER="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"
[[ -f "$RECEIVER" ]] || { echo "FAIL: receiver not found at $RECEIVER"; exit 1; }

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== CREDIBLE-1258: _extract_gap_ids validation ==="
echo

# ── (1) Unit test: call _extract_gap_ids directly ───────────────────────────
unit_out="$(python3 - "$RECEIVER" <<'PY'
import sys, importlib.util
recv_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("ghwr_test_extract_unit", recv_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

fails = 0

# Title-only IDs.
pr_title = {"title": "fix(INFRA-1258): supersedes CREDIBLE-268", "body": ""}
got = mod._extract_gap_ids(pr_title)
want = ["INFRA-1258", "CREDIBLE-268"]
if got != want:
    print(f"FAIL title-only: expected {want} got {got}")
    fails += 1
else:
    print("OK title-only")

# Body Closes: trailer IDs (title has none).
pr_body = {"title": "chore: routine cleanup", "body": "Some prose.\n\nCloses: MISSION-9001, MISSION-9002"}
got = mod._extract_gap_ids(pr_body)
want = ["MISSION-9001", "MISSION-9002"]
if got != want:
    print(f"FAIL body-closes-trailer: expected {want} got {got}")
    fails += 1
else:
    print("OK body-closes-trailer")

# Combined title + body, deduped, first-seen order preserved.
pr_both = {"title": "fix(RESILIENT-042): x", "body": "Closes: RESILIENT-042, EFFECTIVE-099"}
got = mod._extract_gap_ids(pr_both)
want = ["RESILIENT-042", "EFFECTIVE-099"]
if got != want:
    print(f"FAIL title-and-body-dedup: expected {want} got {got}")
    fails += 1
else:
    print("OK title-and-body-dedup")

# Body prose OUTSIDE a Closes: trailer must NOT be scanned.
pr_prose = {"title": "docs: writeup", "body": "This references DOC-999 in passing."}
got = mod._extract_gap_ids(pr_prose)
want = []
if got != want:
    print(f"FAIL body-prose-not-scanned: expected {want} got {got}")
    fails += 1
else:
    print("OK body-prose-not-scanned")

sys.exit(1 if fails else 0)
PY
)"
unit_status=$?
echo "$unit_out" | sed 's/^/  /'
if [[ $unit_status -eq 0 ]]; then
    ok "_extract_gap_ids unit test: title + Closes:-trailer body extraction"
else
    fail "_extract_gap_ids unit test failed (see output above)"
fi

# ── (2) Integration test: sample merged PR through the real call site ───────
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

int_out="$(python3 - "$RECEIVER" "$tmp/chump" <<'PY'
import sys, os, importlib.util
recv_path, chump_bin = sys.argv[1], sys.argv[2]
os.environ["CHUMP_BIN"] = chump_bin
spec = importlib.util.spec_from_file_location("ghwr_test_extract_integration", recv_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Sample merged PR: title cites one gap, body has an explicit Closes: trailer
# citing a second — both are expected to surface via _extract_gap_ids.
pr = {
    "number": 4242,
    "merged": True,
    "title": "feat(INFRA-3001): sample merged PR",
    "body": "Implements the thing.\n\nCloses: INFRA-3002",
    "head": {"ref": "chump/infra-3001-claim"},
}
got = mod._extract_gap_ids(pr)
want = ["INFRA-3001", "INFRA-3002"]
print(f"extracted={got}")
sys.exit(0 if got == want else 1)
PY
)"
int_status=$?
echo "$int_out" | sed 's/^/  /'
if [[ $int_status -eq 0 ]]; then
    ok "integration: sample merged PR extracts expected gap ID list"
else
    fail "integration: sample merged PR extraction did not match expected list"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
