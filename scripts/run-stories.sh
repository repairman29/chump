#!/usr/bin/env bash
# Run all 20 user stories one by one against Chump CLI. See docs/USER_STORIES.md.
# Requires: local model (./run-local.sh env or ./run-best.sh env). Run from rust-agent/.
# With a small model (e.g. llama3.2:1b) many stories will execute tools but the final reply may be raw JSON; use a larger model (e.g. qwen2.5:7b or vLLM-MLX 30B) for natural-language summaries.

set -e
cd "$(dirname "$0")/.."

run_one() {
    local n="$1"
    local prompt="$2"
    echo "=============================================="
    echo "Story $n: $prompt"
    echo "=============================================="
    ./run-local.sh --chump "$prompt" 2>&1 || true
    echo ""
}

echo "Chump: running all 20 user stories one by one (Ollama)."
echo ""

# 1–5 Setup and organization (explicit run_cli/memory so small model follows)
run_one 1 "Use run_cli to run: cargo new _story1_tool --bin. Then reply in one sentence what happened."
run_one 2 "Use run_cli to run: ls -la. Then reply in one sentence what you see in this folder."
run_one 3 "Use memory with action=store and content=Preferred repo layout: docs/, src/, tests/ at top. Then reply: Stored."
run_one 4 "Use run_cli to run: pwd. Reply with where we are; then suggest: script could live in scripts/ and be named sync-env.sh."
run_one 5 "Use run_cli to run: ls -la. Then use run_cli to run: cat README.md 2>/dev/null || true. Reply in 2 sentences what is in this repo."

# 6–10 Planning and breaking down work
run_one 6 "Reply in 2 sentences: To add a health check, (1) add a handler in src or a new module, (2) run tests. No tools needed; just answer."
run_one 7 "Reply with this ordered list only: 1. fix login bug 2. add tests 3. refactor DB layer 4. deploy. No tools needed."
run_one 8 "Reply in one sentence: Suggest 2-3 PRs by splitting the feature into API, then logic, then tests."
run_one 9 "Use run_cli to run: git status 2>/dev/null || true. Reply in one sentence the smallest next step to ship."
run_one 10 "Use memory with action=recall. Then reply in one sentence what you recalled, or say no memories yet."

# 11–15 Git and repo ops
run_one 11 "Use run_cli to run: git status. Then use run_cli to run: git diff --stat 2>/dev/null || true. Summarize in one sentence."
run_one 12 "Use run_cli to run: git checkout -b feature/health-check 2>/dev/null || true. Reply what happened."
run_one 13 "Use run_cli to run: git stash. Then run_cli: git checkout main. Then run_cli: git pull. Reply in one sentence."
run_one 14 "Use run_cli to run: git branch --merged. Reply with the list or one sentence."
run_one 15 "Use run_cli to run: git diff --cached. Reply with a suggested one-line commit message."

# 16–20 Running and verifying
run_one 16 "Use run_cli to run: cargo test 2>&1. Reply in one sentence: pass or fail and how many."
run_one 17 "Use run_cli to run: cargo build 2>&1. Then run_cli: target/debug/rust-agent --help 2>&1. Reply with first 3 lines of --help."
run_one 18 "Use run_cli to run: cargo tree 2>/dev/null | head -20. Reply in one sentence what deps we have."
run_one 19 "Use run_cli to run: cargo fmt. Reply in one sentence: done."
run_one 20 "Use run_cli to run: cargo build 2>&1. Then run_cli: cargo test 2>&1. Reply in one sentence: build and test pass or fail."

echo "Done. All 20 stories run. See docs/USER_STORIES.md."
