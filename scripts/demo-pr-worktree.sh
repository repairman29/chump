#!/usr/bin/env bash
# Demo: "Issue → isolated worktree → PR" sponsor path.
# Shows Chump creating a change in a git worktree without touching the main branch.
#
# Usage:
#   ./scripts/demo-pr-worktree.sh                  # interactive (prompts before each step)
#   DEMO_AUTO=1 ./scripts/demo-pr-worktree.sh      # non-interactive (runs all steps)
#
# Prerequisites:
#   - Chump web running (./run-web.sh)
#   - Model server reachable
#   - git repo with a clean working tree
#
# What it does:
#   1. Creates a git worktree in a temp branch
#   2. Sends a chat message to Chump asking it to make a small change
#   3. Shows the diff
#   4. Optionally creates a PR via gh
#   5. Cleans up the worktree

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOST="${CHUMP_WEB_HOST:-127.0.0.1}"
PORT="${CHUMP_WEB_PORT:-3000}"
TOKEN="${CHUMP_WEB_TOKEN:-}"
BASE="http://${HOST}:${PORT}"

DEMO_AUTO="${DEMO_AUTO:-0}"

step() {
  echo ""
  echo "=== $1 ==="
  if [[ "$DEMO_AUTO" != "1" ]]; then
    read -rp "Press Enter to continue (or Ctrl-C to abort)..."
  fi
}

auth_header() {
  if [[ -n "$TOKEN" ]]; then
    echo "Authorization: Bearer $TOKEN"
  else
    echo "X-No-Auth: 1"
  fi
}

# --- Step 1: Check prerequisites ---
step "Step 1/5: Check prerequisites"

health=$(curl -s --max-time 5 "${BASE}/api/health" 2>/dev/null || echo "")
if [[ "$health" != *"chump-web"* ]]; then
  echo "ERROR: Chump web not responding at ${BASE}. Start it: ./run-web.sh"
  exit 1
fi
echo "Chump web: OK (${BASE})"

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "ERROR: Not inside a git repo."
  exit 1
fi
echo "Git repo: OK ($(git rev-parse --show-toplevel))"

# --- Step 2: Create worktree ---
step "Step 2/5: Create isolated git worktree"

BRANCH="demo/pr-$(date +%s)"
WORKTREE="$ROOT/.worktrees/$BRANCH"
git worktree add "$WORKTREE" -b "$BRANCH" HEAD
echo "Worktree created: $WORKTREE"
echo "Branch: $BRANCH"

cleanup() {
  echo ""
  echo "Cleaning up worktree..."
  git worktree remove "$WORKTREE" --force 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true
  echo "Done."
}
trap cleanup EXIT

# --- Step 3: Ask Chump to make a change ---
step "Step 3/5: Ask Chump to make a change in the worktree"

PROMPT="Add a comment at the top of scripts/demo-pr-worktree.sh that says '# Demo run at $(date -u +%Y-%m-%dT%H:%M:%SZ)'. Only add the one comment line, nothing else. Use the file at ${WORKTREE}/scripts/demo-pr-worktree.sh."

echo "Sending to Chump: $PROMPT"
echo ""

# Create a session and send the message
SESSION_RESP=$(curl -s -X POST "${BASE}/api/sessions" \
  -H "$(auth_header)" \
  -H "Content-Type: application/json" \
  -d '{}')
SESSION_ID=$(echo "$SESSION_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")

if [[ -z "$SESSION_ID" ]]; then
  echo "WARN: Could not create session. Sending without session_id."
fi

# Send chat (SSE) and collect response
CHAT_BODY=$(python3 -c "
import json
d = {'message': '''$PROMPT'''}
if '$SESSION_ID':
    d['session_id'] = '$SESSION_ID'
print(json.dumps(d))
")

echo "Waiting for Chump response (this may take 15-60s depending on model)..."
RESPONSE=$(curl -s -N --max-time 120 \
  -H "$(auth_header)" \
  -H "Content-Type: application/json" \
  -d "$CHAT_BODY" \
  "${BASE}/api/chat" 2>/dev/null | grep "^data:" | tail -5)

echo "Response received."

# --- Step 4: Show diff ---
step "Step 4/5: Show changes"

cd "$WORKTREE"
if git diff --quiet && git diff --cached --quiet; then
  echo "(No file changes detected — Chump may have used a different approach or the model was too slow.)"
  echo "Worktree contents:"
  ls -la "$WORKTREE/scripts/demo-pr-worktree.sh" 2>/dev/null || true
else
  echo "--- Changes in worktree ---"
  git diff
  git diff --cached
fi
cd "$ROOT"

# --- Step 5: Optionally create PR ---
step "Step 5/5: Create PR (optional)"

if [[ "$DEMO_AUTO" == "1" ]]; then
  echo "Skipping PR creation in auto mode."
else
  if command -v gh &>/dev/null; then
    read -rp "Create a PR from this branch? (y/N) " CREATE_PR
    if [[ "$CREATE_PR" == "y" || "$CREATE_PR" == "Y" ]]; then
      cd "$WORKTREE"
      git add -A
      git commit -m "demo: automated change via Chump worktree flow"
      git push -u origin "$BRANCH"
      gh pr create --title "Demo: Chump worktree PR" --body "Automated demo of the Chump issue-to-PR workflow."
      cd "$ROOT"
    fi
  else
    echo "gh CLI not installed — skipping PR creation. Install: brew install gh"
  fi
fi

echo ""
echo "Demo complete. Worktree will be cleaned up on exit."
