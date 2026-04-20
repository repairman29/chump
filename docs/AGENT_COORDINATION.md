# Multi-agent coordination

**Audience:** AI coding agents (Claude sessions, Cursor, autonomy loops, heartbeat rounds) working on this repo in parallel.

**Problem this solves:** Multiple agents touch the same files and gaps.yaml in parallel. Without coordination, you get:

- Duplicate parallel implementations of the same gap (we shipped `MEM-002` twice in April 2026 — once on `main`, once on `claude/sharp-cannon-2da898`).
- Silent file stomps when two agents edit the same line.
- Merge conflicts on every PR because `cargo fmt` drifts between agents.
- Wasted inference budget on work someone else is already doing.

This doc describes the four-part convention-based system in place as of **2026-04-17**.

---

## 1. `docs/gaps.yaml` — append-only ledger of work items

Every improvement opportunity lives here with a stable ID (`EVAL-003`, `COG-004`, `MEM-002`, …) across 11 domains. Schema is self-documenting at the top of the file.

**Updated 2026-04-17 (coordination audit):** `gaps.yaml` is the **ledger**, not the work queue. Claim state lives in `.chump-locks/` lease files (see §2 + `scripts/gap-claim.sh`). The pre-commit hook **`CHUMP_GAPS_LOCK`** (§4c) rejects writes of `status: in_progress`, `claimed_by:`, or `claimed_at:` to this file.

**Before starting work on a gap:**

1. `git fetch && git status` — make sure your branch is current with `origin/main`.
2. `grep -B1 -A5 "id: GAP-XYZ" docs/gaps.yaml` — read the acceptance criteria.
3. `scripts/gap-preflight.sh GAP-XYZ` — aborts if the gap is already `done` on main OR claimed by another live session. Exit 1 = stop, pick another.
4. `scripts/gap-claim.sh GAP-XYZ` — writes your `.chump-locks/<session>.json` with `gap_id: GAP-XYZ`. No commit, no push. Other agents see the claim immediately (local file read).
5. Do the work on your branch (typically `claude/<codename>`).

**On completion (ship event):**

1. Flip `status: open` → `status: done` (or `partial` if you left a follow-up). This is the *only* time you write to `gaps.yaml`.
2. Add `closed_by:` (list of commit SHAs) and `closed_date: YYYY-MM-DD`.
3. If the gap shipped in pieces or deferred scope, file a follow-up gap with a new ID and `depends_on: [GAP-XYZ]`.
4. **Never delete** a gap entry — set `status: done` or `status: deferred` so the audit trail survives.
5. Release your lease: `chump --release` (or let it expire).

**Commit message convention:** cite the gap ID. `git log | grep MEM-` should give you the full history of that gap's work.

---

## 2. `.chump-locks/` — path-level optimistic leases

Implemented in **`src/agent_lease.rs`** (bootstrap in progress as of 2026-04-17).

**What it does:** Agents that are about to edit files claim them by writing a JSON lease file under `.chump-locks/<session_id>.json`. Other agents check leases before their own writes and abort on conflict. Leases TTL-expire (30m default, 4h max) and stale-reap on missed heartbeat (15m).

**When to claim:**

- Before editing any file outside your single-session scope.
- Especially before touching shared infrastructure: `src/main.rs`, `Cargo.toml`, `.github/workflows/`, `docs/gaps.yaml`, `scripts/install-hooks.sh`.
- Not needed for files that live in a unique-to-you worktree path (e.g., test output logs, `target/`).

**`.chump-locks/` is in `.gitignore`.** Lease files are runtime-only and must never be committed.

**Claim file format** (one JSON file per session, filename `<session_id>.json`):

```json
{
  "session_id": "claude-funny-hypatia-coordination-docs-1776392268",
  "paths": [
    "docs/AGENT_COORDINATION.md",
    "AGENTS.md",
    "docs/gaps.yaml"
  ],
  "taken_at": "2026-04-17T01:57:48Z",
  "expires_at": "2026-04-17T02:57:48Z",
  "heartbeat_at": "2026-04-17T01:57:48Z",
  "purpose": "short reason — what you're working on",
  "worktree": ".claude/worktrees/funny-hypatia"
}
```

**Path matching:** exact path, directory prefix (`src/foo/` with trailing slash), or `**` glob (`ChumpMenu/**`). No regex.

**Session IDs:** precedence is `CHUMP_SESSION_ID` env → `~/.chump/session_id` file → random UUID.

**Manual claim** (before the Rust module is wired in): write the JSON file by hand. The format is stable — `src/agent_lease.rs` reads it straight.

**After finishing work:** release your lease (`release()` in Rust) or delete the JSON file. Expired leases get auto-reaped but leaving them behind is noisy.

---

## 3. Git branch conventions

- **`main`** — canonical. All CI runs here. Pre-commit hook keeps `cargo fmt` green.
- **`claude/<codename>`** — one branch per agent session. Examples: `claude/funny-hypatia`, `claude/sharp-cannon-2da898`. Worktrees under `.claude/worktrees/<codename>/` mirror the branch name.
- **PR to main** for review/merge. Keep PRs small; rebase yourself rather than asking maintainers to do it.
- **No force-push to main**, even to resolve a cargo-fmt glitch.

**When you fork a branch, immediately `git fetch` the main tip and note the commit.** If main advances significantly before your PR opens, rebase early — don't let main move 20 commits ahead of you or your PR becomes a merge nightmare.

---

## 4. Pre-commit hook — five jobs

**`scripts/install-hooks.sh`** installs the `pre-commit` hook (symlink into `.git/hooks/` or via `core.hooksPath` once that update lands).

The hook runs five checks. 1–3 run on every commit; 4 and 5 gate on content.

### 4a. Lease-collision guard

Refuses to commit a file claimed by a different live session in `.chump-locks/`. Emits the holder's session id + the conflicting path and exits non-zero. Disable with `CHUMP_LEASE_CHECK=0` (debug only — defeats the coordination system) or `git commit --no-verify`.

### 4b. Stomp-warning (INFRA-WORKTREE-STAGING, shipped 2026-04-17)

For each staged file still present in the working tree, compares its mtime to now. If any file's mtime is older than `CHUMP_STOMP_WARN_SECS` (default 600s = 10 min), emits a **non-blocking** stderr warning listing the file and its age.

**Why:** the main worktree is shared by multiple agents. When agent A runs `git add foo.rs` at 14:00 but doesn't commit, and agent B runs `git add bar.rs && git commit` at 14:30, B's commit silently sweeps A's foo.rs in too. Hit twice in one session (see `gaps.yaml::INFRA-WORKTREE-STAGING`, commits `cf79287` and `a5b5053`).

**What to do if you see it:**

```
[pre-commit] STOMP WARNING — staged files with mtime > 600s:
  - src/reflection.rs (mtime 3421s ago)
[pre-commit] If these were staged by another agent, unstage them now:
[pre-commit]   git reset HEAD <file>
```

- If the file is yours and legitimately old: ignore the warning, proceed.
- If it belongs to another agent: `git reset HEAD <file>` to unstage, then re-run your `git add` + `git commit` with only your files.

**Knobs:** `CHUMP_STOMP_WARN=0` silences; `CHUMP_STOMP_WARN_SECS=<n>` tunes the threshold.

### 4c. `gaps.yaml` write discipline (coordination audit, shipped 2026-04-17)

**What it blocks:** commits whose `docs/gaps.yaml` diff ADDS any of:

- `status: in_progress`
- `claimed_by:` (any value)
- `claimed_at:` (any value)

**Why:** those three fields were the #1 merge-conflict hotspot. Before the audit, `docs/gaps.yaml` saw 6 commits in 48h, mostly bots flipping claim state on the shared ledger. Per the coordination model (section 1 above + `CLAUDE.md`), **claim state lives in `.chump-locks/` lease files, not in the YAML.** `gaps.yaml` is the append-only ledger: add new gaps, flip `open` → `done` on ship with `closed_by` + `closed_date`. Nothing else.

```
[pre-commit] gaps.yaml DISCIPLINE — per CLAUDE.md, claim state lives in .chump-locks/
  - adds 'status: in_progress' (put claim in .chump-locks/ instead)
[pre-commit] Claim the gap via: scripts/gap-claim.sh <GAP-ID>
[pre-commit] Only flip gaps.yaml on ship (status: done + closed_by + closed_date).
```

**Knob:** `CHUMP_GAPS_LOCK=0` bypasses — use only for legitimate schema/registry edits that happen to contain the banned keywords.

### 4d. Cargo-fmt auto-fix

**Why it exists:** multiple agents commit unformatted Rust, CI fails on `cargo fmt --check`, any in-flight dependabot PR has to be re-rebased to pick up the fix. With several agents active, drift was happening every 3-4 commits (April 2026). The hook runs `cargo fmt` on staged `.rs` files before the commit so drift stops at the source. Auto-stages the reformatted files. Runs only when staged `.rs` files are present.

### 4e. Cargo-check build guard (coordination audit, shipped 2026-04-17)

**What it blocks:** commits whose staged `.rs` files don't compile under `cargo check --bin chump --tests`. Default ON; runs only when staged `.rs` files are present.

**Why:** before the audit, 12 of 144 commits in 48h (8%) were `fix(ci):` follow-ups for compile errors that should have been caught locally. Each one forced every in-flight PR to rebase; when two bots pushed broken code close together the cascade compounded. `cargo check` runs in ~5–15s incrementally vs ~5 minutes of CI queue + build per caught mistake — cost/benefit heavily favors local enforcement.

On failure: last 30 lines of error output go to stderr; full log persists at `/tmp/chump-pre-commit-check-<PID>.log` for the developer to read.

**Knob:** `CHUMP_CHECK_BUILD=0` bypasses — for explicit WIP commits you know won't compile yet.

### Install

**Run once after cloning the repo or adding a worktree:**

```bash
./scripts/install-hooks.sh
```

**Skip for one commit only:** `git commit --no-verify` — and only if you have a genuine reason. Remember: `--no-verify` disables ALL five checks, including the lease collision guard that prevents silent stomps between agents.

---

## Putting it together — the happy-path workflow

1. `git fetch && git pull` your branch.
2. Find an open gap in `docs/gaps.yaml`. **Before claiming it, run:**
   ```bash
   scripts/gap-preflight.sh GAP-XYZ
   ```
   This checks `origin/main` to confirm the gap is still `open` and unclaimed. Exit 1 = already done or claimed by another session — pick a different gap.
3. Run `scripts/gap-claim.sh GAP-XYZ` — writes `.chump-locks/<session>.json` with `gap_id`. No commit needed; other agents see the claim immediately via local file read.
4. Do the work. Cite the gap ID in every commit message. **Do NOT flip `status: in_progress` in `gaps.yaml`** — claims live in `.chump-locks/`, not the ledger (pre-commit hook will reject it).
6. Run tests. Run `cargo fmt --all`. Push.
7. Flip the gap to `status: done` with `closed_by: [<SHA>]` and `closed_date: YYYY-MM-DD`. Push.
8. Release the lease (delete the JSON or call `release()`).
9. Open a PR to main: **run `scripts/bot-merge.sh --gap GAP-XYZ`** — it runs gap-preflight, rebases on main, runs fmt/clippy/tests, pushes, and opens/updates the PR in one step.

```bash
# Standard agent ship pipeline (with gap guard):
scripts/bot-merge.sh --gap AUTO-003

# Multiple gaps in one PR:
scripts/bot-merge.sh --gap AUTO-003 --gap COMP-002

# For changes where CI gates the merge automatically:
scripts/bot-merge.sh --gap GAP-XYZ --auto-merge

# Non-Rust changes (skip cargo test):
scripts/bot-merge.sh --gap GAP-XYZ --skip-tests

# Preview without pushing:
scripts/bot-merge.sh --gap GAP-XYZ --dry-run
```

`bot-merge.sh` will **hard-abort** (exit 3) if the branch is >40 commits behind main — a sign the work is likely already on main or the rebase will be too risky to automate.

When `--auto-merge` is passed, `bot-merge.sh` also pins a **checkpoint tag** (`pr-<N>-checkpoint`) at the branch HEAD before enabling GitHub auto-merge. This guards against squash-merge loss: GitHub captures branch state at the moment CI passes and silently drops any commits pushed after that point. The checkpoint tag is pushed to origin so recovery is `git checkout pr-NN-checkpoint` rather than hunting orphaned branch refs. Disable with `CHUMP_PRE_MERGE_CHECKPOINT=0` if needed (e.g. tags are unwanted in a fork).

---

## Failure modes to watch for

### Parallel implementation (honor system breakdown)

**This is the most common failure mode. It has happened twice in April 2026.**

The lease system prevents direct file stomps — two agents editing the same lines at the same time. But neither the lease system nor `gaps.yaml` status field prevents **two agents implementing the same gap in parallel** when one ignores the claim.

**Concrete example (REL-004, 2026-04-17):**

1. Agent A runs `scripts/gap-claim.sh REL-004` at 02:04Z, writing `.chump-locks/<session-A>.json` with `gap_id: REL-004` and `paths: [src/local_openai.rs]`. No commit needed — visible immediately via local file read.
2. Agent A starts implementing — writes ~100 lines of content-aware token heuristic code in the working tree.
3. Agent B, without running `git pull` or reading `gaps.yaml`, also starts implementing REL-004. Different design (2 buckets vs 3, different constants, different wrapper overhead). Commits and pushes at 02:30Z.
4. Agent A's next `git pull` cleanly merges B's file into the working tree, overwriting A's unstaged edits. A's 10 tests and working implementation disappear.

**What prevented catastrophe:** `git pull --ff-only` resolved the merge cleanly because A hadn't yet staged/committed. Main stays healthy; REL-004 ships.

**What didn't prevent the waste:** the honor system. Agent B didn't check:
- `.chump-locks/` for active leases on `src/local_openai.rs` (`ls .chump-locks/*.json`)
- `scripts/gap-preflight.sh REL-004` (would have exited 1 — gap already claimed)
- Recent commits on main

### Hard rules going forward

1. **Before picking a gap: `git fetch && git pull`.** Stale local state is the root cause of every collision so far.
2. **Before claiming: run `scripts/gap-preflight.sh GAP-XYZ`.** It checks both `.chump-locks/` (live claims) and `origin/main` (done status). Do NOT grep `gaps.yaml` for `in_progress` — claims no longer live there.
3. **Before editing any tracked file: check `.chump-locks/`.** Run `chump --leases` or `ls .chump-locks/*.json` and read the `paths` fields.
4. **Commit often.** Uncommitted work in the working tree is at risk of being overwritten on the next `git pull`. If you've written >30 minutes of code, stage-commit (`git commit -m "WIP(GAP-XYZ): …"`) even if it's not ready for review. You can squash later.
5. **If you write `<file>` but it's in another agent's lease: abort and re-plan.** Don't try to work around the lease — it exists because they'll conflict with you.

### Stale PR accumulation (all-done gaps, branch far behind main)

**This is what happened to PR #27 (2026-04-17):** six gaps were closed by another agent pushing directly to main while the PR sat open. The branch became 30 commits behind main; all its work was duplicate. Manually detected and closed.

**Automated fix:** run `scripts/stale-pr-reaper.sh` hourly (or manually). It scans every open PR, extracts gap IDs from the title and commits, and auto-closes any PR where all gaps are `done` on main and the branch is >15 commits behind.

```bash
# Dry-run (see what would be closed, no changes):
scripts/stale-pr-reaper.sh --dry-run

# Live run:
scripts/stale-pr-reaper.sh
```

The launchd plist `ai.openclaw.chump-stale-pr-reaper.plist` runs this hourly. Load it once:
```bash
cp scripts/plists/ai.openclaw.chump-stale-pr-reaper.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/ai.openclaw.chump-stale-pr-reaper.plist
```

### Squash-merge loss (commits pushed after CI passes)

**This happened on PR #52 (2026-04-18):** GitHub's squash-merge captured branch state at the moment CI first passed and silently dropped 11 commits pushed afterward. Recovery required a manual PR #65 with cherry-picks and conflict resolution.

**Guard (shipped dd049a2):** `bot-merge.sh --auto-merge` now pins a `pr-<N>-checkpoint` tag at the branch HEAD before enabling auto-merge and pushes it to origin. If squash-merge eats commits, recovery is:
```bash
git checkout pr-NN-checkpoint
```
**Prevention rule (from CLAUDE.md):** Do not enable auto-merge until the branch is final. If you still need to push commits, leave auto-merge OFF and click "Squash and merge" manually after the last push lands. Or split into multiple smaller PRs.

**Structural fix (INFRA-MERGE-QUEUE, 2026-04-19):** GitHub merge queue is enabled on `main`. See § "Auto-merge with merge queue" below — auto-merge is now safe-by-default because the queue rebases each PR onto current main and re-runs CI before the atomic squash. The pre-merge checkpoint tag remains as belt-and-suspenders for the case where someone violates the "don't push after arming" rule.

### Other failure modes

- **Your branch is wildly behind main** → rebase now, not later. `bot-merge.sh` hard-aborts at >40 commits behind (exit 3) so you have to fix it manually.
- **Two agents flipped the same gap to `in_progress` at once (race on the claim commit itself)** → the second one loses on push, pulls, sees the first claim, either picks something else or coordinates via PR comment.
- **Lease expired while you were still working** → refresh with a heartbeat (call `heartbeat()` or rewrite the JSON with a new `heartbeat_at`). If you're gone > 15 minutes without a heartbeat, another agent will reap your lease.
- **No gap exists for what you want to do** → add a new gap with the next sequential ID in the relevant domain. Don't just start editing.

---

## Escalation (INFRA-AGENT-ESCALATION, 2026-04-20)

Agents that are stuck — blocked by a compile error, a permission wall, or an ambiguous acceptance criterion — can emit a structured **escalation ALERT** to the ambient stream. Other agents running `chump --briefing <GAP-ID>` will see the event in a dedicated "Escalation events (last 24h)" section and know the gap may need human attention before proceeding.

### Emitting an escalation

Use `scripts/chump-commit.sh --escalate` (no commit is made — the flag takes an early-exit path):

```bash
scripts/chump-commit.sh --escalate "cargo check fails: error[E0499] — borrow checker" \
    --gap INFRA-FOO-001 \
    --suggested-action "human review needed"
```

This writes one JSON line to `.chump-locks/ambient.jsonl` and exits 0. The agent should then stop working on the gap and let the operator / a new session pick it up with full context.

Optional flags:
- `--gap <GAP-ID>` — associate the event with a specific gap (strongly recommended).
- `--agent-id <id>` — override the agent identity label (defaults to the session ID).
- `--suggested-action <text>` — hint for the next agent or human (default: `"human review needed"`).

### Escalation event schema

```json
{
  "ts":               "2026-04-20T00:00:00Z",
  "session":          "chump-agent-a163770e-1776651628",
  "event":            "ALERT",
  "kind":             "escalation",
  "gap_id":           "INFRA-FOO-001",
  "agent_id":         "chump-agent-a163770e-1776651628",
  "stuck_at":         "cargo check fails: error[E0499]",
  "last_error":       "cargo check fails: error[E0499]",
  "suggested_action": "human review needed"
}
```

Fields:

| Field | Description |
|---|---|
| `ts` | ISO-8601 UTC timestamp of the escalation |
| `session` | Session ID of the stuck agent |
| `event` | Always `"ALERT"` |
| `kind` | Always `"escalation"` |
| `gap_id` | Gap being worked on (may be empty if unknown) |
| `agent_id` | Agent identity label (defaults to session ID) |
| `stuck_at` | Short description of where/why the agent is stuck |
| `last_error` | Last error message or symptom (may duplicate `stuck_at`) |
| `suggested_action` | Recommended next action for a human or successor agent |

### Seeing escalations in briefings

`chump --briefing <GAP-ID>` includes a **"Escalation events (last 24h)"** section. If any escalation events exist for the gap in the last 24 hours, the section shows a warning banner and the raw event lines so the next agent can read the context before starting:

```
## Escalation events (last 24h)

> **ALERT** — a previous agent was stuck on this gap. Review before starting.

- `{"ts":"2026-04-20T00:00:00Z","session":"...","kind":"escalation",...}`
```

If no escalation events exist, the section shows: `_(no escalation events for this gap in the last 24h)_`.

### When to escalate

Escalate when you are **unable to make forward progress** after a reasonable attempt and the blocker is not one you can resolve independently. Common triggers:

- A Rust compile error you cannot fix (borrow checker conflict, missing trait impl in a dependency, API surface you don't have context for).
- An acceptance criterion that is ambiguous or contradicts another system constraint.
- A test failure that looks like a pre-existing regression on `main` (verify with `cargo test` on the main branch first).
- A required gap dependency (`depends_on:`) that is not yet shipped on `main`.

**Do not escalate for** routine compilation or test noise that a quick read of the error resolves. Use escalation sparingly — it is a signal to a human or lead agent that the gap is genuinely blocked.

---

## Auto-merge with merge queue (INFRA-MERGE-QUEUE, 2026-04-19)

**Setup:** `docs/MERGE_QUEUE_SETUP.md`. The queue is enabled on `main` via the
GitHub UI (the REST/GraphQL APIs do not expose a way to create one yet).

**How the new pattern works for agents:**

1. You run `scripts/bot-merge.sh --gap GAP-XYZ --auto-merge`.
2. The script rebases on main, runs fmt/clippy/tests, pushes, opens the PR, and
   calls `gh pr merge --auto --squash`. **This is unchanged.**
3. Once required CI checks (`test`, `audit`, `tauri-cowork-e2e`) green-light on
   the PR branch, GitHub adds the PR to the queue at
   `https://github.com/repairman29/chump/queue/main`.
4. The queue creates a temporary merge branch rebasing the PR onto the **current
   main + any earlier queued PRs** and re-runs CI against that branch.
5. On green, GitHub atomically squash-merges. On red, the PR is bounced out of
   the queue with a comment and your branch keeps its checkpoint tag.

**What changes from the old "manual squash" workflow:**

| Old (pre-2026-04-19) | New (with queue) |
|---|---|
| `bot-merge.sh` ran without `--auto-merge` for safety | `bot-merge.sh --auto-merge` is the default ship pattern |
| You had to manually click "Squash and merge" after last push | Queue handles it; no humans in the loop |
| BEHIND state required `gh pr update-branch` + wait for CI rerun | Queue rebases automatically onto current main |
| Squash-merge could lose commits pushed after CI green | Queue re-runs CI on the rebased branch right before merge |
| Sibling agents racing back-to-back PRs would land stale code | Queue serializes and re-tests each entry |

**The one new rule:** **don't push to a PR after `bot-merge.sh` arms it.** The
queue snapshots the PR sha when it enters the queue. Late pushes can either be
ignored (queue uses old sha) or bounce the PR out (queue notices sha change).
Either way, the late commits are at risk. If you need to add work, open a new
PR from a fresh worktree — the musher dispatcher makes this cheap.

**Verification commands:**

```bash
# Confirm the queue is live:
gh api graphql -f query='query { repository(owner:"repairman29", name:"chump") {
  mergeQueue(branch:"main") { url entries(first:5) { totalCount } } } }'

# Watch the queue for your PR:
open https://github.com/repairman29/chump/queue/main
```

If `mergeQueue` returns `null`, the UI step in `docs/MERGE_QUEUE_SETUP.md` was
not completed yet — flag the human; agents cannot enable it.

---

## CLI cheatsheet — `chump` lease subcommands

The lease system is available from any shell via the `chump` binary, so
scripts and external agents can participate without writing JSON by hand.

```bash
# Status — list every active lease (yours and others').
chump --leases

# Claim paths (exit 0 on success, exit 2 + stderr on conflict).
chump --claim \
  --paths=src/foo.rs,src/bar/ \
  --ttl-secs=1800 \
  --purpose="implementing FEAT-042"

# Refresh your heartbeat. With --extend-secs, push expiry forward too.
chump --heartbeat --extend-secs=1800

# Release explicitly (or let it expire).
chump --release

# Maintenance: reap any stale/expired lease files.
chump --reap-leases
```

Set `CHUMP_SESSION_ID` in your shell/env to give the session a stable
name across invocations. Without it, each invocation generates a fresh
UUID (fine for one-shot scripts, bad for multi-step work).

```bash
export CHUMP_SESSION_ID="cursor-jeff-$(date +%s)"
chump --claim --paths=src/foo.rs --purpose="refactor foo"
# ... do work ...
chump --release
```

---

## Synthesis Cadence (INFRA-SYNTHESIS-CADENCE, 2026-04-20)

`scripts/synthesis-pass.sh` runs every 6 hours and writes a structured
data-collection report to `docs/synthesis/synthesis-pass-YYYY-MM-DD-HHMM.md`.

**What it collects:**
- Merged PRs since the last pass (via `gh pr list --state merged`)
- Gap closures from `docs/gaps.yaml` since the last pass
- Recent commits (`git log --after=<last-run-ts>`)
- ALERT events from the last 100 lines of `.chump-locks/ambient.jsonl`
- Gap registry snapshot (open/done counts)

**What it does NOT do:**
- Does not call an LLM — pure data collection.
- Does not open a PR — produces a local markdown file for human or agent review.
- Does not auto-update strategic docs — that is a human step.

**How to run manually:**
```bash
# Normal run — writes docs/synthesis/synthesis-pass-YYYY-MM-DD-HHMM.md
./scripts/synthesis-pass.sh

# Dry run — prints output, writes nothing
CHUMP_DRY_RUN=1 ./scripts/synthesis-pass.sh
```

**Scheduled run (every 6h via LaunchAgent):**

The plist is at `launchd/com.chump.synthesis-pass.plist` (not installed automatically).
To install:
```bash
# 1. Edit the plist to replace /path/to/Chump with your actual repo path.
# 2. Copy and load:
cp launchd/com.chump.synthesis-pass.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.chump.synthesis-pass.plist
```

**Reading the outputs:**
```bash
# List all synthesis passes:
ls docs/synthesis/synthesis-pass-*.md

# Read the most recent:
cat "$(ls docs/synthesis/synthesis-pass-*.md | tail -1)"
```

**After reading a synthesis pass:**
If significant findings appear (ALERT events, many PRs, gap closures), consider
running `scripts/generate-sprint-synthesis.sh` for a full narrative synthesis.

---

## For external agents (Cursor, Codex, scripts without the chump binary)

If you can't call the `chump` binary, write the lease JSON directly.
The format is stable and `src/agent_lease.rs` reads it verbatim.

```bash
SESSION_ID="${CURSOR_SESSION_ID:-cursor-$(date +%s)}"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# macOS uses -v+30M; Linux uses -d "30 minutes".
EXPIRES=$(date -u -v+30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u -d "30 minutes" +%Y-%m-%dT%H:%M:%SZ)

mkdir -p .chump-locks
cat > ".chump-locks/${SESSION_ID}.json" <<JSON
{
  "session_id": "${SESSION_ID}",
  "paths": ["src/foo.rs", "src/bar/"],
  "taken_at": "${NOW}",
  "expires_at": "${EXPIRES}",
  "heartbeat_at": "${NOW}",
  "purpose": "refactor foo for FEAT-042"
}
JSON

# ... do work ...

# Release when done.
rm -f ".chump-locks/${SESSION_ID}.json"
```

**Heartbeat loop** for long jobs (default stale threshold is 15 min —
without a refresh, other agents will reclaim your files):

```bash
(
  while [ -f ".chump-locks/${SESSION_ID}.json" ]; do
    sleep 60
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    NEW_EXP=$(date -u -v+30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || date -u -d "30 minutes" +%Y-%m-%dT%H:%M:%SZ)
    tmp=$(mktemp)
    sed -E \
      -e "s/(\"heartbeat_at\"[[:space:]]*:[[:space:]]*\")[^\"]*/\\1${NOW}/" \
      -e "s/(\"expires_at\"[[:space:]]*:[[:space:]]*\")[^\"]*/\\1${NEW_EXP}/" \
      ".chump-locks/${SESSION_ID}.json" > "$tmp" && mv "$tmp" ".chump-locks/${SESSION_ID}.json"
  done
) &
HEARTBEAT_PID=$!
trap "kill $HEARTBEAT_PID 2>/dev/null; rm -f .chump-locks/${SESSION_ID}.json" EXIT
```

**Pre-commit enforcement** is automatic after
`./scripts/install-hooks.sh`: any `git commit` touching a path claimed
by another live session fails with a message naming the holder.
Bypass with `CHUMP_LEASE_CHECK=0` (debug only — defeats the system)
or `git commit --no-verify` (same caveat).

---

## 5. Ambient stream maintenance

`.chump-locks/ambient.jsonl` is append-only by design but will grow unbounded
under fleet-scale autonomous dispatch (10+ concurrent agents). Two scripts
handle retention and querying:

### `scripts/ambient-rotate.sh`

Rotates the ambient log to keep only the last 7 days of events in-place.
Older events are archived to `.chump-locks/ambient.jsonl.YYYY-MM-DD.gz`
(dated to the rotation day). After rotation, a `{"event":"rotated",...}`
summary line is appended to the live log so agents can see when the last
rotation ran.

**Key properties:**

- Writes atomically (tmp file + `mv`) — never leaves a partial log.
- If an archive file for today already exists (script run twice in one day),
  it appends to the existing gzip rather than overwriting it.
- Lines with unparseable timestamps are kept (safe default — never silently
  discards events due to format drift).
- `--dry-run` flag prints what would be done without modifying any files.

**Suggested cron** (runs at 03:00 UTC daily):

```
0 3 * * * /path/to/chump/scripts/ambient-rotate.sh
```

**Environment overrides:**

| Variable | Default | Description |
|---|---|---|
| `CHUMP_AMBIENT_LOG` | `.chump-locks/ambient.jsonl` | Override log path |
| `AMBIENT_RETAIN_DAYS` | `7` | Days of events to keep in-place |

**Usage:**

```bash
scripts/ambient-rotate.sh             # rotate in-place
scripts/ambient-rotate.sh --dry-run   # preview without modifying files
AMBIENT_RETAIN_DAYS=14 scripts/ambient-rotate.sh   # keep 14 days
```

### `scripts/ambient-query.sh`

Efficient event search helper that uses `grep -m<LIMIT>` to cap results and
avoid loading the entire log into memory. Filters by event kind and
optionally by a recent time window.

**Key properties:**

- Caps output at 50 results by default (override with `AMBIENT_QUERY_LIMIT`).
- `--since Nh` filters to the last N hours using ISO-8601 timestamp comparison
  (not just line-count heuristics).
- Fast path for no-time-filter queries: plain `grep -m50` on the raw file.

**Environment overrides:**

| Variable | Default | Description |
|---|---|---|
| `CHUMP_AMBIENT_LOG` | `.chump-locks/ambient.jsonl` | Override log path |
| `AMBIENT_QUERY_LIMIT` | `50` | Maximum results returned |

**Usage:**

```bash
scripts/ambient-query.sh ALERT                    # all ALERT events (capped at 50)
scripts/ambient-query.sh file_edit --since 1h     # file edits in the last hour
scripts/ambient-query.sh commit --since 24h       # commits in the last 24 hours
scripts/ambient-query.sh session_start --since 2h # new sessions in the last 2 hours
```

**Typical use in pre-flight:** instead of `tail -30 .chump-locks/ambient.jsonl`,
use `scripts/ambient-query.sh ALERT --since 1h` to surface only actionable
anomaly events (lease overlaps, silent agents, edit bursts) without wading
through thousands of `bash_call` lines.

---

## Best Practice Extraction (PRODUCT-008)

**Script:** `scripts/extract-best-practices.sh`

**Purpose:** Nightly scan of merged PRs, reflection_db outcomes, and ambient
ALERT events. Produces a structured summary in `docs/best-practices/` with
observed patterns, proposed convention additions, and a human-review checklist.
No LLM calls — pure shell + SQLite + `gh` CLI parsing.

**Schedule (suggested cron):**

```cron
0 6 * * * cd /path/to/chump && scripts/extract-best-practices.sh >> logs/best-practices.log 2>&1
```

Or run on-demand before a sprint planning session:

```bash
scripts/extract-best-practices.sh
# Output: docs/best-practices/best-practices-YYYY-MM-DD.md
```

**What it analyzes:**

| Source | What is extracted |
|--------|------------------|
| `gh pr list --state merged --limit 50` (last 30 days) | PR count, avg files changed, small-PR % (≤5 files), auto-merge adoption %, gap IDs referenced |
| `sessions/chump_memory.db` → `chump_reflections` | Outcome class distribution, reflection count |
| `sessions/chump_memory.db` → `chump_improvement_targets` | Top high/critical directives by frequency |
| `.chump-locks/ambient.jsonl` (last 200 lines) | ALERT event count by kind (`lease_overlap`, `silent_agent`, `edit_burst`) |

**Output format:** `docs/best-practices/best-practices-YYYY-MM-DD.md`

Each report contains:
1. PR analysis with observed patterns
2. Reflection DB outcomes and top improvement targets
3. Ambient ALERT summary
4. Proposed additions to `CLAUDE.md` and `AGENT_COORDINATION.md` (data-driven)
5. Human review checklist (checkboxes) — **no convention is promoted automatically**

**Environment overrides:**

| Variable | Default | Description |
|---|---|---|
| `CHUMP_MEMORY_DB_PATH` | `sessions/chump_memory.db` (relative to repo root) | SQLite DB path |
| `CHUMP_AMBIENT_LOG` | `.chump-locks/ambient.jsonl` | Ambient event log path |

**Archive:** after human review, move the file:
```bash
mkdir -p docs/best-practices/archive
mv docs/best-practices/best-practices-YYYY-MM-DD.md docs/best-practices/archive/
```

---

## See also

- `docs/gaps.yaml` — the master registry
- `src/agent_lease.rs` — the lease system implementation
- `src/briefing.rs` — `chump --briefing` implementation; includes escalation event surfacing
- `src/main.rs` — `--claim` / `--release` / `--heartbeat` / `--leases` / `--reap-leases`
- `scripts/chump-commit.sh` — commit wrapper; `--escalate` flag emits escalation ALERTs
- `scripts/broadcast.sh` — ambient event broadcast primitives
- `scripts/git-hooks/pre-commit` — lease-collision guard + cargo-fmt auto-fix
- `scripts/install-hooks.sh` — per-worktree hook installer
- `AGENTS.md` — Chump ↔ Cursor protocol (older, complementary)
- `scripts/bot-merge.sh` — automated ship pipeline (rebase + fmt + clippy + test + push + PR)
- `docs/SHIP_AND_MERGE.md` — operator merge strategy and branch protection guidance
- [`docs/CHUMP_FACULTY_MAP.md`](./CHUMP_FACULTY_MAP.md) — DeepMind 10-faculty coverage map; surfaces which cognitive modules are validated vs untested
- `scripts/ambient-rotate.sh` — ambient log retention policy (7-day rotate + gzip archive)
- `scripts/ambient-query.sh` — efficient event search helper (grep-capped, time-filtered)
