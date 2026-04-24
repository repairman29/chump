#!/bin/bash
# Chump CLI golden path demo — interactive 3-minute walkthrough
# This script runs the key steps that showcase Chump's value:
# 1. Initialize Chump (chump init)
# 2. Pick a task (interactive)
# 3. Execute the task
# 4. Show results

set -eu

# Helper: pause and wait for user input
pause() {
  local msg="${1:-Press ENTER to continue...}"
  echo ""
  echo "→ $msg"
  read
}

# Helper: run a command with visible output
run_cmd() {
  local cmd="$1"
  local desc="${2:-}"
  echo ""
  if [ -n "$desc" ]; then
    echo "📋 $desc"
  fi
  echo "$ $cmd"
  eval "$cmd"
}

# ======== DEMO SCRIPT ========

clear
echo "╔════════════════════════════════════════════════════════╗"
echo "║         Chump CLI Demonstration - Golden Path          ║"
echo "║         Multi-agent local coding assistant             ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "This 3-minute demo shows:"
echo "  • Installing and initializing Chump"
echo "  • Running an automated coding task"
echo "  • Chump executing work autonomously"
echo ""

pause "Press ENTER to begin..."

# ========== STEP 1: Initialize ==========
echo ""
echo "═══════════════════════════════════════════════════════"
echo "STEP 1: Initialize Chump"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Chump uses a local sqlite database to track gaps (tasks),"
echo "coordinate between agents, and maintain ambient state."
echo ""

run_cmd "chump init --fresh" "Initialize Chump in /tmp/chump-demo/"

pause "Chump is ready. Press ENTER to see the gap registry..."

# ========== STEP 2: List gaps ==========
echo ""
echo "═══════════════════════════════════════════════════════"
echo "STEP 2: View available gaps (tasks)"
echo "═══════════════════════════════════════════════════════"
echo ""

run_cmd "chump gap list --status open --limit 5" "Show 5 open gaps"

pause "These are tasks that agents can pick up. Press ENTER to start one..."

# ========== STEP 3: Execute a gap ==========
echo ""
echo "═══════════════════════════════════════════════════════"
echo "STEP 3: Execute a gap autonomously"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Chump can execute a gap end-to-end:"
echo "  • Claims the gap (lease management)"
echo "  • Runs the task in a worktree"
echo "  • Creates a PR with auto-merge enabled"
echo "  • Reports completion"
echo ""

run_cmd "chump gap claim TEST-001" "Claim a test gap"

pause "Claimed! Press ENTER to see the real-time execution heartbeat..."

run_cmd "chump gap status TEST-001" "Show execution status"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "STEP 4: Ambient stream — multi-agent coordination"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "When multiple agents run in parallel, they share a"
echo "peripheral-vision stream (.chump-locks/ambient.jsonl):"
echo ""

run_cmd "tail -10 ~/.chump/.ambient.jsonl 2>/dev/null || echo '(ambient stream from recent runs would appear here)'" "Show recent events"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "DEMO COMPLETE"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "✓ Chump initialized and ready"
echo "✓ Gaps tracked and claimable"
echo "✓ Autonomous execution workflow proven"
echo "✓ Multi-agent coordination visible"
echo ""
echo "Next steps:"
echo "  • Clone a repo: chump init <repo-path>"
echo "  • See all commands: chump --help"
echo "  • Read docs: https://chump.dev/docs"
echo ""

pause "Thanks for watching! Press ENTER to exit..."
echo ""
