# Closing the Gaps — Master Plan

Everything Chump needs to go from "capable agent with tools" to "reliable autonomous developer you trust overnight." Prioritized by impact, grouped by theme. Each item has: what's wrong, what to build, how much effort, and dependencies.

---

## Theme 1: Reliable Continuity (Chump always knows who he is)

### Gap 1.1: `assemble_context()` — Automatic session bootstrap

**Problem:** The soul says "you can load your state at session start" but Chump has to choose to do it. On a 14B model with limited context, he may skip ego/brain reads to save tokens. Result: rounds start cold, Chump doesn't know his current focus, open tasks, or recent episodes.

**Solution:** A Rust function `assemble_context()` that runs *before* the model sees any message. It reads state, tasks, episodes, and wiki, then injects a structured context block (~2000–2500 tokens) into the system prompt — not as tool calls, but as pre-loaded text.

**What it loads:**

```
[CHUMP CONTEXT — auto-loaded, do not repeat these tool calls]
Current focus: {ego.current_focus}
Mood: {ego.mood}
Frustrations: {ego.frustrations}
Recent wins: {ego.recent_wins}
Things Jeff should know: {ego.things_jeff_should_know}
Session #{ego.session_count}

Open tasks (top 5):
  #{id}: {title} [{status}] — {notes snippet}

Recent episodes (last 3):
  - {summary} [{sentiment}] {timestamp}

Scheduled (due soon):
  - {prompt} (due: {fire_at})

Outstanding PRs: (from gh_list_my_prs if available)
  - #{pr}: {title} [{status}]
```

**Implementation:** New module `src/context_assembly.rs` (~200 lines). Reads from `state_db`, `task_db`, `episode_db`, `schedule_db`. Called in `build_agent()` in `discord.rs` and in the CLI `--chump` path. Appended to system prompt after the soul + routing table.

**Effort:** Medium (1 day). All the DBs and read functions exist. This is plumbing.

**Dependencies:** None — all data sources exist.

---

### Gap 1.2: `close_session()` — Automatic session wrap-up

**Problem:** When a heartbeat round ends (or a Discord session goes idle), nothing happens. Chump's ego state isn't updated, session count isn't incremented, brain isn't committed. If the process dies, in-progress state is lost.

**Solution:** A Rust function `close_session()` called:
- After each heartbeat round (in the `--chump` path, after `agent.run()` returns)
- On Discord idle timeout (if we add one) or on SIGTERM

**What it does:**

```rust
fn close_session() {
    // 1. Increment session_count in ego
    state_db::increment("session_count");

    // 2. Auto-commit brain repo if CHUMP_BRAIN_PATH is a git repo
    if let Ok(brain) = brain_root() {
        if brain.join(".git").exists() {
            let _ = Command::new("git")
                .args(["add", "-A"])
                .current_dir(&brain)
                .output();
            let _ = Command::new("git")
                .args(["commit", "-m", &format!("chump: auto-commit session {}", session_count)])
                .current_dir(&brain)
                .output();
        }
    }

    // 3. Log session end
    chump_log::log_session_end();
}
```

**Effort:** Low (half day). Straightforward.

**Dependencies:** None.

---

### Gap 1.3: Context window management — Summarize and trim

**Problem:** Long Discord threads silently overflow the context window. Old messages are dropped by the provider without Chump knowing. He loses track of what was said.

**Solution:** In the session manager (or a wrapper), before sending messages to the model:

1. Count tokens in the message history (approximate: chars / 4).
2. If over threshold (e.g. 80% of model's context minus system prompt), summarize older turns using `delegate(summarize)` and replace them with a summary block.
3. Keep the last N turns verbatim + the summary of everything before.

**Implementation:**

```
[Earlier in this conversation (summarized):
  We discussed X, decided Y, and you ran Z. Key facts: ...]

[Recent messages (verbatim):]
  user: ...
  assistant: ...
```

**Effort:** Medium (1 day). Need token counting and summary insertion in the session path.

**Dependencies:** Delegate tool (exists). Token counting (approximate is fine).

---

### Gap 1.4: Heartbeat round handoff — Schedule integration

**Problem:** `schedule_db::schedule_due()` exists but nothing checks it. The heartbeat scripts run their own prompts without checking if Chump set any alarms. Rounds don't know about each other.

**Solution:** Add to both heartbeat scripts, before the round prompt:

```bash
# Check for due scheduled items first
DUE_PROMPT=$("$ROOT/target/release/rust-agent" --chump-due 2>/dev/null || true)
if [[ -n "$DUE_PROMPT" ]]; then
  echo "[...] Round $round: running due scheduled item" >> "$LOG"
  prompt="$DUE_PROMPT"
fi
```

This requires a new CLI flag `--chump-due` that:
1. Calls `schedule_db::schedule_due()`
2. If there's a due item, prints its prompt and marks it fired
3. If not, exits with empty output

Then the heartbeat uses that prompt instead of the round's default.

**Also:** Pass round metadata to Chump via env so he knows where he is:

```bash
export CHUMP_HEARTBEAT_ROUND="$round"
export CHUMP_HEARTBEAT_TYPE="$round_type"
export CHUMP_HEARTBEAT_ELAPSED="$elapsed"
export CHUMP_HEARTBEAT_DURATION="$DURATION_SEC"
```

And in `assemble_context()`, inject: "This is heartbeat round {N} ({type}), {elapsed} into a {duration} run."

**Effort:** Medium (1 day). New CLI flag + script changes + context injection.

**Dependencies:** `schedule_db` (exists), heartbeat scripts.

---

## Theme 2: Intelligence (Chump makes better decisions)

### Gap 2.1: Cost accounting — Know what things cost

**Problem:** Chump has no concept of resource costs. He can burn Tavily credits, waste 14B model time on tasks a 7B could handle, or run expensive searches when a simple `rg` would do.

**Solution:** A `cost_tracker` module (Rust) that tracks per-session:

```rust
struct SessionCost {
    tavily_calls: u32,          // Tavily API calls (basic=1 credit, advanced=2)
    tavily_credits_used: u32,
    model_calls: u32,           // Main model completions
    worker_calls: u32,          // Delegate worker calls
    tool_calls: u32,            // Total tool invocations
    cli_time_secs: f64,         // Total time in run_cli
    round_start: Instant,
}
```

Logged at session end. Injected into `assemble_context()` as:

```
Budget this round: Tavily credits remaining ~{N}. Model calls so far: {N}.
Be efficient: use run_cli and native tools before web_search. Delegate to worker for summarize/extract.
```

**How Tavily credits are tracked:** Count calls in `tavily_tool.rs`, store in a thread-local or static counter. Persist to a simple file (`logs/tavily_usage.json`) with daily totals. The monthly limit (e.g. 1000) is set via `CHUMP_TAVILY_MONTHLY_LIMIT`.

**Effort:** Medium (1 day). Counters + persistence + context injection.

**Dependencies:** None.

---

### Gap 2.2: Tool health awareness — Know when tools break

**Problem:** If the model server goes down mid-session, Chump keeps trying and failing. If `rg` isn't installed, he might try it every round. No learning from tool failures.

**Solution:** Two parts:

**Part A — Runtime tool health:** After a tool call fails, record the failure in a session-level map. After 2 consecutive failures for the same tool, inject a note: "Tool {X} is failing this session. Use alternatives." This is in-memory only (resets each session).

**Part B — Cross-session learning:** When a tool fails for a *structural* reason (not installed, permission denied, not configured), store it in a `tool_health` table:

```sql
CREATE TABLE chump_tool_health (
    tool TEXT PRIMARY KEY,
    status TEXT DEFAULT 'ok',  -- ok, degraded, unavailable
    last_error TEXT,
    last_checked TEXT,
    failure_count INTEGER DEFAULT 0
);
```

`assemble_context()` loads this and adds: "Tools currently degraded: {list}. Unavailable: {list}."

**Effort:** Medium (1 day for both parts).

**Dependencies:** None new.

---

### Gap 2.3: Error budgets — Learn from failure patterns

**Problem:** Chump tries a failing task 3 times, marks it blocked, and moves on. But he doesn't recognize patterns: "I've failed at 4 dependency-upgrade tasks in a row" or "edit_file always fails on files with certain patterns."

**Solution:** Extend `episode_db` with a query: `episodes_by_tag_and_sentiment(tag, sentiment, limit)`. Then in opportunity rounds, add:

```
Before creating new tasks, check your recent failures:
  episode search sentiment=frustrating limit=5
If you see a pattern (same type of task keeps failing), avoid creating more like it.
Instead, create a task to investigate WHY that type fails.
```

This is mostly a prompt change + one new DB query.

**Effort:** Low (half day).

**Dependencies:** Episode tool (exists).

---

### Gap 2.4: Task priority

**Problem:** Tasks have no priority. Chump picks the lowest ID, which is just the oldest. No way to express urgency.

**Solution:** Add `priority` column to `chump_tasks` (INTEGER, default 0, higher = more urgent). Update `task_list` to order by `priority DESC, id ASC`. Update `task` tool schema to accept `priority` on create and update.

Migrate existing table:

```sql
ALTER TABLE chump_tasks ADD COLUMN priority INTEGER DEFAULT 0;
```

**Effort:** Low (half day). Schema change + tool update.

**Dependencies:** None.

---

### Gap 2.5: Time awareness

**Problem:** Chump doesn't know what time it is, how long he's been running, or how many rounds are left. Can't pace himself.

**Solution:** In `assemble_context()`, inject:

```
Current time: {UTC timestamp}
```

For heartbeat rounds (via env vars from Gap 1.4):

```
Heartbeat: round {N} of ~{estimated_total}, {elapsed_human} into {duration_human} run. ~{remaining_human} left.
Pace yourself: don't start large tasks near the end.
```

**Effort:** Trivial (included in Gap 1.4 work).

**Dependencies:** Gap 1.4 env vars.

---

## Theme 3: Operational Visibility (you know what Chump did)

### Gap 3.1: Morning report — Summary DM after heartbeat

**Problem:** After an overnight heartbeat, you have to read the raw log to know what happened. No summary.

**Solution:** At the end of `heartbeat-self-improve.sh`, run one final Chump invocation with a summary prompt:

```bash
# After the main loop ends:
SUMMARY_PROMPT="This is the end of a self-improve heartbeat ($round rounds over $DURATION).
Summarize what happened: check your recent episodes (episode recent limit=$round), check task status (task list),
check if you opened any PRs (gh_list_my_prs). Write a concise report:
- Tasks completed
- Tasks blocked (and why)
- PRs opened
- Errors encountered
- Things Jeff should know
Send this as a notification to Jeff (notify tool). Be concise — 5-10 lines max."

echo "[...] Generating morning report..." >> "$LOG"
"${RUN_CMD[@]}" "$SUMMARY_PROMPT" >> "$LOG" 2>&1 || true
```

Also write the summary to `logs/morning-report-{date}.md` so it's accessible outside Discord.

**Effort:** Low (a few hours). It's a prompt + script addition.

**Dependencies:** Notify tool (exists), episode tool (exists).

---

### Gap 3.2: Config validation at startup

**Problem:** ~30 env vars, easy to misconfigure. Tools silently don't register. You debug by reading code.

**Solution:** A startup check that runs before the agent starts (in `main.rs` or `discord.rs`):

```rust
fn validate_config() {
    let mut warnings = Vec::new();
    let mut enabled = Vec::new();

    // Required for Discord
    if std::env::var("DISCORD_TOKEN").is_err() {
        warnings.push("DISCORD_TOKEN not set — Discord mode unavailable");
    }

    // Repo tools
    if repo_path::repo_root_is_explicit() {
        enabled.push("Repo tools (read_file, edit_file, etc.)");
    } else {
        warnings.push("CHUMP_REPO/CHUMP_HOME not set — repo tools disabled");
    }

    // GitHub
    if github_tools::github_enabled() {
        enabled.push("GitHub tools");
    } else {
        warnings.push("GITHUB_TOKEN + CHUMP_GITHUB_REPOS not set — GitHub tools disabled");
    }

    // gh CLI tools
    if gh_tools::gh_tools_enabled() {
        enabled.push("gh CLI tools (issues, PRs, branches)");
    }

    // Tavily
    if tavily_tool::tavily_enabled() {
        enabled.push("Web search (Tavily)");
    } else {
        warnings.push("TAVILY_API_KEY not set — web search disabled");
    }

    // Brain
    if brain_root().is_ok() {
        enabled.push("Brain (memory_brain)");
    } else {
        warnings.push("CHUMP_BRAIN_PATH not set or doesn't exist — brain disabled");
    }

    // Executive mode
    if executive_mode() {
        enabled.push("Executive mode (no CLI restrictions)");
    }

    // Log it all
    eprintln!("=== Chump config ===");
    for e in &enabled { eprintln!("  ✅ {}", e); }
    for w in &warnings { eprintln!("  ⚠️  {}", w); }
    eprintln!("====================");

    // Also log to chump.log
    chump_log::log_config_summary(&enabled, &warnings);
}
```

Run at startup. Also available as `--check-config` CLI flag.

**Effort:** Low (half day). All the `_enabled()` functions exist.

**Dependencies:** None.

---

### Gap 3.3: PR follow-up — Check outstanding work

**Problem:** Chump opens PRs but never checks if they were merged, closed, or commented on. No "morning standup" where he reviews his own open work.

**Solution:** Add to the WORK_PROMPT in `heartbeat-self-improve.sh`, at step 1:

```
1.5 CHECK YOUR OUTSTANDING WORK:
   - If gh tools are available: run gh_list_my_prs to see your open PRs.
   - For each open PR: gh_pr_checks to see if CI passed.
   - If CI failed: create a task to fix it (or resume an existing task).
   - If PR has comments from Jeff: read them and respond or update the code.
   - If PR was merged: set the related task to done and log a win episode.
```

Also useful: a `gh_pr_comments` tool that reads comments on a PR. Currently missing — Chump can only post comments, not read them. Add `gh_pr_list_comments` (wraps `gh pr view --comments`).

**Effort:** Low (prompt change) + Medium (new tool for reading PR comments).

**Dependencies:** gh_tools (exists).

---

## Theme 4: Safety & Recovery

### Gap 4.1: Rollback — Undo changes safely

**Problem:** Chump can edit and commit, but if a change breaks things, he has no structured way to undo. He'd have to manually construct a `git revert` command.

**Solution:** Two new tools:

**`git_stash`** — Stash uncommitted changes:
```
git_stash(action: "save"|"pop"|"list"|"drop")
```

**`git_revert`** — Revert the last commit (or a specific one):
```
git_revert(optional: commit_hash)  // defaults to HEAD
```

Both wrap `git stash` and `git revert` with the same path guards as `git_commit`/`git_push`.

Add to the WORK_PROMPT: "If your changes break tests and you can't fix them in 3 attempts, use git_stash or git_revert to undo, set the task to blocked, and notify."

**Effort:** Low (half day each, simple wrappers).

**Dependencies:** git_tools module (exists).

---

### Gap 4.2: Model quality guard — Sanity check responses

**Problem:** If the model produces garbage (hallucinated tool calls, incoherent text, empty responses), Chump has no way to detect it. He just keeps going.

**Solution:** After each `agent.run()`, basic sanity checks:

```rust
fn sanity_check_response(response: &str) -> ResponseQuality {
    if response.is_empty() {
        return ResponseQuality::Empty;
    }
    if response.len() < 10 && !response.contains("ok") {
        return ResponseQuality::Suspicious;
    }
    // Check for common failure patterns
    if response.contains("I cannot") || response.contains("I'm unable") {
        return ResponseQuality::Refusal;
    }
    ResponseQuality::Ok
}
```

On `Empty` or `Suspicious`: log a warning, retry once. On repeated failures: mark the round as failed, don't commit anything.

This is a simple heuristic, not a full evaluation — but it catches the worst failures.

**Effort:** Low (half day).

**Dependencies:** None.

---

## Theme 5: Collaboration

### Gap 5.1: `ask_jeff` — Async question/answer

**Problem:** Chump can DM you (notify), but it's one-way. He can't ask a question and wait for an answer. If he's uncertain about an approach, he either guesses or sets the task blocked. No "which do you prefer, A or B?" flow.

**Solution:**

**SQLite table:**
```sql
CREATE TABLE chump_questions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    question TEXT NOT NULL,
    context TEXT,
    priority TEXT DEFAULT 'curious',  -- blocking, curious, fyi
    asked_at TEXT,
    answered_at TEXT,
    answer TEXT
);
```

**`ask_jeff` tool:**
```
ask_jeff(question, context?, priority: "blocking"|"curious"|"fyi")
→ stores question, sends DM via notify, returns "Question #{id} sent to Jeff."
```

**Answering:** You reply in Discord. The Discord handler detects replies that start with `answer:` or `re: question #N` and stores the answer in the DB.

**Session assembly:** `assemble_context()` checks for new answers:
```
Jeff answered your questions:
  Q#{id}: {question} → A: {answer}
```

And for unanswered blocking questions:
```
Blocking questions (waiting for Jeff):
  Q#{id}: {question} (asked {time_ago})
  → Don't work on related tasks until Jeff answers.
```

**Effort:** Medium-High (1-2 days). New table, tool, Discord handler changes, context assembly.

**Dependencies:** Notify tool (exists), Discord handler.

---

### Gap 5.2: `watch_file` — React to your changes

**Problem:** If you edit a file between sessions, Chump doesn't know. He might be working on an outdated understanding of the code.

**Solution:** At session start (in `assemble_context()`), compute `git diff --name-only HEAD~1..HEAD` (or compare against a stored snapshot). If files changed:

```
Files changed since your last session:
  M src/discord.rs
  M src/cli_tool.rs
  A src/new_module.rs
Read the changed files before working on related code.
```

Simpler than a background watcher — just check git history at startup.

**Effort:** Low (half day). Just git commands in `assemble_context()`.

**Dependencies:** CHUMP_REPO (exists).

---

## Implementation Order

Grouped into sprints by theme. Each sprint is ~2-3 days of work.

### Sprint 1: Reliable Continuity (highest impact)

| Order | Item | Effort | Impact |
|---|---|---|---|
| 1 | `assemble_context()` | 1 day | **Critical** — makes everything else work better |
| 2 | `close_session()` | 0.5 day | High — prevents state loss |
| 3 | Config validation | 0.5 day | Medium — prevents debugging sessions |
| 4 | Task priority column | 0.5 day | Medium — smarter task selection |

**Total: ~2.5 days. After this sprint, Chump reliably knows who he is at every session start.**

### Sprint 2: Heartbeat Intelligence

| Order | Item | Effort | Impact |
|---|---|---|---|
| 5 | Schedule integration (`--chump-due` + script) | 1 day | High — alarms actually fire |
| 6 | Time/round awareness (env vars + context) | 0.5 day | Medium — pacing |
| 7 | Morning report (summary prompt + notify) | 0.5 day | **High** — you see what Chump did |
| 8 | PR follow-up (prompt change + optional tool) | 0.5 day | Medium — closes work loops |

**Total: ~2.5 days. After this sprint, heartbeat rounds are aware of each other and you get a report.**

### Sprint 3: Intelligence & Safety

| Order | Item | Effort | Impact |
|---|---|---|---|
| 9 | Cost accounting (Tavily + model counters) | 1 day | Medium — resource awareness |
| 10 | Tool health awareness | 1 day | Medium — stops banging head on wall |
| 11 | `git_stash` + `git_revert` tools | 0.5 day | Medium — safe recovery |
| 12 | Model quality guard | 0.5 day | Medium — catches garbage output |
| 13 | Error budgets (episode sentiment query) | 0.5 day | Low-Medium — pattern recognition |

**Total: ~3.5 days. After this sprint, Chump is resource-aware and can recover from mistakes.**

### Sprint 4: Collaboration & Context

| Order | Item | Effort | Impact |
|---|---|---|---|
| 14 | `watch_file` (git diff at startup) | 0.5 day | Medium — knows what you changed |
| 15 | Context window management (summarize+trim) | 1 day | Medium — long threads don't break |
| 16 | `ask_jeff` (full async Q&A) | 1.5 days | **High** — true collaboration |

**Total: ~3 days. After this sprint, Chump is a collaborator, not just a tool user.**

---

## What This Gives You

After all 4 sprints (~12 days of work):

**Before:** Chump is a capable agent that sometimes forgets what he's doing, wastes Tavily credits, doesn't check his alarms, can't undo mistakes, and requires you to read logs to know what happened.

**After:**
- Every session starts with full context (ego, tasks, episodes, schedule, PRs, file changes)
- Every session ends with state saved and brain committed
- Heartbeat rounds check scheduled items, know their position in the run, and hand off to each other
- You get a morning report DM summarizing the night's work
- Chump tracks resource costs and makes tradeoffs
- Chump detects tool failures and stops retrying broken tools
- Chump can stash/revert changes when things go wrong
- You can ask Chump questions that he'll pick up in his next session
- Long Discord threads don't lose context
- Config problems are caught at startup, not after debugging

Chump goes from "agent with tools" to "autonomous developer you trust to run overnight and report back in the morning."

---

## Files to Create/Modify

| File | Action | Sprint |
|---|---|---|
| `src/context_assembly.rs` | **New** — assemble_context() + close_session() | 1 |
| `src/tool_health_db.rs` | **New** — tool health table + queries | 3 |
| `src/cost_tracker.rs` | **New** — per-session cost accounting | 3 |
| `src/git_stash_tool.rs` | **New** — git stash wrapper | 3 |
| `src/git_revert_tool.rs` | **New** — git revert wrapper | 3 |
| `src/ask_jeff_tool.rs` | **New** — async Q&A tool | 4 |
| `src/ask_jeff_db.rs` | **New** — questions table | 4 |
| `src/discord.rs` | **Modify** — call assemble_context(), close_session(), config validation, answer detection | 1-4 |
| `src/main.rs` | **Modify** — add --chump-due flag, config validation | 1-2 |
| `src/task_db.rs` | **Modify** — add priority column + migration | 1 |
| `src/task_tool.rs` | **Modify** — accept priority param | 1 |
| `src/episode_db.rs` | **Modify** — add sentiment query | 3 |
| `src/tavily_tool.rs` | **Modify** — increment cost counter | 3 |
| `src/local_openai.rs` | **Modify** — increment model call counter | 3 |
| `scripts/heartbeat-self-improve.sh` | **Modify** — schedule check, env vars, morning report | 2 |
| `scripts/heartbeat-learn.sh` | **Modify** — schedule check, env vars | 2 |
