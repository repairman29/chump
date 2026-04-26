---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Onboarding Friction Log

Running log of friction points encountered during first-install and early use. Used to prioritize UX improvements and update [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md).

## Format

Each entry: date, user type, friction point, resolution, and status.

**User types:** `new-external` (no prior Chump exposure), `new-internal` (knows the codebase), `upgrading` (existing install), `agent` (Claude/Cursor session starting cold)

---

## Log

| Date | User type | Friction point | Resolution | Status |
|------|-----------|---------------|------------|--------|
| 2026-04-17 | agent | `gap-claim.sh` refuses to run from main worktree root — no clear error message about needing a linked worktree | Added `CHUMP_ALLOW_MAIN_WORKTREE=1` override + error message explains worktree requirement | Fixed |
| 2026-04-17 | agent | `scripts/coord/bot-merge.sh --auto-merge` didn't exist yet — agents used manual `git push + gh pr create` | `bot-merge.sh --auto-merge` added and documented in CLAUDE.md | Fixed |
| 2026-04-17 | agent | Cargo.lock conflicts when multiple agents commit in parallel — no detection | `chump-commit.sh` wrapper introduced to reset unrelated staged files before commit | Fixed |
| 2026-04-18 | agent | Duplicate gap work — two sessions claimed same gap without knowing | Lease file system (`.chump-locks/`) replaced gaps.yaml `claimed_by` fields | Fixed |
| 2026-04-18 | agent | `status: in_progress` instruction in AGENT_COORDINATION.md contradicted the new lease system | AGENT_COORDINATION.md corrected | Fixed |
| 2026-04-18 | new-external | `./run-web.sh` fails silently when `CHUMP_HOME` not set — WebView loads blank | EXTERNAL_GOLDEN_PATH.md now calls out `CHUMP_HOME` requirement; `chump-preflight.sh` checks it | Fixed |
| 2026-04-18 | new-external | First `cargo build` takes 5–8 min with no progress indicator for LTO stages | Known; golden path notes expected time; no code change needed | Won't fix |
| 2026-04-18 | agent | `config/config.yaml` accidentally committed with live API key (no .gitignore entry for `config/`) | Key rotated; `config/*.yaml` added to `.gitignore` | Fixed |
| 2026-04-19 | upgrading | vLLM-MLX OOM on Metal during model reload — not obvious that reducing VLLM_CACHE_PERCENT fixes it | GPU_TUNING.md created; OPERATIONS.md links to OOM runbook | Fixed (doc) |
| 2026-04-19 | new-external | `chump --preflight` binary not found after `cargo build` (PATH not updated) | Golden path now uses `./target/debug/chump --preflight`; also `./scripts/ci/chump-preflight.sh` | Fixed |
| 2026-04-19 | agent | tools_index.md listed only 27 of 48+ native tools — agents couldn't plan around missing tools | tools_index.md Extended Native Tools section added | Fixed |

## Patterns

**Most common blockers for external new users (no prior context):**
1. Path / env setup (`CHUMP_HOME`, PATH, `.env` variable order)
2. First build time expectation — no progress indicator on LTO
3. Model pull size — `ollama pull qwen2.5:14b` is 8GB; not called out in initial prereqs

**Most common blockers for agents:**
1. Worktree requirement not obvious from error messages
2. gaps.yaml discipline enforcement — stale instructions in docs
3. Missing tool discovery (tools_index.md gaps)

## Proposed fixes (not yet done)

- [ ] `./run-web.sh` should check `CHUMP_HOME` early and print a clear error if unset
- [ ] `cargo build` progress: add a "first build expected time" note to EXTERNAL_GOLDEN_PATH.md §3
- [ ] `chump --preflight` should be runnable without a web server for basic env checks
- [ ] `.gitignore` should include `config/*.yaml` and `config/*.json`

## See Also

- [External Golden Path](EXTERNAL_GOLDEN_PATH.md) — first-install walkthrough
- [Setup and Run](SETUP_AND_RUN.md) — quick-start reference
- [PRODUCT_REALITY_CHECK.md](PRODUCT_REALITY_CHECK.md) — honest current-state assessment
