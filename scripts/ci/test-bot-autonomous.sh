#!/usr/bin/env bash
# CREDIBLE-002: pre-deploy assertion — is pr-triage-bot autonomous?
#
# Creates a fixture PR with a known auto-fixable clippy lint (len_zero),
# waits for the pr-triage-bot to commit a fix, and asserts that it did so
# within BOT_AUTONOMOUS_WAIT_SECS seconds (default: 900 = 15 min).
#
# Cleans up (closes PR + deletes branch) on exit regardless of outcome.
#
# Exits 0  — bot committed an auto-fix in time.
# Exits 1  — bot did not commit, timed out, or an error occurred.
# Exits 0  — GH_TOKEN absent (non-CI environment, skip silently).
#
# Emits kind=bot_autonomous_check_passed|failed to ambient.jsonl.
#
# Usage (CI):
#   GH_TOKEN=<token> GITHUB_REPOSITORY=<owner/repo> \
#     bash scripts/ci/test-bot-autonomous.sh

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
WAIT_MAX_SECS="${BOT_AUTONOMOUS_WAIT_SECS:-900}"
POLL_INTERVAL=30
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO="${GITHUB_REPOSITORY:-}"
FIXTURE_BRANCH="test/credible-002-bot-$(date +%s)"
FIXTURE_FILE="tests/credible_002_bot_fixture.rs"
PR_NUMBER=""

# ── Helpers ──────────────────────────────────────────────────────────────────
log() { echo "[credible-002] $*" >&2; }

emit_ambient() {
    local kind="$1" outcome="$2"
    local locks_dir="${REPO_ROOT}/.chump-locks"
    mkdir -p "${locks_dir}" 2>/dev/null || true
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s","outcome":"%s","fixture_pr":%s}\n' \
        "${ts}" "${kind}" "${outcome}" "${PR_NUMBER:-null}" \
        >> "${locks_dir}/ambient.jsonl" 2>/dev/null || true
}

cleanup() {
    local exit_code=$?
    if [[ -n "${PR_NUMBER}" ]]; then
        log "Cleaning up fixture PR #${PR_NUMBER}..."
        gh pr close "${PR_NUMBER}" --delete-branch 2>/dev/null || true
    fi
    if git -C "${REPO_ROOT}" branch --list "${FIXTURE_BRANCH}" | grep -q .; then
        git -C "${REPO_ROOT}" branch -D "${FIXTURE_BRANCH}" 2>/dev/null || true
    fi
    # Delete remote fixture branch if it exists
    gh api "repos/${REPO}/git/refs/heads/${FIXTURE_BRANCH}" \
        --method DELETE 2>/dev/null || true
    exit "${exit_code}"
}

# ── Guard: skip if no GH_TOKEN ───────────────────────────────────────────────
if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
    log "No GH_TOKEN set — skipping live bot-autonomous check (non-CI environment)."
    log "Set GH_TOKEN and GITHUB_REPOSITORY to run this assertion."
    exit 0
fi

# Resolve repo from git remote if not set by env
if [[ -z "${REPO}" ]]; then
    REPO="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null \
        | sed 's|.*github.com[:/]||;s|.git$||')"
fi
if [[ -z "${REPO}" ]]; then
    log "ERROR: Could not determine GITHUB_REPOSITORY. Set it explicitly."
    exit 1
fi

log "Testing bot autonomy on repo ${REPO}."
log "Fixture branch: ${FIXTURE_BRANCH}."
log "Waiting up to ${WAIT_MAX_SECS}s for bot commit."

trap cleanup EXIT

# ── Step 1: Create fixture branch with a known clippy lint ───────────────────
log "Step 1: Creating fixture branch with clippy::len_zero lint..."

# Work from a temp clone to avoid touching the local working tree
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"; cleanup' EXIT

git clone --quiet "$(git -C "${REPO_ROOT}" remote get-url origin)" "${TEMP_DIR}/repo" \
    --depth 1 --branch main 2>&1 | tail -2 || {
    log "ERROR: Could not clone repo."
    exit 1
}

git -C "${TEMP_DIR}/repo" config user.name "chump-ci-test"
git -C "${TEMP_DIR}/repo" config user.email "chump-ci-test@users.noreply.github.com"
git -C "${TEMP_DIR}/repo" checkout -b "${FIXTURE_BRANCH}"

# Write the fixture file — clippy::len_zero is auto-fixable by cargo clippy --fix
mkdir -p "${TEMP_DIR}/repo/tests"
cat > "${TEMP_DIR}/repo/${FIXTURE_FILE}" <<'RUST'
// CREDIBLE-002 bot-autonomous test fixture — DO NOT MERGE
// This file introduces a clippy::len_zero warning so scripts/ci/test-bot-autonomous.sh
// can assert that pr-triage-bot auto-applies `cargo clippy --fix`.
// Deleted after assertion by the test script cleanup.

#[allow(dead_code)]
fn credible_002_len_zero_fixture() -> bool {
    let v: Vec<u8> = Vec::new();
    v.len() == 0 // clippy::len_zero: prefer v.is_empty()
}
RUST

git -C "${TEMP_DIR}/repo" add "${FIXTURE_FILE}"
CHUMP_GIT_IDENTITY_CHECK=0 CHUMP_GAPS_LOCK=0 \
    git -C "${TEMP_DIR}/repo" commit \
    -m "test(CREDIBLE-002): bot-autonomous fixture — clippy::len_zero

Git-Identity-Bypass: chump-ci-test fixture identity for bot-autonomous assertion
" 2>&1 | tail -3

git -C "${TEMP_DIR}/repo" push -u origin "${FIXTURE_BRANCH}" --quiet 2>&1 | tail -2 || {
    log "ERROR: Could not push fixture branch."
    exit 1
}

# ── Step 2: Open a fixture PR ─────────────────────────────────────────────────
log "Step 2: Opening fixture PR..."
PR_NUMBER="$(gh pr create \
    --repo "${REPO}" \
    --head "${FIXTURE_BRANCH}" \
    --base main \
    --title "test(CREDIBLE-002): bot-autonomous fixture — DO NOT MERGE" \
    --body "$(cat <<'EOF'
**CREDIBLE-002 bot-autonomous assertion fixture. DO NOT MERGE.**

This PR intentionally introduces a \`clippy::len_zero\` lint so that
\`scripts/ci/test-bot-autonomous.sh\` can verify that \`pr-triage-bot\`
autonomously applies \`cargo clippy --fix\` within 15 minutes.

This PR is created and closed automatically by the CI check.
Closed by: scripts/ci/test-bot-autonomous.sh
EOF
)" \
    --json number --jq .number 2>&1)" || {
    log "ERROR: Could not create fixture PR."
    exit 1
}
log "Fixture PR #${PR_NUMBER} opened."

# ── Step 3: Wait for CI to fail then bot to commit ───────────────────────────
log "Step 3: Polling for bot commit (max ${WAIT_MAX_SECS}s, every ${POLL_INTERVAL}s)..."

ELAPSED=0
BOT_COMMIT_SHA=""
while [[ ${ELAPSED} -lt ${WAIT_MAX_SECS} ]]; do
    sleep "${POLL_INTERVAL}"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))

    # Check for a bot commit: look for a commit by chump-pr-triage-bot on the PR branch
    RECENT_COMMITS="$(gh api \
        "repos/${REPO}/pulls/${PR_NUMBER}/commits" \
        --jq '[.[] | {author: .commit.author.name, message: .commit.message}]' \
        2>/dev/null || echo '[]')"

    BOT_COMMIT_SHA="$(gh api \
        "repos/${REPO}/pulls/${PR_NUMBER}/commits" \
        --jq '[.[] | select(.commit.author.name == "chump-pr-triage-bot")] | .[0].sha // empty' \
        2>/dev/null || echo '')"

    if [[ -n "${BOT_COMMIT_SHA}" ]]; then
        log "Bot commit detected: ${BOT_COMMIT_SHA} (after ${ELAPSED}s)"
        break
    fi

    log "  ${ELAPSED}s elapsed — no bot commit yet. Commits so far:"
    echo "${RECENT_COMMITS}" | python3 -c \
        "import sys,json; [print('   ', c['author'], ':', c['message'][:60]) for c in json.load(sys.stdin)]" \
        2>/dev/null || true
done

# ── Step 4: Assert ────────────────────────────────────────────────────────────
if [[ -n "${BOT_COMMIT_SHA}" ]]; then
    log "PASS: pr-triage-bot committed an auto-fix within ${ELAPSED}s."
    log "  Commit: ${BOT_COMMIT_SHA}"
    emit_ambient "bot_autonomous_check_passed" "pass"

    # Verify the fix resolved the lint (message should mention auto-fix)
    COMMIT_MSG="$(gh api \
        "repos/${REPO}/git/commits/${BOT_COMMIT_SHA}" \
        --jq .message 2>/dev/null || echo '')"
    if echo "${COMMIT_MSG}" | grep -qi "auto-fix\|clippy\|fmt"; then
        log "  Commit message confirms lint fix: '${COMMIT_MSG:0:80}'"
    else
        log "  WARN: Bot commit found but message doesn't mention auto-fix. Inspect manually."
        log "  Message: '${COMMIT_MSG:0:120}'"
    fi

    exit 0
else
    log "FAIL: pr-triage-bot did NOT commit within ${WAIT_MAX_SECS}s."
    log "  Check:"
    log "    1. GitHub Actions workflow 'pr-triage-bot' fired on the fixture PR's CI failure"
    log "    2. The auto-fix-lint job classified the failure as lint-only"
    log "    3. cargo clippy --fix and git push ran successfully"
    log "  Fixture PR: https://github.com/${REPO}/pull/${PR_NUMBER}"
    emit_ambient "bot_autonomous_check_failed" "timeout"
    exit 1
fi
