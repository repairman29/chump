# 20 user stories: Chump for building and organizing projects/repos

Stories you’d run with Chump in Discord (DM or @mention). Each assumes he has CLI, memory, and per-channel session.

---

## Setup and organization

1. **Scaffold a new repo**  
   As a dev I want to say “start a new Rust CLI project called my-tool” so that Chump proposes steps (cargo new, add deps, maybe a README) and runs them with my go-ahead.

2. **Organize an existing folder**  
   As a dev I want to say “this folder is a mess; suggest a structure and we’ll do it step by step” so that Chump lists directories/files, proposes moves, and runs only after I confirm.

3. **Standardize repo layout**  
   As a dev I want to tell Chump “I like docs/, src/, tests/ at the top” so that he remembers (memory store) and reuses that layout when we create or reorganize repos.

4. **Name and place new projects**  
   As a dev I want to say “I need a small script to sync env files, where should it live and what should we call it?” so that Chump suggests a name and path and optionally creates the file/dir with my approval.

5. **Audit what’s in a repo**  
   As a dev I want to say “what’s in this repo? List top-level and any README” so that Chump runs ls/tree/cat (or similar) and summarizes.

---

## Planning and breaking down work

6. **Turn a goal into steps**  
   As a dev I want to say “I want to add a health check to service X” so that Chump proposes a short plan (where the handler goes, what to run, tests) and I can say “do step 1” or “skip the test part.”

7. **Prioritize a backlog**  
   As a dev I want to paste a list of tasks and say “order these by impact and dependency” so that Chump returns a short ordered list and optionally stores it in memory for the next session.

8. **Break a feature into PRs**  
   As a dev I want to say “this feature is too big; suggest 2–3 PRs” so that Chump lists logical chunks and I can say “let’s do PR 1” and he helps with commands (branch, files, etc.).

9. **Estimate next steps**  
   As a dev I want to say “what’s the smallest next step to ship X?” so that Chump suggests one concrete step and, if I say go, runs the minimal CLI to do it.

10. **Recover context after a break**  
    As a dev I want to say “what were we doing on project Y?” so that Chump recalls from memory and/or session and summarizes; then we continue.

---

## Git and repo ops

11. **Safe status and diff**  
    As a dev I want to say “what’s changed in this repo?” so that Chump runs git status and git diff --stat (or similar) and summarizes without touching anything.

12. **Branch and first commit**  
    As a dev I want to say “new branch feature/health-check, add the handler file, and stage it” so that Chump proposes the steps, I say go, and he runs git checkout -b, creates/edits the file (or tells me what to add), and git add.

13. **Stash and switch**  
    As a dev I want to say “stash, switch to main, pull” so that Chump runs git stash, git checkout main, git pull and reports; I can then say “switch back and pop” and he does that.

14. **Clean up branches**  
    As a dev I want to say “list merged branches and then delete them one by one with my ok” so that Chump runs git branch --merged (or similar), lists them, and for each deletion waits for my confirmation.

15. **Commit with a good message**  
    As a dev I want to say “suggest a commit message for what’s staged” so that Chump runs git diff --cached, summarizes, and proposes a one-line message; I can say “use that” and he runs git commit -m "…".

---

## Running and verifying

16. **Run tests and summarize**  
    As a dev I want to say “run the tests and tell me if anything failed” so that Chump runs the test command (e.g. cargo test, pnpm test), then summarizes pass/fail and any failure lines.

17. **Build and run one command**  
    As a dev I want to say “build and run the app with --help” so that Chump runs the build and then the binary with --help and pastes the relevant output.

18. **Check deps and outdated**  
    As a dev I want to say “are any deps outdated or insecure?” so that Chump runs the appropriate command (cargo outdated, npm audit, etc.) and summarizes; he can remember my preferred stack (memory) for next time.

19. **Lint and fix**  
    As a dev I want to say “run the linter and apply safe fixes” so that Chump proposes the command (e.g. cargo fmt, pnpm lint --fix), I confirm, and he runs it and reports.

20. **Smoke-check after a change**  
    As a dev I want to say “we just changed X; what’s the minimal check?” so that Chump suggests one or two commands (e.g. build + one test, or curl health), runs them with my ok, and reports.

---

## Making it work well

- **Memory:** Tell Chump your preferences once (e.g. “remember I use pnpm and Rust 2021”); he’ll store and recall so later stories (6–20) stay consistent.
- **Plans:** For any multi-step story, he’ll propose first; say “go” or “do step 2 only” so execution stays under your control.
- **CLI:** He runs from the **bot cwd** (where you started `run-discord.sh`). For repo work, start the bot from the repo root or the folder you care about.
- **Logs:** Use `tail -f rust-agent/logs/chump.log` to see messages and reply previews; use `sessions/chump_memory.json` to see what he’s remembered.

**Project/repo mode:** For these stories to work well, run Chump with project focus:

```bash
export CHUMP_PROJECT_MODE=1
./run-discord.sh
```

That uses a project-focused system prompt (git, plans, memory for preferences). Or set `CHUMP_SYSTEM_PROMPT` yourself for a custom prompt.
