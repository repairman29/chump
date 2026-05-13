#!/usr/bin/env bash
# scripts/ci/test-bot-merge-stale-gate.sh — INFRA-995
#
# Verifies the pre-push staleness gate in scripts/coord/bot-merge.sh:
#   1. The check block is present + uses git rev-list HEAD..REMOTE/BASE.
#   2. Default threshold is 15 (CHUMP_BOT_MERGE_STALE_THRESHOLD).
#   3. Emits kind=stale_branch_blocked with required fields when triggered.
#   4. Exit code 3 (matches the documented "branch too stale" code).
#   5. EVENT_REGISTRY.yaml registers stale_branch_blocked.
#
# We don't simulate a full bot-merge run (too many cargo deps); instead we
# extract the staleness block, source it under a controlled env with a fake
# git that reports a chosen BEHIND count, and assert the ambient + exit code.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. Static-grep checks ────────────────────────────────────────────────────
grep -q "INFRA-995: pre-push staleness gate" "$BOT_MERGE" \
    || fail "staleness gate banner missing from bot-merge.sh"
grep -q 'STALE_REBASE_THRESHOLD="\${CHUMP_BOT_MERGE_STALE_THRESHOLD:-15}"' "$BOT_MERGE" \
    || fail "default threshold 15 not configured via CHUMP_BOT_MERGE_STALE_THRESHOLD"
grep -q 'git rev-list --count "HEAD..\${REMOTE}/\${BASE_BRANCH}"' "$BOT_MERGE" \
    || fail "behind-count computation missing or wrong (expected git rev-list HEAD..REMOTE/BASE)"
grep -q '"kind":"stale_branch_blocked"' "$BOT_MERGE" \
    || fail "stale_branch_blocked ambient emission missing"
grep -q '_bm_fail "stale-branch" 3' "$BOT_MERGE" \
    || fail "exit code 3 + label 'stale-branch' not wired via _bm_fail"
ok "static grep: block present + threshold 15 + ambient kind + exit 3"

# ── 2. EVENT_REGISTRY contains the new event with required fields ───────────
python3 - "$REG" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
assert "kind: stale_branch_blocked" in text, "stale_branch_blocked not registered"
# Section spans from its kind line to next blank-line-separated entry.
m = re.search(r"- kind: stale_branch_blocked.*?(?=\n  -|\Z)", text, re.S)
assert m, "could not extract stale_branch_blocked registry block"
block = m.group(0)
for f in ("ts", "kind", "branch", "behind", "threshold", "phase"):
    assert f in block, f"fields_required missing {f!r}: {block}"
PY
ok "EVENT_REGISTRY.yaml registers stale_branch_blocked with all 6 required fields"

# ── 3. Simulate the staleness block by extracting + executing it ────────────
# We can't run bot-merge.sh end-to-end without cargo, but the staleness
# block is well-contained: source helpers + drive with a fake git.
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/git" <<EOF
#!/usr/bin/env bash
# Fake git: rev-list reports a chosen BEHIND; fetch is a no-op.
case "\$1" in
    rev-list)
        echo "\${TEST_BEHIND:-0}"
        ;;
    fetch)
        exit 0
        ;;
    *)
        # passthrough not needed for this isolated test
        exit 0
        ;;
esac
EOF
chmod +x "$TMP/fakebin/git"

# Stub run_timed_hb + _bm_fail + red so the block runs out-of-context.
RUNNER="$TMP/run-stale-block.sh"
cat >"$RUNNER" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

REMOTE=origin
BASE_BRANCH=main
BRANCH=test/stale-fixture
DRY_RUN=0
LOCK_DIR="$AMB_DIR/.chump-locks"
REPO_ROOT="$AMB_DIR"

red()  { echo "RED: $*"; }
info() { echo "INFO: $*"; }
run_timed_hb() { shift 2; "$@"; }   # drop label + timeout, just run
_bm_fail() { echo "FAIL label=$1 code=$2 msg=$3"; exit "$2"; }

EOF
# Append the actual staleness block from bot-merge.sh (extract lines between
# our marker and the "## ── 5. Push" header).
awk '
    /INFRA-995: pre-push staleness gate/ {grab=1}
    grab {print}
    /^# ── 5\. Push/ {exit}
' "$BOT_MERGE" >>"$RUNNER"

chmod +x "$RUNNER"

# Case A: BEHIND = 5 ≤ 15 → block does not fail, no ambient event.
AMB_DIR="$TMP/caseA"
mkdir -p "$AMB_DIR/.chump-locks"
PATH="$TMP/fakebin:$PATH" AMB_DIR="$AMB_DIR" TEST_BEHIND=5 bash "$RUNNER"
rc=$?
[[ "$rc" -eq 0 ]] || fail "BEHIND=5 should pass, got rc=$rc"
[[ ! -s "$AMB_DIR/.chump-locks/ambient.jsonl" ]] \
    || fail "BEHIND=5 should NOT emit, but ambient has: $(cat "$AMB_DIR/.chump-locks/ambient.jsonl")"
ok "BEHIND=5 (under threshold) → no block, no ambient event"

# Case B: BEHIND = 30 > 15 → block exits 3 + emits stale_branch_blocked.
AMB_DIR="$TMP/caseB"
mkdir -p "$AMB_DIR/.chump-locks"
set +e
PATH="$TMP/fakebin:$PATH" AMB_DIR="$AMB_DIR" TEST_BEHIND=30 bash "$RUNNER"
rc=$?
set -e
[[ "$rc" -eq 3 ]] || fail "BEHIND=30 should exit 3, got rc=$rc"
amb="$AMB_DIR/.chump-locks/ambient.jsonl"
[[ -s "$amb" ]] || fail "BEHIND=30 should emit ambient line, file empty/missing"
line="$(cat "$amb")"
for f in '"kind":"stale_branch_blocked"' '"behind":30' '"threshold":15' '"phase":"pre-push"' '"branch":"test/stale-fixture"' ; do
    grep -q "$f" <<<"$line" || fail "ambient line missing $f: $line"
done
ok "BEHIND=30 → exit 3 + stale_branch_blocked event with all fields"

# Case C: override threshold via env var.
AMB_DIR="$TMP/caseC"
mkdir -p "$AMB_DIR/.chump-locks"
PATH="$TMP/fakebin:$PATH" AMB_DIR="$AMB_DIR" TEST_BEHIND=20 \
    CHUMP_BOT_MERGE_STALE_THRESHOLD=25 bash "$RUNNER"
rc=$?
[[ "$rc" -eq 0 ]] || fail "BEHIND=20 with threshold=25 should pass, got rc=$rc"
[[ ! -s "$AMB_DIR/.chump-locks/ambient.jsonl" ]] \
    || fail "BEHIND=20 under override threshold 25 should NOT emit"
ok "CHUMP_BOT_MERGE_STALE_THRESHOLD env override raises threshold"

echo
echo "All bot-merge staleness-gate tests passed."
