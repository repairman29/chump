# Roadmap: Dogfood and Self-Improve — Maximize Chump’s Capability and Capacity

This roadmap phases **capability and capacity** so Chump can dogfood (use himself), improve himself, and eventually operate with **full access to his own GitHub repos** and **executive tool functions (no limits)**. Each phase builds on the previous; autonomy tiers and heartbeat remain the gate for unattended or high-power modes.

**Relationship to other docs:** This extends the [ROADMAP](ROADMAP.md) and [CHUMP_AUTONOMY_TESTS](CHUMP_AUTONOMY_TESTS.md). The main ROADMAP covers systems, inference, memory, WASM, and multi-agent. This doc focuses on **self-use, repo access, and executive authority**.

---

## Current baseline (where we are)

- **Tools:** run_cli (allowlist/blocklist, timeout, output cap), memory (store/recall), calculator, wasm_calc, delegate (summarize, extract), web_search (Tavily).
- **Heartbeat:** `heartbeat-learn.sh` — learning rounds with web_search + memory; autonomy tier 4 unlocks unattended 8h.
- **Context:** Chump runs with cwd = process cwd (or `CHUMP_HOME` for warm-the-ovens); no dedicated “Chump repo” or GitHub identity.
- **CLI policy:** By default no allowlist = any command; allowlist/blocklist restrict. No “executive mode” yet.

---

## Phase 1: Repo awareness and self-model (capacity to dogfood) — implemented

**Goal:** Chump knows where _he_ lives and can read his own codebase. No write yet; no GitHub. This is the foundation for “improve myself.”

### 1.1 Chump repo root and system context

- **Config:** `CHUMP_REPO` (or reuse `CHUMP_HOME`) — canonical path to the Chump/rust-agent repo. Used by tools and system prompt so Chump can say “my codebase is at …” and reason about it.
- **System prompt:** When `CHUMP_REPO` is set, inject one line (or short block): “Your codebase (this agent) is at CHUMP_REPO. You can read and reason about it; do not modify it unless the user explicitly asks you to change the Chump codebase.”
- **run_cli cwd:** When the user says “in my repo” or “in the Chump repo,” run_cli can use `CHUMP_REPO` as `current_dir` for that invocation (optional; or document that user must `cd` or we add a `run_cli_in_repo` variant). Simplest: document that running Chump from `rust-agent` with `CHUMP_HOME` set gives him that cwd for run_cli.

### 1.2 Read-only repo tools (implemented)

- **Tool: `read_file`** — path (relative to CHUMP_REPO/CHUMP_HOME/cwd), optional start_line, end_line (1-based). Returns file contents. Path validation: under repo root, no `..`. Implemented in `repo_tools.rs` + `repo_path.rs`.
- **Tool: `list_dir`** — path (default “.”). Returns entry names and types (file/dir). Same path guard.
- **Purpose:** Chump can answer “what’s in src/discord.rs?” or “show me the memory tool schema” without running `cat`/`ls`. Enables self-documentation and “explain my code” flows.

### 1.3 Memory and heartbeat: “Chump knowledge” store

- **Convention:** When Chump learns something about _himself_ (e.g. “my memory is in sessions/chump_memory.db”, “I use AxonerAI”), store with source like `chump_self` or tag so recall can prefer “self” facts when the query is about Chump.
- **Heartbeat:** Extend the learning prompt (or add a periodic “self-model” round) so Chump occasionally reads key files (e.g. README, ROADMAP) and stores summaries in memory. Optional: delegate(summarize) on README or ROADMAP and store. That builds an internal “self-model” over time.

**Exit criteria:** CHUMP_REPO (or CHUMP_HOME) documented and used; read_file/list_dir under path guard; heartbeat or manual flow can populate “Chump knowledge” in memory.

---

## Phase 2: Write to own repo (dogfood edits, still human-gated) — implemented

**Goal:** Chump can _edit_ his own codebase when the user explicitly asks (e.g. “add a test for memory_tool”, “update the README”). All edits are in the Chump repo; no GitHub push yet.

### 2.1 Write tool with guardrails (implemented)

- **Tool: `write_file`** — path (relative to repo root), content, mode (overwrite or append). Allowed only when CHUMP_REPO or CHUMP_HOME is set; path must be under that root (no `..`). Implemented in `repo_tools.rs`; uses `resolve_under_root_for_write` for new files.
- **Audit:** Every write logged via `chump_log::log_write_file` (path, content_len, mode) in `logs/chump.log`.
- **System prompt:** When CHUMP_REPO/CHUMP_HOME is set, prompt tells Chump to use read_file/list_dir to read and write_file when the user asks to change the codebase; propose a short plan before editing.

### 2.2 Optional: “confirm destructive” for run_cli in repo

- When run_cli is about to run a command that modifies the repo (e.g. `git add`, `git commit`, `cargo build`), we have two options: (a) allow it with current policy (allowlist/blocklist), or (b) add an optional “executive confirmation” mode later. For Phase 2, keep run_cli as-is so Chump can run `cargo test` or `git status` from the repo; writes go through write_file.

### 2.3 Heartbeat: self-improvement tasks (user-initiated or scheduled)

- **Flow:** User says “Chump, run a self-improvement round: read BULLETPROOF_CHASSIS.md and add one unit test it suggests,” or “every night, read the latest ROADMAP and summarize what’s next in memory.”
- **Mechanism:** Heartbeat script or a dedicated “self-improve” prompt that: (1) reads a doc (read_file or run_cli cat), (2) delegates summarize/extract or uses main model to pick one concrete task, (3) executes via write_file or run_cli (e.g. run tests), (4) stores outcome in memory. Initially **on-demand** (user triggers) or **scheduled with explicit user consent** (e.g. “Chump, you may run one self-improve round per day at 3am”).

**Exit criteria:** write_file implemented with path guard and audit; Chump can edit his own repo when asked; one documented self-improvement flow (manual or scheduled). See “Self-improvement flow” below.

### Self-improvement flow (on-demand)

- **User-triggered:** “Chump, run a self-improvement round: read BULLETPROOF_CHASSIS.md and add one unit test it suggests,” or “read ROADMAP and summarize what’s next in memory.” Chump uses read_file (or run_cli cat), then write_file and/or run_cli (cargo test), and stores outcome in memory.
- **Mechanism:** No new script required; the user messages Chump in Discord or CLI with the request. Chump has read_file, list_dir, write_file, run_cli, delegate, and memory. For scheduled rounds, use cron/launchd to run a one-shot prompt (e.g. `openclaw --chump "Read docs/ROADMAP.md and store a one-paragraph summary of current phase in memory"`) or a small wrapper script that sources .env and runs the agent once.

---

## Phase 3: GitHub identity and read access to own repos — implemented

**Goal:** Chump has a GitHub identity and can **read** his own repos (read files via API). No push yet.

### 3.1 GitHub credentials and scopes

- **Config:** `GITHUB_TOKEN` or `CHUMP_GITHUB_TOKEN` — PAT with minimal scopes: `repo` (read) or at least read for the repos Chump is allowed to use. Stored in env or `.env` (never commit).
- **Allowlist of repos:** `CHUMP_GITHUB_REPOS` — e.g. `owner/rust-agent,owner/chump-menu`. Chump may only operate on these repos (clone, read, and later push). Default can include the repo that contains Chump (e.g. the Maclawd repo or a dedicated “Chump” org repo).

### 3.2 GitHub read tools (implemented)

- **Tool: `github_repo_read`** — repo (owner/name), path, optional ref (default main). Uses GitHub API with `Accept: application/vnd.github.v3.raw` for file content. Repo must be in CHUMP_GITHUB_REPOS. Implemented in `github_tools.rs`.
- **Tool: `github_repo_list`** — repo, path (dir, default “.”), optional ref. Returns “name (file)” or “name (dir)” per line. Same allowlist.
- **Tool: `github_clone_or_pull`** — repo, optional ref (default main). Clones into CHUMP_HOME/repos/owner_name (or pull if already present). Use read_file/list_dir on that path afterward. Audit: `chump_log::log_git_clone_pull`.

### 3.3 Self-model expansion

- Chump can now answer “what’s in the rust-agent README on GitHub?” or “list the docs in my other repo.” Memory can store “my GitHub repos: …” and “last clone/pull of X at …”. Heartbeat can periodically pull allowed repos and summarize changes (e.g. “new commits on main”) into memory.

**Exit criteria:** GITHUB_TOKEN (or CHUMP_GITHUB_TOKEN) + CHUMP_GITHUB_REPOS; github_repo_read and github_repo_list implemented and guarded; doc for setup. Tools register only when both token and allowlist are set.

---

## Phase 4: GitHub write and push (Chump can commit to his own repos) — implemented

**Goal:** Chump can create branches, commit, and push to his allowlisted GitHub repos. Still scoped to CHUMP_GITHUB_REPOS; no arbitrary orgs.

### 4.1 Token and scopes

- **Scopes:** PAT must include `repo` (read + write) for the allowlisted repos. Prefer fine-grained PAT limited to those repos if the org supports it.

### 4.2 Git write tools (implemented)

- **Tool: `git_commit`** — repo (owner/name, must be in CHUMP_GITHUB_REPOS), message. Runs `git add -A` and `git commit -m message` in CHUMP_REPO (or CHUMP_HOME). Audit: `chump_log::log_git_commit`.
- **Tool: `git_push`** — repo, optional branch (default main). Runs `git push origin branch` in CHUMP_REPO. Audit: `chump_log::log_git_push`. Requires git credentials configured (e.g. credential helper or token in remote URL). Implemented in `git_tools.rs`; register when CHUMP_REPO/CHUMP_HOME and CHUMP_GITHUB_REPOS are set.

### 4.3 Workflow: propose → confirm → push

- System prompt: “When you change code in your own repo, propose a short commit message and list of changes. Only run git_commit/git_push after the user says ‘push’ or ‘commit’ (or after an explicit approval). Do not push to main without confirmation unless the user has said you may do so.”
- Optional: `CHUMP_AUTO_PUSH=0` (default) vs `1` — when 1, Chump may push after his own commit without a second confirmation (still only to allowlisted repos).

**Exit criteria:** Chump can commit and push to allowlisted repos; audit log; confirmation flow documented. Propose short commit message and only push after user says “push” or “commit” (prompt guidance in system prompt when repo is set).

---

## Phase 5: Executive mode — no limits on exec (full capacity)

**Goal:** Chump can run **any** shell command (no allowlist/blocklist) when operating in “executive” context: either a dedicated channel/user, or an explicit env flag, with full audit and clear identity.

### 5.1 Definition of “executive”

- **Executive mode:** run_cli (and any future exec-style tools) do not apply allowlist/blocklist; timeout and output cap can be raised or removed (configurable). Intended for “Chump improving himself” or “trusted operator” use.
- **Gate:** Executive mode is **opt-in** and **explicit**:
  - **Option A:** `CHUMP_EXECUTIVE_MODE=1` — when set, run_cli ignores allowlist/blocklist and uses executive timeout/cap (e.g. 300s, 50k chars). Document: “Only set this when you intend Chump to have full host authority (e.g. on a dedicated machine or VM).”
  - **Option B:** Executive only when the Discord user ID (or channel) is in an allowlist (e.g. `CHUMP_EXECUTIVE_USER_IDS=123,456`). So only you (or a bot-admin) can trigger unlimited exec.
  - **Option C:** Both: env turns on the _capability_; user/channel allowlist restricts _who_ can use it.

Recommendation: **Option A + audit.** Require explicit env; log every executive run_cli with a tag `executive=1` in chump.log. Option B/C can be added for multi-user Discord.

### 5.2 Timeout and output cap (executive)

- **Config:** `CHUMP_CLI_TIMEOUT_SECS` (existing) and `CHUMP_CLI_MAX_OUTPUT_CHARS` (new). When executive mode is on, allow higher values (e.g. 300s, 50_000 chars) or “no cap” (stream or truncate at a very high limit to avoid OOM). Document the risk of huge output (memory, Discord message limit).

### 5.3 Scope of “no limits”

- **In scope:** run_cli runs any command the process user can run; no allowlist/blocklist. write_file and GitHub tools remain path/repo-scoped (CHUMP_REPO, CHUMP_GITHUB_REPOS).
- **Out of scope:** We do not remove path validation from read_file/write_file or GitHub tools. “No limits” applies to **exec** (run_cli), not to “write anywhere on disk” or “push to any repo.” So Chump can run `cargo build`, `git push`, or a custom script, but file writes stay inside the allowed trees.

**Exit criteria:** CHUMP_EXECUTIVE_MODE=1 (or equivalent) documented; run_cli in executive mode skips allowlist/blocklist and uses executive timeout/cap; every executive call audited; doc warns that this gives Chump full host authority.

---

## Phase 6: Sustained self-improvement loop (capacity maximized)

**Goal:** Chump runs a **continuous** self-improvement loop: read his own code and docs, run tests, propose and apply edits, commit and push to his own repos, and use web search + memory to incorporate external knowledge. All within the guardrails above (repo allowlist, executive only when explicitly on, full audit).

### 6.1 Loop design

- **Trigger:** (a) Scheduled (cron/launchd): e.g. daily at 3am, run “self-improve” job; or (b) User says “Chump, run a full self-improve cycle”; or (c) Heartbeat extended: one round per N hours is “read ROADMAP_DOGFOOD_SELF_IMPROVE.md and BULLETPROOF_CHASSIS.md, pick one item, implement it, test, commit, push.”
- **Steps per cycle:** (1) Pull latest from allowlisted repos (clone/pull). (2) Read one or two priority docs (e.g. ROADMAP, BULLETPROOF_CHASSIS, or an open issue). (3) Decide one concrete task (e.g. “add unit test for memory_tool recall”). (4) Implement via write_file and/or run_cli (tests, build). (5) If tests pass and user has approved auto-push (or cycle is manual): commit and push. (6) Store “Self-improve cycle at <time>: did X; result Y” in memory.
- **Guardrails:** Executive mode must be on for run_cli (cargo, git, etc.). Push only to CHUMP_GITHUB_REPOS. No push to main without confirmation unless CHUMP_AUTO_PUSH=1 and documented.

### 6.2 Autonomy tier for self-improve

- **Tier 5 (new):** “Self-improve certified.” Tests: (a) Chump can read_file a path under CHUMP_REPO; (b) Chump can write_file a test file and run_cli `cargo test`; (c) Chump can git_commit and git_push to an allowlisted repo (or run_cli git with executive mode). Optional: (d) One full self-improve cycle (read doc → pick task → implement → test → commit) without human in the loop, with CHUMP_AUTO_PUSH=0 so push still requires approval.
- **Unlock:** When tier 5 passes, scripts (heartbeat, Chump Menu) may offer “Start self-improve loop” (scheduled or on-demand) with executive mode and GitHub token configured.

### 6.3 Capacity ceiling

- **Compute:** Model (30B) and heartbeat/self-improve run on one machine; long cycles may need longer timeouts or chunking (e.g. “one PR per day”).
- **Rate limits:** GitHub API and Tavily have limits; self-improve loop should back off and log.
- **Safety:** Executive mode + GitHub write = Chump can change production code. Mitigations: branch-by-default (Chump works on `chump/self-improve` or similar), require PR or merge approval by human; or CHUMP_AUTO_PUSH only to a dedicated “chump-edits” branch.

**Exit criteria:** One documented self-improve cycle (manual or scheduled); tier 5 defined and tested; optional “Start self-improve loop” in Chump Menu or heartbeat; safety note in doc (branch strategy, approval).

---

## Summary table

| Phase | Focus                       | Key deliverables                                                                                         |
| ----- | --------------------------- | -------------------------------------------------------------------------------------------------------- |
| **1** | Repo awareness, self-model  | CHUMP_REPO; optional read_file/list_dir; “Chump knowledge” in memory; heartbeat can summarize own docs   |
| **2** | Write to own repo           | write_file with path guard and audit; self-improve flow (user-triggered or scheduled with consent)       |
| **3** | GitHub read                 | GITHUB_TOKEN + CHUMP_GITHUB_REPOS; github_repo_read, github_repo_list; optional clone/pull               |
| **4** | GitHub write/push           | git_commit, git_push (or run_cli in repo with guardrails); confirm-before-push; CHUMP_AUTO_PUSH optional |
| **5** | Executive mode              | CHUMP_EXECUTIVE_MODE=1; run_cli no allowlist/blocklist; executive timeout/cap; full audit                |
| **6** | Sustained self-improve loop | Scheduled or on-demand cycle; tier 5 autonomy; branch/approval strategy; “Start self-improve” in UI      |

---

## Dependency order

- Phase 1 does not depend on 2–6. Phases 2–6 build in order: 2 needs 1 (repo path); 3 needs 2 (optional, but self-model helps); 4 needs 3 (GitHub read before write); 5 is independent of 3–4 but pairs with 4 for “Chump can push his own changes”; 6 needs 1–5 (full loop uses repo awareness, write, GitHub, executive).
- **Bulletproof chassis first:** Complete [BULLETPROOF_CHASSIS](BULLETPROOF_CHASSIS.md) Phase A–B before enabling executive mode or automated push, so the core is stable and testable.

---

## Links

- [ROADMAP](ROADMAP.md) — Systems, memory, WASM, multi-agent.
- [CHUMP_AUTONOMY_TESTS](CHUMP_AUTONOMY_TESTS.md) — Tiers 0–4; tier 5 to be added for self-improve.
- [BULLETPROOF_CHASSIS](BULLETPROOF_CHASSIS.md) — Harden core before expanding authority.
- [CHUMP_SERVICE](CHUMP_SERVICE.md) — Heartbeat, launchd, warm-the-ovens.
- [USER_STORIES](USER_STORIES.md) — Repo and git stories (align with Phase 2–4).
