# Chump's Full Toolkit — Run of the Farm

Chump has executive mode (`CHUMP_EXECUTIVE_MODE=1`) and can run any command. This doc defines what should be **pre-installed and ready**, what **new native tools** to build, and how Chump **discovers and installs new tools on his own**.

Principle: Chump should never be stuck because a tool isn't installed. He should be able to find, install, evaluate, and adopt tools autonomously — then store what he learned so he gets better over time.

---

## Part 1: CLI Arsenal (pre-install via brew/cargo)

These should be installed on the machine so Chump can use them immediately. Group by purpose.

### Code Search & Navigation

| Tool | Install | Why |
|---|---|---|
| `ripgrep` (rg) | `brew install ripgrep` | 10x faster than grep, respects .gitignore, regex. Essential for codebase search. |
| `fd` | `brew install fd` | Better `find`. Fast, intuitive syntax, respects .gitignore. |
| `tree` | `brew install tree` | Directory visualization. Better than `ls -R` for understanding project structure. |
| `tokei` | `cargo install tokei` | Code stats: lines, blanks, comments per language. Know the shape of the codebase. |
| `ast-grep` | `cargo install ast-grep` | Structural code search using AST patterns. Find code by shape, not just text. |

### Code Quality & Analysis

| Tool | Install | Why |
|---|---|---|
| `cargo-nextest` | `cargo install cargo-nextest` | Faster test runner with better output, retries, and per-test timing. |
| `cargo-audit` | `cargo install cargo-audit` | Security advisory check on dependencies. Run in opportunity rounds. |
| `cargo-outdated` | `cargo install cargo-outdated` | Find outdated deps. Create tasks for upgrades. |
| `cargo-deny` | `cargo install cargo-deny` | License + advisory + duplicate dep check. |
| `cargo-tarpaulin` | `cargo install cargo-tarpaulin` | Code coverage. Know which paths are untested. |
| `cargo-expand` | `cargo install cargo-expand` | See macro expansion. Debug proc macros. |
| `cargo-watch` | `cargo install cargo-watch` | Auto-rebuild on change. Useful for long sessions. |
| `cargo-flamegraph` | `cargo install flamegraph` | Performance profiling. Find bottlenecks. |

### Data Processing

| Tool | Install | Why |
|---|---|---|
| `jq` | `brew install jq` | **Essential.** JSON processing. Parse API responses, config files, logs. |
| `yq` | `brew install yq` | YAML processing. Same idea as jq for YAML/TOML. |
| `xsv` | `cargo install xsv` | CSV processing. Fast column operations, joins, stats. |
| `sd` | `cargo install sd` | Better sed. Intuitive find-and-replace. |
| `htmlq` | `cargo install htmlq` | jq for HTML. Extract content from web pages. |

### System & Monitoring

| Tool | Install | Why |
|---|---|---|
| `bottom` (btm) | `brew install bottom` | System monitor. CPU, memory, disk, network, processes. |
| `dust` | `cargo install du-dust` | Better du. Visual disk usage. Know what's eating space. |
| `procs` | `cargo install procs` | Better ps. Find processes, filter, sort. |
| `bandwhich` | `cargo install bandwhich` | Network monitoring. See what's using bandwidth. |

### Network & API

| Tool | Install | Why |
|---|---|---|
| `xh` | `cargo install xh` | Better curl. HTTPie-compatible, colorized, clean syntax. |
| `curlie` | `brew install curlie` | curl with HTTPie interface. For when you want curl flags + readable output. |
| `dog` | `brew install dog` | Better dig. DNS lookups with color and multiple protocols. |

### Git & GitHub

| Tool | Install | Why |
|---|---|---|
| `gh` | `brew install gh` | GitHub CLI. **Already used.** Issues, PRs, checks, releases. |
| `delta` | `brew install git-delta` | Better git diffs. Syntax highlighting, side-by-side, line numbers. |
| `git-absorb` | `cargo install git-absorb` | Auto-fixup commits. Clean up history before PR. |
| `gitleaks` | `brew install gitleaks` | Scan for leaked secrets in git history. Security hygiene. |

### Documentation & Content

| Tool | Install | Why |
|---|---|---|
| `pandoc` | `brew install pandoc` | Universal document converter. Markdown → HTML/PDF/docx. |
| `mdbook` | `cargo install mdbook` | Generate docs site from markdown. Could build Chump's own docs. |

### Scripting & Automation

| Tool | Install | Why |
|---|---|---|
| `just` | `cargo install just` | Command runner (like make, but better). Define project-specific recipes. |
| `watchexec` | `cargo install watchexec-cli` | Run commands when files change. More general than cargo-watch. |
| `hyperfine` | `cargo install hyperfine` | Benchmarking CLI commands. Statistical rigor. |
| `nushell` (nu) | `brew install nushell` | Structured shell. Pipelines return tables, not text. Game-changer for parsing. |

### AI & LLM

| Tool | Install | Why |
|---|---|---|
| `ollama` | `brew install ollama` | Run additional models locally. Second opinion, different specialization. |
| `aider` | `pip install aider-chat` | AI coding tool. Inspiration and comparison for Chump's own approach. |
| `llm` | `pip install llm` | Simon Willison's CLI for LLMs. Quick one-shot queries to any provider. |

---

## Part 2: New Native Tools (build in Rust)

These are better as first-class Chump tools than shelling out. They close loops the wishlist identified.

### Priority 1: Close the loops

#### `read_url` — Fetch and extract web content

**Why:** `web_search` gives snippets. Chump needs full pages — docs.rs, GitHub READMEs, blog posts, Stack Overflow answers. Today he'd `curl | htmlq` but a native tool with content extraction is cleaner and token-efficient.

```
read_url(url, optional: selector, max_chars)
→ extracted text content (stripped nav/footer/ads)
```

**Implementation:** reqwest + scraper crate (or readability algorithm). Strip boilerplate, return clean text. Optional CSS selector for targeted extraction. Cap output to avoid flooding context.

#### `patch_file` — Unified diff edits (shipped)

**Why:** Fragile exact-string edits waste turns when context drifts. This tool parses a **single-file** unified diff, verifies every context and removal line against the current file, writes on success, and on mismatch returns a **line-numbered excerpt** of the real file (whole file if ≤200 lines, otherwise a window around the hunk) so the model can emit a corrected `patch_file` call immediately.

```
patch_file(path | file_path, diff) → success message, or recovery instructions + excerpt
```

**Implementation:** `patch` crate + strict applicator in `src/patch_apply.rs`; tool in `src/repo_tools.rs`; audit via `chump_log::log_patch_file`.

#### `run_test` — Structured test runner

**Why:** Parsing `cargo test` output with grep is fragile. Chump needs: pass/fail/error counts, which tests failed and why, compile error vs test failure vs timeout — as structured data he can reason about.

```
run_test(optional: filter, runner: "cargo"|"nextest")
→ { passed: 47, failed: 1, errors: 0, failures: [{name, message, stdout}], duration_secs }
```

**Implementation:** Run `cargo nextest run --message-format=libtest-json` (or `cargo test -- -Z unstable-options --format json` on nightly) and parse the JSON output. Fall back to text parsing for stable.

#### `crate_search` — Find Rust libraries

**Why:** When building new features, Chump needs to find the right crate. Today: `web_search "rust crate for X"` → hope for the best. A dedicated tool hits crates.io API directly.

```
crate_search(query, optional: sort_by: "relevance"|"downloads"|"recent")
→ [{name, version, description, downloads, recent_downloads, documentation}]
```

**Implementation:** Hit `https://crates.io/api/v1/crates?q=...` with reqwest. Parse response. Simple and high-value.

#### `system_info` — Know the machine

**Why:** Chump should know CPU load, available memory, disk space, and running processes without parsing `htop` output. Especially important before starting heavy operations (model loading, large builds).

```
system_info(optional: section: "all"|"cpu"|"memory"|"disk"|"processes")
→ { cpu_usage_pct, memory: {total, used, available}, disk: {total, used, free}, top_processes: [...] }
```

**Implementation:** `sysinfo` crate. Already cross-platform. Light dependency.

### Priority 2: Autonomy multipliers

#### `sandbox` — Throwaway environment

**Why:** Before touching the real repo, copy it, try something, throw it away. Makes Chump bolder. He can experiment without fear.

```
sandbox(action: "create"|"run"|"destroy", optional: command)
  create → copies repo to /tmp/chump-sandbox-{id}/, returns sandbox_id
  run(sandbox_id, command) → runs command in sandbox dir, returns output
  destroy(sandbox_id) → rm -rf
```

**Implementation:** cp -r + namespaced temp dirs + run_cli in that dir. Simple but game-changing for confidence.

#### `watch_file` — React to changes

**Why:** If you edit a file, Chump wants to know on next session. "Jeff edited `src/discord.rs` since your last session. Here's what changed." Closes the collaboration loop.

```
watch_file(action: "snapshot"|"diff")
  snapshot → hash all tracked files, store in DB
  diff → compare current hashes to last snapshot, return changed files + git diff
```

**Implementation:** Walk the repo, hash each file (or use git status/diff), store snapshot in SQLite. Run at session start.

#### `ask_jeff` — Async question loop

**Why:** Not a one-way DM. Chump poses a question, you answer when you have time, and Chump's next session starts with that answer in context. True collaboration.

```
ask_jeff(question, context, priority: "blocking"|"curious"|"fyi")
→ stored in DB; next session assembly injects unanswered questions + any answers
```

**Implementation:** SQLite table `chump_questions(id, question, context, priority, asked_at, answered_at, answer)`. You answer via Discord reply or a simple CLI. Session assembly checks for new answers.

### Priority 3: Vision and intelligence

#### `screenshot` — See the screen

**Why:** Chump is blind to visual output. He can run a dev server but can't tell if the UI is broken. With vision: verify UI, read error dialogs, see what a user would see.

```
screenshot(target: "screen"|"url", optional: url, selector)
→ base64 image (passed to vision model for description)
```

**Implementation:** macOS `screencapture` CLI for screen; headless Chrome/Playwright for URLs. Pass through vision API (or delegate to a multimodal model).

#### `introspect` — Query own tool call history

**Why:** "What did I actually do last session?" Episode log captures summaries; introspect gives ground truth — every tool call, input, output, duration.

```
introspect(action: "recent_calls"|"session_summary", optional: tool_name, limit)
→ [{tool, input_summary, output_summary, duration_ms, success, timestamp}]
```

**Implementation:** Log every tool call to SQLite (tool name, input hash, output length, duration, success). Query with filters.

---

## Part 3: Self-Discovery and Installation

This is the key unlock: Chump should be able to **find, evaluate, install, and adopt new tools on his own.**

### `tool_scout` — Discovery tool

A new native tool (or a self-improve round type) that:

1. **Searches** for tools relevant to a problem (Tavily + crates.io + brew search + GitHub trending).
2. **Evaluates** candidates: stars, recent commits, dependencies, size, platform support.
3. **Installs** the best candidate (brew install / cargo install / pip install).
4. **Tests** it with a simple command to verify it works.
5. **Documents** the tool in memory_brain (`tools/<tool-name>.md`) with: what it does, how to use it, when it's useful, and any gotchas.
6. **Creates a task** if the tool suggests a codebase improvement.

### Discovery round type for heartbeat

Add a 4th round type to the self-improve heartbeat:

```bash
ROUND_TYPES=(work work opportunity work work research work discovery)
```

**Discovery prompt:**

```
This is a tool discovery round. You are looking for CLI tools or Rust crates that would make you more capable.

1. Pick an area you've been frustrated with recently (ego read_all → frustrations) or a capability you lack.
2. Use web_search to find CLI tools or crates for that area. Try "best rust CLI tools for X" or "brew install X alternative".
3. Evaluate: is it well-maintained? Does it solve a real problem you have? Is it safe to install?
4. If promising: run_cli "brew install X" or "cargo install X". Then test it: run a simple command.
5. If it works: document it in memory_brain (write tools/<name>.md with usage notes).
6. Store the discovery in memory so you remember it exists.
7. If the tool suggests a codebase improvement, create a task.
```

### Tool inventory

Chump maintains a living inventory in `chump-brain/tools/`:

```
chump-brain/
  tools/
    installed.md      # master list: tool, version, installed_at, what_for
    ripgrep.md        # per-tool: usage, flags I actually use, gotchas
    cargo-nextest.md
    ...
```

Updated by discovery rounds and whenever Chump learns a new trick with an existing tool.

---

## Part 4: Bootstrap Script

A one-shot script to install the full arsenal on a fresh machine. See **scripts/bootstrap-toolkit.sh** in this repo.

- **Usage:** `./scripts/bootstrap-toolkit.sh`
- **Options:** `SKIP_CARGO=1` (skip cargo installs), `SKIP_BREW=1` (skip brew), `INCLUDE_OLLAMA=1` (install Ollama).
- **Idempotent:** Skips already-installed tools.
- **After run:** Execute `./scripts/verify-toolkit.sh` to check status.

---

## Part 5: Verify Script

See **scripts/verify-toolkit.sh** in this repo.

- **Usage:** `./scripts/verify-toolkit.sh` — human-readable ✅/❌ and summary by category.
- **Machine-readable:** `./scripts/verify-toolkit.sh --json` — JSON for Chump to parse (tool name, bin, category, installed).

**Chump native tool:** `toolkit_status` — calls the verify script with `--json` and returns the result so Chump can reason about what is installed vs missing (e.g. in discovery rounds).

---

## Part 6: Native Tool Build Order

What to implement first, based on impact × effort:

| Order | Tool | Impact | Effort | Notes |
|---|---|---|---|---|
| 1 | `read_url` | **High** — closes the "blind to the web" gap | Low | **Done.** reqwest + scraper. |
| 2 | `run_test` | **High** — structured test results, no grep | Medium | nextest JSON + fallback parser |
| 3 | `crate_search` | **Medium** — find deps without web_search | Low | crates.io API, ~100 lines |
| 4 | `system_info` | **Medium** — know machine state | Low | sysinfo crate, ~150 lines |
| 5 | `sandbox` | **High** — experiment without fear | Low | cp + temp dirs, ~100 lines |
| 6 | `ask_jeff` | **High** — true collaboration | Medium | SQLite + session assembly |
| 7 | `watch_file` | **Medium** — react to your changes | Low | git diff + hash store |
| 8 | `introspect` | **Medium** — ground truth on actions | Medium | tool call logging + query |
| 9 | `screenshot` | **High** — vision capability | High | screencapture + vision API |
| 10 | `tool_scout` | **Medium** — self-expanding toolkit | Medium | meta-tool, uses others |

---

## Part 7: Wishlist Items (from CHUMP_WISHLIST) — Status Update

| Wishlist Item | Status | Plan |
|---|---|---|
| `screenshot` + vision | Not started | Priority 3 native tool. Needs vision model access. |
| `diff_review` | **Done** | Already implemented. |
| `schedule` | **Done** | Already implemented. |
| `run_test` | **Done** | src/run_test_tool.rs; structured pass/fail, cargo/npm test. |
| `read_url` | **Done** | Implemented. Fetch URL, optional CSS selector, max_chars. |
| `watch_file` | Partial | Git diff at startup in context_assembly; full tool TBD. |
| `introspect` | Not started | Priority 2 native tool. |
| `sandbox` | Not started | Priority 2 native tool. |
| Emotional memory | **Done** | Episode sentiment + recent_by_sentiment; recent frustrating in context_assembly; ego frustrations in context. |
| `ask_jeff` | **Done** | src/ask_jeff_tool.rs + ask_jeff_db; context_assembly injects answers. |

---

## Summary

**Pre-install (30 min, one-time):** Run `scripts/bootstrap-toolkit.sh` to install ~30 CLI tools covering code search, quality, data processing, system monitoring, networking, git, docs, and automation.

**Build native tools (prioritized):** `read_url` → `run_test` → `crate_search` → `system_info` → `sandbox` → `ask_jeff` → `watch_file` → `introspect` → `screenshot` → `tool_scout`.

**Self-expanding:** Discovery rounds in heartbeat + tool_scout let Chump find, install, evaluate, and document new tools on his own. He maintains a living inventory in `chump-brain/tools/`.

**The vision:** Chump wakes up, reads his brain, checks his tasks, scans the codebase, finds opportunities, discovers tools that would help, installs them, uses them to improve the code, tests everything, commits to a branch, opens a PR, DMs you with what he did, and goes to sleep. Next session, he checks if the PR was merged, reads your comments, and adapts.
