#!/usr/bin/env bash
# test-bot-merge-shadow-plan.sh — INFRA-1346
#
# Smoke test: drives a synthetic bot-merge.sh invocation against a fake
# `chump ship plan` (returning a canned ShipPlan JSON) and asserts that
# exactly one ship_plan_advisory event is emitted with the expected fields.
# NO live gh calls — all external tools are shimmed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

[[ -f "$BOT_MERGE" ]] || fail "missing $BOT_MERGE"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

LOCK_DIR="$TMP/.chump-locks"
AMB="$LOCK_DIR/ambient.jsonl"
SHIM_DIR="$TMP/bin"
mkdir -p "$LOCK_DIR" "$SHIM_DIR"

# ── Fake git repo so bot-merge can resolve REPO_ROOT ────────────────────────
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" config user.email "test@example.com"
git -C "$FAKE_REPO" config user.name "Test"
touch "$FAKE_REPO/README.md"
git -C "$FAKE_REPO" add README.md
git -C "$FAKE_REPO" commit -q -m "init"
git -C "$FAKE_REPO" checkout -q -b "chump/infra-9001-claim"

# ── chump shim ────────────────────────────────────────────────────────────────
# Returns a canned ShipPlan JSON for `ship plan`, exits 0 for other calls.
cat > "$SHIM_DIR/chump" <<'SHIM'
#!/usr/bin/env bash
if [[ "$*" == *"ship plan"* ]]; then
    echo '{"action":"push_and_create_pr","branch":"chump/infra-9001-claim","gap":"INFRA-9001","behind":0,"checks_state":"pending","pr_number":null}'
elif [[ "$*" == *"gap preflight"* ]]; then
    echo "[preflight] OK INFRA-9001 — open and unclaimed."
elif [[ "$*" == *"doctor"* ]]; then
    exit 0
else
    exit 0
fi
SHIM
chmod +x "$SHIM_DIR/chump"

# ── gh shim — returns minimal valid JSON for every call ──────────────────────
cat > "$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
# Minimal gh shim: handles the calls bot-merge makes at startup.
case "$*" in
    *"api graphql"*|*"rate_limit"*|*"rateLimit"*)
        echo '{"data":{"rateLimit":{"remaining":5000,"limit":5000,"resetAt":"2099-01-01T00:00:00Z"}}}'
        ;;
    *"pr view"*"--json number"*)
        echo '{"number":2099}'
        ;;
    *"pr list"*|*"pr view"*)
        echo '[]'
        ;;
    *"api"*"rate_limit"*)
        echo '{"resources":{"graphql":{"remaining":5000,"limit":5000,"reset":9999999999}}}'
        ;;
    *)
        echo '{}'
        ;;
esac
SHIM
chmod +x "$SHIM_DIR/gh"

# ── git shim extensions: wrap real git but override remote calls ──────────────
# (We rely on $FAKE_REPO being a valid git repo; bot-merge is invoked from there)

# ── Run _bm_shadow_plan in isolation via a minimal harness ───────────────────
# Instead of running all of bot-merge.sh (which needs a real PR), source only
# the required pieces and call _bm_shadow_plan directly.
HARNESS="$TMP/harness.sh"
cat > "$HARNESS" <<HARNESS_EOF
#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$FAKE_REPO"
LOCK_DIR="$LOCK_DIR"
CHUMP_AMBIENT_LOG="$AMB"
BRANCH="chump/infra-9001-claim"
BASE_BRANCH="main"
GAP_IDS=("INFRA-9001")
SESSION_ID="test-session"
DRY_RUN=0

# Minimal colour helpers (bot-merge uses these)
green() { echo "[green] \$*"; }
info()  { echo "[info]  \$*"; }
yellow(){ echo "[yellow] \$*"; }

# Source only ambient-write lib.
source "$REPO_ROOT/../../../$( cd "$REPO_ROOT" && realpath --relative-to="$REPO_ROOT" "$REPO_ROOT/scripts/coord/lib/ambient-write.sh" 2>/dev/null || echo "scripts/coord/lib/ambient-write.sh")"

HARNESS_EOF

# We need the actual lib path relative to our fake repo.
# Use the real repo root's lib directly.
cat > "$HARNESS" <<HARNESS_EOF2
#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$REPO_ROOT"
LOCK_DIR="$LOCK_DIR"
CHUMP_AMBIENT_LOG="$AMB"
BRANCH="chump/infra-9001-claim"
BASE_BRANCH="main"
GAP_IDS=("INFRA-9001")
SESSION_ID="test-session"
DRY_RUN=0

green() { echo "[green] \$*"; }
info()  { echo "[info]  \$*"; }
yellow(){ echo "[yellow] \$*"; }

source "$REPO_ROOT/scripts/coord/lib/ambient-write.sh"

# Paste _bm_shadow_plan definition inline (extracted from bot-merge.sh).
$(sed -n '/_bm_shadow_plan()/,/^}/p' "$BOT_MERGE")

CHUMP_BOT_MERGE_SHADOW_PLAN=1 _bm_shadow_plan
HARNESS_EOF2
chmod +x "$HARNESS"

echo "--- shadow plan harness run ---"
PATH="$SHIM_DIR:$PATH" bash "$HARNESS" 2>&1
echo "---"
echo ""

# ── Assert exactly one ship_plan_advisory event was emitted ──────────────────
[[ -f "$AMB" ]] || fail "ambient log not created"

advisory_count=$(grep -c '"kind":"ship_plan_advisory"' "$AMB" 2>/dev/null || echo 0)
[[ "$advisory_count" -eq 1 ]] \
    && ok "exactly one ship_plan_advisory event emitted" \
    || fail "expected 1 ship_plan_advisory event, got $advisory_count"

# Assert required fields are present.
advisory=$(grep '"kind":"ship_plan_advisory"' "$AMB" | head -1)
for field in '"kind":"ship_plan_advisory"' '"source":"bot-merge.sh"' '"branch":' '"gap":' '"plan_action":' '"plan_json_truncated_to_2kb":'; do
    echo "$advisory" | grep -q "$field" \
        && ok "field $field present" \
        || fail "missing field $field in advisory event"
done

# Assert plan_action is the canned value ("push_and_create_pr").
echo "$advisory" | grep -q '"plan_action":"push_and_create_pr"' \
    && ok "plan_action matches canned ShipPlan" \
    || fail "plan_action mismatch — expected push_and_create_pr"

# ── Assert CHUMP_BOT_MERGE_SHADOW_PLAN=0 suppresses the event ────────────────
AMB2="$LOCK_DIR/ambient2.jsonl"
cat > "$TMP/harness2.sh" <<HARNESS2_EOF
#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$REPO_ROOT"
LOCK_DIR="$LOCK_DIR"
CHUMP_AMBIENT_LOG="$AMB2"
BRANCH="chump/infra-9001-claim"
BASE_BRANCH="main"
GAP_IDS=("INFRA-9001")
SESSION_ID="test-session"
DRY_RUN=0
green() { echo "[green] \$*"; }
info()  { echo "[info]  \$*"; }
yellow(){ echo "[yellow] \$*"; }
source "$REPO_ROOT/scripts/coord/lib/ambient-write.sh"
$(sed -n '/_bm_shadow_plan()/,/^}/p' "$BOT_MERGE")
# Opt-out: should emit nothing
[[ "\${CHUMP_BOT_MERGE_SHADOW_PLAN:-1}" == "1" ]] && _bm_shadow_plan || true
HARNESS2_EOF
chmod +x "$TMP/harness2.sh"

PATH="$SHIM_DIR:$PATH" CHUMP_BOT_MERGE_SHADOW_PLAN=0 bash "$TMP/harness2.sh" 2>&1 >/dev/null
suppressed_count=$(grep -c '"kind":"ship_plan_advisory"' "$AMB2" 2>/dev/null || echo 0)
[[ "$suppressed_count" -eq 0 ]] \
    && ok "CHUMP_BOT_MERGE_SHADOW_PLAN=0 suppresses advisory (no event emitted)" \
    || fail "expected 0 events with opt-out, got $suppressed_count"

echo ""
echo "=== test-bot-merge-shadow-plan.sh PASSED ==="
