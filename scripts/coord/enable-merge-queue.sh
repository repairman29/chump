#!/usr/bin/env bash
# scripts/coord/enable-merge-queue.sh — RESILIENT-343
#
# One-command operator flip for GitHub's native merge queue, gated behind
# the same pre-flip readiness check documented in docs/process/MERGE_QUEUE.md.
#
# Problem this closes: the only prior path to flipping "Require merge queue"
# was a manual web-UI walkthrough (docs/process/MERGE_QUEUE.md "Option A"),
# with no automated guard against flipping it while a required check is
# missing merge_group coverage (which would wedge the queue forever — a
# required check that never runs against the queue's synthetic merge commit).
#
# Modes:
#   Default (dry-run): runs the coverage readiness gate, reports current
#   merge-queue state, and prints what WOULD change. Never mutates GitHub.
#   --confirm: after the readiness gate passes, performs the mutation via
#   the GraphQL repository ruleset API. Requires operator sign-off per
#   CLAUDE.md — this flag must be passed explicitly, never inferred.
#
# Usage:
#   bash scripts/coord/enable-merge-queue.sh              # dry-run (safe, default)
#   bash scripts/coord/enable-merge-queue.sh --confirm     # actually flips branch protection
#
# See docs/process/MERGE_QUEUE.md for the full operator runbook.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")}"
LOCKS_DIR="${LOCKS_DIR:-${REPO_ROOT}/.chump-locks}"
COVERAGE_SCRIPT="${COVERAGE_SCRIPT:-${REPO_ROOT}/scripts/ci/test-merge-group-coverage.sh}"

CONFIRM=0
for arg in "$@"; do
    case "${arg}" in
        --confirm) CONFIRM=1 ;;
        --dry-run) CONFIRM=0 ;;
        -h|--help)
            printf 'Usage: %s [--confirm]\n' "$0"
            printf '  (no flag)   dry-run: readiness check + report only, no mutation\n'
            printf '  --confirm   flip branch protection to require merge queue (operator sign-off)\n'
            exit 0
            ;;
    esac
done

ok()   { printf '\033[0;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }

_ambient_write() {
    printf '%s\n' "$2" >> "$1" 2>/dev/null || true
}

emit_ambient() {
    local kind="$1" detail="$2" ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    mkdir -p "${LOCKS_DIR}" 2>/dev/null || true
    _ambient_write "${LOCKS_DIR}/ambient.jsonl" \
        "$(printf '{"ts":"%s","kind":"%s","detail":"%s"}' "${ts}" "${kind}" "${detail}")"
}

echo "=== RESILIENT-343 merge queue enablement ==="
echo

# ── 1. Pre-flip readiness gate ────────────────────────────────────────────────
echo "[1. Pre-flip readiness: merge_group trigger coverage]"
if [[ ! -f "${COVERAGE_SCRIPT}" ]]; then
    err "Coverage script not found at ${COVERAGE_SCRIPT} — cannot verify readiness"
    exit 1
fi

if CHUMP_MERGE_GROUP_STRICT=1 bash "${COVERAGE_SCRIPT}"; then
    ok "All required status checks fire on merge_group events"
else
    err "Coverage gate failed — a required check is missing merge_group support."
    err "Enabling merge queue now would wedge it forever. Aborting; no mutation attempted."
    emit_ambient "merge_queue_enable_blocked" "coverage_gate_failed"
    exit 1
fi

# ── 2. Determine repo + current state ─────────────────────────────────────────
echo
echo "[2. Current merge queue state]"
REPO="$(git -C "${REPO_ROOT}" remote get-url chump 2>/dev/null \
    | sed 's|.*github.com[:/]||;s|.git$||' \
    || git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null \
    | sed 's|.*github.com[:/]||;s|.git$||' \
    || echo '')"
OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

if [[ -z "${OWNER}" ]] || [[ -z "${REPO_NAME}" ]]; then
    err "Cannot determine owner/repo from git remotes"
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    err "gh CLI not available — cannot check or flip merge queue state"
    exit 1
fi

MQ_RESULT="$(gh api graphql \
    -f owner="${OWNER}" -f name="${REPO_NAME}" \
    -f query='query($owner:String!,$name:String!){
      repository(owner:$owner,name:$name){
        mergeQueue(branch:"main"){id}}}' \
    --jq '.data.repository.mergeQueue' 2>/dev/null || echo 'null')"

if [[ "${MQ_RESULT}" != "null" ]] && [[ -n "${MQ_RESULT}" ]]; then
    ok "Merge queue is already enabled on main (${OWNER}/${REPO_NAME}) — nothing to do"
    exit 0
fi
warn "Merge queue is NOT enabled on main (${OWNER}/${REPO_NAME})"

# ── 3. Dry-run vs confirm ─────────────────────────────────────────────────────
echo
echo "[3. Action]"
if [[ "${CONFIRM}" -ne 1 ]]; then
    echo "DRY-RUN (default). Readiness gate passed — merge queue is safe to enable."
    echo "No changes made. To actually flip branch protection, re-run with --confirm:"
    echo
    echo "    bash scripts/coord/enable-merge-queue.sh --confirm"
    echo
    echo "This requires operator sign-off per CLAUDE.md (branch protection is a"
    echo "shared, production setting). Manual alternative (web UI):"
    echo "  https://github.com/${OWNER}/${REPO_NAME}/settings/branches"
    echo "  Edit 'main' → enable 'Require merge queue' (Squash / All Green / max 5)."
    echo "See docs/process/MERGE_QUEUE.md for full details."
    emit_ambient "merge_queue_enable_dry_run" "readiness_ok"
    exit 0
fi

echo "CONFIRM flag set — flipping branch protection to require merge queue."
RULESET_ID="$(gh api "repos/${OWNER}/${REPO_NAME}/rulesets" --jq '.[0].id' 2>/dev/null || echo '')"
if [[ -z "${RULESET_ID}" ]]; then
    err "No repository ruleset found — this GitHub plan/config may require the web-UI path."
    err "See docs/process/MERGE_QUEUE.md 'Option A: Web UI'."
    emit_ambient "merge_queue_enable_failed" "no_ruleset"
    exit 1
fi

gh api "repos/${OWNER}/${REPO_NAME}/rulesets/${RULESET_ID}" --method PUT \
    --input - <<'JSON'
{
  "rules": [
    { "type": "merge_queue",
      "parameters": {
        "merge_method": "SQUASH",
        "grouping_strategy": "ALLGREEN",
        "max_entries_to_build": 5,
        "max_entries_to_merge": 5,
        "min_entries_to_merge": 1,
        "min_entries_to_merge_wait_minutes": 0,
        "check_response_timeout_minutes": 60
      }
    }
  ]
}
JSON

ok "Merge queue enable request sent for ${OWNER}/${REPO_NAME} (ruleset ${RULESET_ID})"
emit_ambient "merge_queue_enabled" "ruleset_${RULESET_ID}"
