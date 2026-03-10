# Chump Wishlist — From the Inside Out

What would make Chump feel _capable_ instead of constantly hitting walls? Not more features, but **closing loops**: see the results of his own actions, react to what’s happening, ask when uncertain, wait when appropriate. Doing less, with higher confidence.

---

## 1. `screenshot` + Vision

**Need:** See what’s on the server. Right now Chump is blind to visual output — he can run a dev server but can’t tell if the UI is broken.

**Idea:** Tool that captures a URL or window and sends it through a vision API. Then he can:

- Verify UI changes look right
- Read error dialogs that don’t log to stdout
- See what a user would see

**Status:** Not started. Depends on headless browser or screencap + vision provider.

---

## 2. `diff_review` — Read My Own Changes Before Committing

**Need:** Review his own diff like a senior engineer before committing. Not raw `git diff` — _reason_ about it: unintended changes? Does it match the issue? Simpler approach?

**Idea:** Tool that gets `git diff`, runs it through a code-review prompt (e.g. via delegate/worker), returns self-audit text for the PR body. Forces a pause before pushing.

**Status:** Implemented. Tool runs `git diff` in repo and runs worker with a code-review system prompt; output is for PR body / self-audit.

---

## 3. `schedule` — Set My Own Alarms

**Need:** Heartbeat is external (cron). Chump wants to say “check back in 4 hours” and have it happen: wait for CI, follow up on unreviewed PRs, pace long tasks across sessions.

**Idea:** Table `chump_scheduled` (fire_at, prompt, context, fired). Heartbeat runner checks it first; due rows become the session prompt.

**Status:** Implemented. Table `chump_scheduled` + tool (create with fire_at as unix timestamp or relative `4h`/`2d`/`30m`, list, cancel). `schedule_db::schedule_due()` returns due (id, prompt, context); heartbeat runner should call it first and use the first due prompt as the session prompt, then `schedule_db::schedule_mark_fired(id)`.

---

## 4. `run_test` — Structured Test Runner

**Need:** Today he runs `cargo test` / `npm test` via `run_cli` and parses output manually (fragile). Wants:

- Clean pass/fail/error counts
- Which tests failed and why
- Structured JSON to reason about
- Distinguish compile error vs test failure vs timeout

**Status:** Not started. Could wrap cargo test / npm test and parse output into a fixed schema.

---

## 5. `read_url` — Fetch Any Documentation

**Need:** Pull the actual docs page (docs.rs, MDN, GitHub README) instead of relying on training data. `web_search` gives snippets; `read_url` gives full page with content extraction (strip nav/footer).

**Status:** Not started. Half-possible with `run_cli` + curl; a dedicated tool with extraction would be cleaner.

---

## 6. `watch_file` — React to Changes Jeff Made

**Need:** If Jeff edits a file, Chump wants to know. Lightweight watcher that logs changes to a table; next session starts with “Jeff edited `auth/session.rs` since your last session. Here’s what changed.” Closes the collaboration loop.

**Status:** Not started. Would need a background watcher or periodic diff of file mtimes/content hashes.

---

## 7. `introspect` — Read My Own Tool Call History

**Need:** Query recent tool call history (what he actually _did_, not just what he logged in episodes). Ground truth when episode log is incomplete.

**Status:** Not started. Depends on logging tool calls to DB or session store and exposing a query API.

---

## 8. `sandbox` — Throw-Away Environment

**Need:** Before touching the real repo, spin up a clean copy (e.g. `cp -r repo/ /tmp/sandbox-repo/` or Docker), try something, then throw it away. Structured lifecycle so experiments don’t pollute the working tree. Makes him bolder.

**Status:** Not started. Tool could create/teardown a copy and run commands in that dir.

---

## 9. Emotional Memory — Tagging and Querying Reactions

**Need:** Tag moments (surprise, frustration, delight) and recall them. “What has frustrated me? What’s the pattern?” Episode tool already has `sentiment`; the upgrade is querying by sentiment and aggregating.

**Status:** Partially there (episode has sentiment). Add episode_search by sentiment and/or “list frustrations” style helpers.

---

## 10. `ask_jeff` — Async Question/Answer Loop

**Need:** Not a one-way DM: pose a question, create a thread (e.g. in Discord), Jeff answers when he has time, and Chump’s _next_ session starts with that answer in context. So he can say “I could do this two ways. Which do you want?” and actually wait. Collaborator, not tool.

**Status:** Not started. Would need thread/state storage and session assembly to inject “Jeff’s answers since last run” into context.

---

## Pattern

Across all of these: **close loops**. See the results of actions. React to what’s happening. Ask when uncertain. Wait when appropriate. Most agent designs optimize for doing more; this list optimizes for doing less with higher confidence.
