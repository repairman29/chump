# Chump Daily Driver — 95-Step Test Plan (3 Weeks)

## Week 1 — Run It

### Day 1: Build & Boot

```bash
# 1. Build the release binary
cargo build --release --bin chump

# 2. Verify binary exists
ls -la target/release/chump

# 3. Ensure Ollama is running
brew services start ollama

# 4. Pull your model
ollama pull qwen2.5:14b

# 5. Confirm Ollama responds
curl -s http://localhost:11434/v1/models | head -20

# 6. Set minimal .env
#    OPENAI_API_BASE=http://localhost:11434/v1
#    OPENAI_API_KEY=ollama
#    OPENAI_MODEL=qwen2.5:14b
#    (or use CHUMP_GOLDEN_PATH_OLLAMA=1 to override a heavier .env)

# 7. Validate config
CHUMP_USE_RELEASE=1 CHUMP_GOLDEN_PATH_OLLAMA=1 ./run-local.sh -- --check-config

# 8. Send a single test message
CHUMP_USE_RELEASE=1 CHUMP_GOLDEN_PATH_OLLAMA=1 ./run-local.sh -- --chump "What tools do you have available?"
# PASS: You get a response listing tools. No crashes.
```

### Day 2: Web PWA

```bash
# 9. Start web server
CHUMP_USE_RELEASE=1 CHUMP_GOLDEN_PATH_OLLAMA=1 ./run-web.sh

# 10. Health check
curl -s http://127.0.0.1:3000/api/health
# PASS: {"status":"ok","service":"chump-web"}

# 11. Open browser
open http://127.0.0.1:3000

# 12. Send a message through the chat UI
#     Type: "Hello, what can you do?"
# PASS: Streaming response appears in browser

# 13. Create a second session (click new session in sidebar)
# PASS: Clean conversation starts

# 14. Switch back to first session
# PASS: Previous conversation is still there

# 15. Check sessions API
curl -s http://127.0.0.1:3000/api/sessions | python3 -m json.tool
# PASS: Both sessions listed with IDs
```

### Day 3: ChumpMenu + Tool Policy

```bash
# 16. Build menu bar app
./scripts/build-chump-menu.sh

# 17. Launch it
open ChumpMenu/ChumpMenu.app
# PASS: Menu bar icon appears. Green dots for running services.

# 18. Set tool policy in .env
#     CHUMP_TOOLS_ASK=run_cli,write_file,patch_file,git_commit,git_push
#     CHUMP_CLI_ALLOWLIST=cargo,git,rg,ls,cat,head,wc

# 19. Restart web server (ctrl-C, then ./run-web.sh)

# 20. In PWA, ask: "List the files in the current directory"
# PASS: Chump calls list_dir — no approval needed (read-only)

# 21. Ask: "Run cargo test"
# PASS: Approval prompt appears in the web UI. Click Allow. Tests run.

# 22. Ask: "Create a file called /tmp/chump-test.txt with 'hello world'"
# PASS: Approval prompt for write_file. Click Allow. File created.

# 23. Verify
cat /tmp/chump-test.txt
# PASS: "hello world"

# 24. Ask: "Run rm -rf /"
# PASS: Either blocked by CLI allowlist, or approval prompt appears and you click Deny.
```

### Day 4: Memory & Brain

```bash
# 25. Build with in-process embeddings
cargo build --release --bin chump --features inprocess-embed

# 26. Restart web server

# 27. In PWA, ask: "Remember that my main project uses Axum for the web framework and SQLite for storage"
# PASS: Chump calls memory_brain to store this

# 28. Verify memory persisted
sqlite3 sessions/chump_memory.db "SELECT content, ts FROM chump_memory ORDER BY id DESC LIMIT 3;"
# PASS: Your memory entry appears

# 29. Start a NEW session in PWA

# 30. Ask: "What web framework does my main project use?"
# PASS: Chump recalls "Axum" from memory

# 31. Seed the brain wiki
mkdir -p chump-brain
cat << 'EOF' > chump-brain/self.md
# My Setup
- MacBook Pro M-series
- Primary language: Rust
- Editor: Cursor
- Deploy: Vercel
EOF

# 32. Set in .env:
#     CHUMP_BRAIN_PATH=chump-brain
#     CHUMP_BRAIN_AUTOLOAD=self.md

# 33. Restart web server

# 34. New session. Ask: "What editor do I use?"
# PASS: Chump knows "Cursor" from brain autoload
```

### Day 5: Point at a Real Repo

```bash
# 35. Set in .env:
#     CHUMP_REPO=/path/to/your/actual/project
#     GITHUB_TOKEN=ghp_your_token_here
#     CHUMP_GITHUB_REPOS=yourname/yourrepo

# 36. Restart web server

# 37. Ask: "Read the README.md file"
# PASS: Chump reads from your real repo, not the Chump repo

# 38. Ask: "List the src directory"
# PASS: Shows your project's src/ contents

# 39. Ask: "What does this project do? Read the main entry point."
# PASS: Chump reads the right file and gives an accurate summary

# 40. Ask: "Run the tests"
# PASS: Approval prompt → Allow → cargo test runs on YOUR project

# 41. Ask Chump to make a small real change (fix a typo, add a comment)
# PASS: Approval for write_file/patch_file → change applied correctly

# 42. Ask: "Show me the git diff"
# PASS: Chump runs git diff and shows your change

# 43. Ask: "Commit this with message 'fix: typo in readme'"
# PASS: Approval for git_commit → commit created

# 44. Verify
cd /path/to/your/actual/project && git log --oneline -3
# PASS: Your commit is there
```

---

## Week 2 — Trust It

### Day 6: Verify Recall Quality

```bash
# 45. Store 5 distinct memories through conversation:
#     - "My API uses bearer token auth"
#     - "The deploy command is vercel --prod"
#     - "Database migrations are in db/migrations/"
#     - "The CI pipeline runs on GitHub Actions"
#     - "Feature branches merge to develop, not main"

# 46. Kill the web server. Restart it. New session.

# 47. Ask: "How do I deploy?"
# PASS: Gets "vercel --prod"

# 48. Ask: "Where are the migrations?"
# PASS: Gets "db/migrations/"

# 49. Ask: "What branch do feature branches merge to?"
# PASS: Gets "develop, not main"

# 50. If any of these fail, check:
sqlite3 sessions/chump_memory.db "SELECT count(*) FROM chump_memory;"
#     If count is 0, memory_brain isn't persisting. Debug.
#     If count > 0 but recall fails, embedding quality issue. Check RUST_LOG=debug.
```

### Day 7: Task System

```bash
# 51. Create tasks via API
curl -X POST http://127.0.0.1:3000/api/tasks \
  -H "Content-Type: application/json" \
  -d '{"title":"Summarize recent git log","assignee":"chump","priority":1}'

# 52. Create more tasks
curl -X POST http://127.0.0.1:3000/api/tasks \
  -H "Content-Type: application/json" \
  -d '{"title":"Check if all tests pass","assignee":"chump","priority":2}'

curl -X POST http://127.0.0.1:3000/api/tasks \
  -H "Content-Type: application/json" \
  -d '{"title":"List any TODO comments in src/","assignee":"chump","priority":3}'

# 53. Verify tasks exist
curl -s http://127.0.0.1:3000/api/tasks?status=pending | python3 -m json.tool
# PASS: 3 tasks listed

# 54. In PWA, ask: "What tasks are assigned to you?"
# PASS: Chump lists the 3 tasks via task tool
```

### Day 8: Autonomy (Manual)

```bash
# 55. Run autonomy-once (picks highest priority task)
CHUMP_USE_RELEASE=1 CHUMP_GOLDEN_PATH_OLLAMA=1 ./run-local.sh -- --autonomy-once
# PASS: Chump picks "Summarize recent git log", executes, marks complete

# 56. Check task status
curl -s http://127.0.0.1:3000/api/tasks | python3 -m json.tool
# PASS: First task is "done". Others still "pending".

# 57. Run again
CHUMP_USE_RELEASE=1 CHUMP_GOLDEN_PATH_OLLAMA=1 ./run-local.sh -- --autonomy-once
# PASS: Picks next task, executes

# 58. Run again
CHUMP_USE_RELEASE=1 CHUMP_GOLDEN_PATH_OLLAMA=1 ./run-local.sh -- --autonomy-once
# PASS: Third task done

# 59. Run one more time with no tasks
CHUMP_USE_RELEASE=1 CHUMP_GOLDEN_PATH_OLLAMA=1 ./run-local.sh -- --autonomy-once
# PASS: Exits cleanly with "no pending tasks" or similar
```

### Day 9: Heartbeat

```bash
# 60. Get a Tavily key from tavily.com (free tier)
#     Add to .env: TAVILY_API_KEY=tvly-xxxxx

# 61. Quick test of heartbeat
HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-self-improve.sh
# PASS: Runs for ~2 min, completes 1-2 rounds, exits. Check logs:
cat logs/heartbeat-self-improve.log | tail -20

# 62. Create a task for the heartbeat to work on
curl -X POST http://127.0.0.1:3000/api/tasks \
  -H "Content-Type: application/json" \
  -d '{"title":"Research best practices for Rust error handling and store in memory","assignee":"chump","priority":1}'

# 63. Run heartbeat with dry run (no git push)
HEARTBEAT_DRY_RUN=1 HEARTBEAT_DURATION=10m HEARTBEAT_INTERVAL=2m \
  ./scripts/heartbeat-self-improve.sh

# 64. While it runs, watch logs in another terminal
tail -f logs/heartbeat-self-improve.log
# PASS: See rounds executing, task picked up, web search used

# 65. After it finishes, check memory for new entries
sqlite3 sessions/chump_memory.db "SELECT content FROM chump_memory ORDER BY id DESC LIMIT 5;"
# PASS: New research-related entries stored

# 66. Test kill switch
touch logs/pause
HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-self-improve.sh
# PASS: Exits immediately or skips rounds
rm logs/pause
```

### Day 10: Overnight Run

```bash
# 67. Create 3-5 real tasks you actually want done overnight
#     Examples:
#     - "Review all TODO comments in src/ and create a summary"
#     - "Check test coverage and note any untested modules"
#     - "Research [topic relevant to your project] and store findings"

# 68. Start the heartbeat before bed
HEARTBEAT_DRY_RUN=1 HEARTBEAT_DURATION=4h HEARTBEAT_INTERVAL=15m \
  nohup ./scripts/heartbeat-self-improve.sh > /dev/null 2>&1 &
echo $! > logs/heartbeat.pid

# 69. Next morning, check results
cat logs/heartbeat-self-improve.log | grep -i "round\|complete\|error"
curl -s http://127.0.0.1:3000/api/tasks | python3 -m json.tool
sqlite3 sessions/chump_memory.db "SELECT content FROM chump_memory ORDER BY id DESC LIMIT 10;"
# PASS: Tasks completed. No crashes. Memory has useful entries.
# FAIL: Check logs for errors. Common issues:
#   - Ollama fell asleep → add OLLAMA_KEEP_ALIVE=24h
#   - Task timed out → check CHUMP_TASK_LEASE_TTL_SECS
#   - Web search failed → check TAVILY_API_KEY
```

---

## Week 3 — Harden It

### Day 11: diff_review Gate

```bash
# 70. In PWA, ask Chump to make a code change and commit it
#     "Add a comment to the top of src/main.rs and commit it"

# 71. Watch the flow:
#     - write_file/patch_file → approval → allowed
#     - diff_review should run automatically before commit
#     - git_commit → approval → allowed
# PASS: diff_review output shown before commit happens

# 72. If diff_review is NOT triggering automatically, verify:
#     Check that diff_review_tool.rs is wired into the commit flow
#     This may need code work — note it as a hardening task

# 73. Test with an intentionally bad change
#     "Write a function that uses unwrap() on a None value and commit it"
# PASS: diff_review flags the unwrap as high-severity
```

### Day 12: Battle QA

```bash
# 74. Run battle QA against your actual usage
./run-local.sh -- --chump "Run battle_qa with 10 rounds"
# Or via the tool directly if battle_qa is registered

# 75. If battle_qa tool isn't suitable, manually test edge cases:

# 76. Test: empty message
curl -X POST http://127.0.0.1:3000/api/chat \
  -H "Content-Type: application/json" -d '{"message":"","session_id":"test1"}'
# PASS: Graceful error or empty response, no crash

# 77. Test: very long message (paste 10K chars)
python3 -c "print('x' * 10000)" | xargs -I{} curl -X POST http://127.0.0.1:3000/api/chat \
  -H "Content-Type: application/json" -d '{"message":"{}","session_id":"test2"}'
# PASS: Handled gracefully (trimmed or rejected)

# 78. Test: rapid fire (5 messages in 2 seconds)
for i in {1..5}; do
  curl -s -X POST http://127.0.0.1:3000/api/chat \
    -H "Content-Type: application/json" \
    -d "{\"message\":\"count to $i\",\"session_id\":\"stress\"}" &
done
wait
# PASS: All complete without deadlock or crash

# 79. Test: tool that doesn't exist
#     In PWA: "Use the foo_bar_tool to do something"
# PASS: Chump says it doesn't have that tool, doesn't crash

# 80. Test: file outside repo
#     "Read the file /etc/passwd"
# PASS: Blocked by path guard or returns error gracefully
```

### Day 13: Stability Soak

```bash
# 81. Start web server in the morning. Use it ALL DAY for real work.

# 82. Track issues in a simple log:
echo "$(date) - started soak test" >> /tmp/chump-soak.log

# 83. Every few hours, check:
curl -s http://127.0.0.1:3000/api/health
# PASS: Still responds

# 84. Check memory isn't growing unbounded
sqlite3 sessions/chump_memory.db "SELECT count(*) FROM chump_memory;"
# Note the count. Is it reasonable?

# 85. Check disk usage
du -sh sessions/
# PASS: Not growing out of control (< 100MB for normal use)

# 86. Check the process isn't leaking memory
ps aux | grep chump | grep -v grep
# Note RSS. Should be stable (< 500MB for normal use)

# 87. At end of day, note everything that broke or annoyed you
#     These become your hardening backlog
```

### Day 14: Lock Down Your Config

```bash
# 88. Promote safe tools off the ASK list
#     In .env, update:
#     CHUMP_AUTO_APPROVE_TOOLS=read_file,list_dir,calculator,memory_brain,task,episode
#     Keep on ASK: run_cli,write_file,patch_file,git_commit,git_push

# 89. Restart and verify auto-approve works
#     "Read README.md" → no approval prompt
#     "Write a file" → still prompts
# PASS: Clean separation

# 90. Set up daily heartbeat via launchd (just the self-improve one)
cat << 'PLIST' > ~/Library/LaunchAgents/ai.chump.daily-improve.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ai.chump.daily-improve</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>cd $HOME/Projects/Chump &amp;&amp; HEARTBEAT_DRY_RUN=1 HEARTBEAT_DURATION=2h HEARTBEAT_INTERVAL=15m ./scripts/heartbeat-self-improve.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>2</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/chump-heartbeat-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/chump-heartbeat-stderr.log</string>
</dict>
</plist>
PLIST

# 91. Load it
launchctl load ~/Library/LaunchAgents/ai.chump.daily-improve.plist

# 92. Verify it's registered
launchctl list | grep chump
# PASS: Shows ai.chump.daily-improve
```

### Day 15: Document & Baseline

```bash
# 93. Snapshot your working .env (minus secrets)
grep -v "TOKEN\|KEY\|SECRET" .env > docs/my-daily-driver-env.md

# 94. Record your baseline metrics
echo "=== DAILY DRIVER BASELINE $(date) ===" >> docs/baseline.md
echo "Memory entries: $(sqlite3 sessions/chump_memory.db 'SELECT count(*) FROM chump_memory;')" >> docs/baseline.md
echo "Episodes: $(sqlite3 sessions/chump_memory.db 'SELECT count(*) FROM episodes;' 2>/dev/null || echo 'N/A')" >> docs/baseline.md
echo "Tasks completed: $(curl -s http://127.0.0.1:3000/api/tasks?status=done 2>/dev/null | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 'N/A')" >> docs/baseline.md
echo "DB size: $(du -sh sessions/)" >> docs/baseline.md
echo "Binary size: $(du -sh target/release/chump 2>/dev/null)" >> docs/baseline.md

# 95. Final validation — everything works together
curl -s http://127.0.0.1:3000/api/health           # web up
launchctl list | grep chump                          # heartbeat scheduled
sqlite3 sessions/chump_memory.db "SELECT count(*) FROM chump_memory;"  # memory populated
cat logs/heartbeat-self-improve.log | tail -5        # heartbeat ran successfully
# PASS: All four checks green. You're a daily driver.
```
