# Agent Loop — Autonomous Work Queue

Give this doc to any Claude Code agent to put it on the shared work queue. It will pick gaps, do the work, ship PRs, and loop — without needing to be re-prompted.

---

## Starting a new agent — two modes

### Interactive Claude Code session (recommended)

1. Open a new Claude Code session
2. Type `/loop` — this gives the agent the `ScheduleWakeup` tool so it can self-pace
3. Paste as the first (or only) message:

```
You are a Chump agent on the autonomous work queue. Read docs/AGENT_LOOP.md and follow the loop instructions exactly. Start immediately — call ScheduleWakeup after each gap ships.
```

`/loop` is critical. Without it the agent has no way to reschedule itself and will stop after one gap.

### Unattended / scripted (shell loop wrapper)

```bash
scripts/agent-loop.sh
# or with a cap:
scripts/agent-loop.sh --max-gaps 10
```

This re-invokes `claude -p` with the AGENT_LOOP prompt after each gap. The agent does one gap per run and exits; the shell handles the retry loop. No `/loop` needed.

### Cursor IDE sessions, subagents, and Cursor CLI

For **Cursor Composer**, **Task / subagent** delegation, and headless **`agent`** runs from Chump or shell, use the same lease + gap-preflight bar as any other agent. Canonical patterns live in **`docs/CHUMP_CURSOR_FLEET.md`** (CLI smoke: `bash scripts/cursor-cli-status-and-test.sh`). Subagents should return a **single packaged handoff** to the parent; the parent owns claims, `docs/gaps.yaml` closure, and PR strategy.

### If `/loop` isn't available

If the agent reports that `ScheduleWakeup` is not a recognized tool, fall back to the shell wrapper above. The shell wrapper is always reliable; `/loop` is a speedup (warm cache, no re-init cost).

---

## The loop (what every agent does)

```
1. git fetch origin main --quiet
2. scripts/musher.sh --pick          → get your gap assignment
3. scripts/gap-preflight.sh <GAP-ID> → verify it's still available
4. chump --briefing <GAP-ID>         → load context for this gap
5. Do the work in .claude/worktrees/<codename>/
6. scripts/bot-merge.sh --gap <GAP-ID> --auto-merge
7. Go to step 1
```

If `musher.sh --pick` returns nothing (queue empty): sleep 5 minutes, then retry from step 1.

---

## Go slow to go fast — anti-stomp protocol

**Read this first.** The lessons below came from a 2026-04-20 incident in
which four parallel agents all filed new gaps from the same Red Letter in a
5-minute window, three of them invented their own meaning for `INFRA-017`,
and the gap registry ended up with three distinct `- id: INFRA-017` entries
on main. The pre-commit ID-hijack guard only catches *title rewrites of
existing entries* — it does not catch *duplicate-ID inserts*. Until that
guard is tightened (filed as a follow-up), coordination is on you.

### The race condition

New-gap IDs are picked by `max(PREFIX-NNN) + 1`. When three agents all
read `docs/gaps.yaml` at the same instant and all see `INFRA-016` as the
max, all three pick `INFRA-017`. The preflight check passes for each
independently (none of them have committed yet). The bot-merge race then
lands three different `INFRA-017` gaps.

### Hard rules for proactive gap-filing

These override the Autonomy section below when they conflict.

1. **Never invent a new gap ID while other agents may be filing.** Run
   `scripts/gap-reserve.sh <DOMAIN> "short title"` from your linked worktree
   first — it atomically reserves the next free ID (scans `origin/main`
   `docs/gaps.yaml`, open PR diffs for that file when `gh` is available, and live
   leases including `pending_new_gap`) and writes `pending_new_gap` to your
   session lease. Then add the `- id:` block to `docs/gaps.yaml` and ship in the
   same PR as the work. **Manual fallback** when you cannot run the script: scan
   open PRs + leases yourself and take `max(all_reserved_ids) + 1`, not
   `max(main_ids) + 1`.

2. **One proactive-filing session at a time.** If the ambient stream
   (`tail -30 .chump-locks/ambient.jsonl`) shows another session ran
   `gap-architect.py` or filed new gaps in the last 10 minutes, skip
   Autonomy pattern #1 this turn. Do queue work instead.

3. **Filing from the Red Letter is a gold-rush hotspot.** The Red Letter
   is read by every agent at cycle-start. If you decide to file gaps
   from it, broadcast intent first:
   ```bash
   scripts/broadcast.sh "filing red-letter gaps SEC-001,QUALITY-004,COG-035 — sibling agents please pick other items"
   ```
   Then wait 60 seconds for any conflicting broadcast before you start
   filing.

4. **Never ship more than one new-gap-ID per PR in a stomp-risk window.**
   Batched seed PRs (5+ new IDs at once) are the highest collision
   surface. Prefer one-gap-per-PR when other agents are active; it halves
   the bad-state recovery cost.

5. **"Don't stomp" overrides velocity.** If `chump-commit.sh` or
   `bot-merge.sh` fails for a reason you don't fully understand — pause,
   re-read the error, check siblings, and report to Jeff. **Do not bypass
   with `CHUMP_*=0` envs or `--no-verify` to clear the error.** The hooks
   exist because silent stomps have cost real work before.

### When you catch a collision in progress

- **You are the later filer** (your PR hasn't merged, a sibling's has):
  close your PR, pick a new ID, refile. Your work content is fine; only
  the ID needs to change.
- **You are the earlier filer** (your PR is armed with auto-merge, a
  sibling just opened one colliding): do nothing. The later PR will hit
  the hook. If the hook is broken and both land, file a cleanup gap.
- **Both PRs already landed with colliding IDs:** stop. File a
  dedupe gap (no new features in it) and wait for explicit direction —
  don't silently rewrite gap IDs, don't silently delete an entry. The
  registry is load-bearing for `chump --briefing` and the lease system.

---

## Full instructions (for the agent)

### Your job
Pick the next available gap from `docs/gaps.yaml`, do the work, ship a PR, repeat. The gap registry and lease system coordinate you with other agents — you never need to ask a human what to work on.

### Step-by-step

**1. Sync and check the queue**
```bash
git fetch origin main --quiet
scripts/musher.sh --pick
```
`musher.sh --pick` reads the live gap registry + active leases + open PRs and prints the best unclaimed gap for you. If the queue is empty it exits 1 — sleep 5 min and retry.

**2. Preflight**
```bash
scripts/gap-preflight.sh <GAP-ID>
```
Exits 1 if the gap was claimed between your `--pick` and now. If it fails, run `--pick` again.

**3. Load context**
```bash
chump --briefing <GAP-ID>
```
Produces a single markdown briefing: gap description, acceptance criteria, relevant lessons from `chump_improvement_targets`, recent ambient events, prior PRs that touched the same domain.

**4. Read the project rules**
Read `AGENTS.md` (build/test/lint/style) and `CLAUDE.md` (coordination, worktrees, commit discipline) before touching any files. They're short.

**5. Claim and work**
```bash
scripts/gap-claim.sh <GAP-ID>
# work in .claude/worktrees/<codename>/
```
Always work in a linked worktree, never in the main repo root.

**6. Ship**
```bash
scripts/bot-merge.sh --gap <GAP-ID> --auto-merge
```
This rebases on main, runs fmt/clippy/tests, opens the PR, and arms auto-merge. It prints the PR number when done. Once it runs, treat the PR as frozen — don't push more commits to it.

**7. Loop**
Return to step 1.

---

### Rules that matter most

| Rule | Why |
|------|-----|
| Always work in `.claude/worktrees/<codename>/` | Main repo stomps break other agents |
| Use `scripts/chump-commit.sh` not `git add && git commit` | Prevents cross-agent staging drift |
| Keep PRs ≤ 5 files, ≤ 5 commits | Smaller PRs land faster; merge conflicts are cheaper |
| Never touch `docs/gaps.yaml` except to (a) file a **new** gap (run `gap-reserve.sh` first for the ID), or (b) set `status: done` when shipping | Claims live in `.chump-locks/`, not the YAML. Filing adds a new `- id:` block, nothing else. |
| **Never invent a gap ID without `scripts/gap-reserve.sh`.** Run `scripts/gap-reserve.sh <DOMAIN> "title"` first; it stamps `pending_new_gap` in your lease so `gap-preflight.sh` accepts the ID before it exists on `main`. Ship the YAML block in the same PR as the work. **Bootstrap only:** `CHUMP_ALLOW_UNREGISTERED_GAP=1` on the tiny filing PR if you truly cannot run `gap-reserve.sh`. | Concurrent ID invention caused the INFRA-016/017/018 collision chain (2026-04-20) — three agents each picked the same "next free number" and shipped conflicting PRs. |
| **`chump --pick-gap` must see the same reservation.** It skips gap IDs already live-claimed in `.chump-locks/`, including both `gap_id` and `pending_new_gap.id` (INFRA-021). For SQLite workflows after `chump gap import`, use `chump gap reserve …` instead of the shell script. | Otherwise the musher and the Rust picker can assign work that collides with a session that already reserved the next ID in JSON leases. |
| Never push to `main` directly | Branch is `claude/<codename>` |
| Never touch COG-031 | Held at v9; requires explicit human decision |

---

### Self-scheduling with ScheduleWakeup (when in /loop mode)

After every gap ships OR after a queue-empty check, call `ScheduleWakeup` with:
- `prompt`: the exact text `"You are a Chump agent on the autonomous work queue. Read docs/AGENT_LOOP.md and follow the loop instructions exactly. Start immediately — call ScheduleWakeup after each gap ships."`
- `delaySeconds`: **60** if you just shipped, **270** if queue was empty (stays inside the 300s cache TTL)
- `reason`: one line — e.g. `"shipped INFRA-007, checking queue for next gap"` or `"queue empty, retrying in 270s"`

Without this call at the end of every turn, the loop dies. Always call it.

---

### Checking what's available right now

```bash
scripts/musher.sh --status          # full dispatch table
scripts/musher.sh --assign 3        # 3 non-overlapping assignments for 3 agents
scripts/musher.sh --why <GAP-ID>    # explain why a gap is/isn't available
scripts/musher.sh --check <GAP-ID>  # conflict analysis for a specific gap
```

---

### Signals from other agents

Check `tail -20 .chump-locks/ambient.jsonl` before starting work. Key events:

- `session_start` — another agent is online; note their gap
- `file_edit` — note the path (may overlap yours)
- `commit` — note the sha (may have advanced main past your rebase)
- `ALERT kind=lease_overlap` — **stop**: two sessions claim the same files
- `ALERT kind=silent_agent` — a live session stopped heartbeating; its work may be lost

---

### Self-heal when the queue is stuck (INFRA-010)

Sometimes `musher.sh --pick` surfaces only a single `effort: l` or
stale-premise gap for many retries in a row, because sibling PRs have
file-scope prefixes that preemptively mark most open gaps `conflict`. This
is over-cautious — the GitHub merge queue rebases each PR onto current
`main` and re-runs CI, so prefix-level false positives (e.g. an EVAL
docs-only gap blocked by an EVAL PR that only touches
`scripts/ab-harness/`) rarely materialise as real merge conflicts.

After **2 consecutive retries** in which `--pick` returns only a gap you
do not want to attempt (large-effort, stale premise, or outside your tool
scope), escape with:

```bash
scripts/musher.sh --pick --ignore-file-conflicts
```

This bypasses file-scope conflict detection and surfaces the highest-
priority *truly unclaimed* open gap. Lease collisions and dependency
blocks are still respected — only the coarse prefix heuristic is disabled.

If your gap has a known narrow file set (e.g. analysis-only writing only
to `docs/eval/`), declare `file_scope:` on its gaps.yaml entry so the
default `--pick` path works without the escape hatch:

```yaml
- id: EVAL-080
  title: Analysis-only re-score of existing JSONLs
  domain: eval
  file_scope: docs/eval/,docs/FINDINGS.md    # overrides DOMAIN_FILES default
  ...
```

`docs/gaps.yaml` is excluded from conflict detection globally — line-level
edits to disjoint gap blocks are rebasable.

### When to stop looping

- `musher.sh --pick --ignore-file-conflicts` returns nothing AND all gaps are
  blocked by dependencies AND no parallel-track work is available (see
  Autonomy section below)
- You hit an unresolvable merge conflict (rebase manually, then continue)
- A gap is marked `effort: XL` (musher never auto-assigns these — but you can SLICE
  XLs into shippable chunks; see Autonomy section)
- Jeff tells you to stop

---

### Replenishing the queue with gap-architect

If `musher.sh --pick` returns nothing across two 5-minute retries (genuine empty queue), you can refill the gap registry with new work:

```bash
python3.12 scripts/gap-architect.py --dry-run    # preview what would be added
python3.12 scripts/gap-architect.py               # generate + write + ship a PR
```

`gap-architect.py` calls Claude (claude-sonnet-4-6) with the latest strategic docs
(`RESEARCH_PLAN_2026Q3.md`, `RED_LETTER.md`, `FINDINGS.md`) to generate ~20 new
concrete gaps, deduplicates them against existing open gaps, assigns sequential
IDs, appends them to `docs/gaps.yaml`, and opens a PR.

Only run this when the queue is genuinely empty — generating gaps when work already
exists creates planning noise. It requires `ANTHROPIC_API_KEY` in the environment
or in `.env`. Use `--count N` to request a different number of gaps, `--no-ship` to
write to `docs/gaps.yaml` without opening a PR.

---

## Autonomy — push the limits when the queue stalls

The default loop is reactive: pick from the queue, do that, repeat. That's the
floor, not the ceiling. When `musher.sh --pick` returns nothing or the queue is
blocked on your own pending PRs, **the right move is not to sleep — it is to do
the highest-leverage work nobody is doing.** A wake that produces nothing is
wasted capacity.

### What you have permission to do without explicit human direction

These are pre-approved patterns. Use them when the queue is stalled or when
you have spare turn-budget after shipping a small gap:

1. **Proactive gap filing.** When you spot a real issue while reading code or
   docs (broken hook, stale TODO with a clear answer, dead code, dangling
   reference, methodology gap), file it as a small new gap entry in
   `docs/gaps.yaml` with concrete acceptance criteria and ship the entry.
   Don't wait for someone else to file it. **Reserve-then-file:** run
   `scripts/gap-reserve.sh <DOMAIN> "title"` to get the next ID and write
   `pending_new_gap` to your lease, add the `- id:` block to `docs/gaps.yaml`, then
   `gap-claim.sh` / `gap-preflight.sh` as usual — filing + implementation can ship
   in one PR. `gap-preflight.sh` refuses IDs that are neither on `main` nor
   reserved to your session. **Bootstrap escape hatch:** if you cannot run
   `gap-reserve.sh`, use `CHUMP_ALLOW_UNREGISTERED_GAP=1` on the tiny filing PR
   only (same as INFRA-020).

2. **Cross-validation.** Re-run a sibling agent's claim on the same data — fresh
   eyes can catch noise-floor artifacts, off-by-one errors, or judge bias the
   original author missed. Particularly valuable for any EVAL-XXX result that
   carries a NULL or PRELIMINARY label. Document findings in the source eval
   doc as an amendment.

3. **Parallel-track research.** While one PR is in CI you have free turn-budget.
   Use it on:
   - drafting publication content (PRODUCT-009 / future blog posts / ArXiv prep)
   - reading & summarising a paper that informs a roadmap gap
   - exploring a research-paper.md / FINDINGS.md update with a new angle
   - prototyping a small experiment that doesn't fit the gap registry yet

4. **XL gap decomposition.** Musher refuses to auto-assign XL gaps because they
   can't ship in one PR. But you can READ an XL gap, propose a decomposition into
   3-5 ≤M sub-gaps with explicit dependencies, file those sub-gaps, and let the
   next agent pick up the smallest. The XL gap stays open until the
   sub-gaps close.

5. **Code review of recently-merged PRs.** Pre-merge review by code-reviewer-agent
   is automated but not exhaustive. Spot-check the last 3-5 merged PRs in your
   domain for stale TODOs, missing test coverage, debug println, or
   over-permissive scope. File a follow-up gap if you find something.

6. **Tooling improvements.** Spotted friction in the gap workflow itself? File
   a small INFRA-* gap (or just ship the fix if it's <30 LOC and self-contained
   in scripts/). Examples: a missing flag on a script, a broken edge-case in
   gap-preflight, a doc reference that's gone stale.

7. **Self-improvement targets.** When you notice you keep making the same kind
   of error (wrong worktree, lease collision, formatting drift), file an entry
   in `chump_improvement_targets` (via `chump --memory ...` or direct DB
   insert) so future sessions inherit the lesson.

### What you still must NOT do without explicit direction

- **Touch COG-031.** Held at v9; explicit Jeff decision required.
- **Modify any gap that's claimed by another live session.** Always check
  `.chump-locks/*.json` first; if collision, work on something else.
- **Push to main.** Always work on `claude/<codename>` branches.
- **Reframe a research finding.** If you disagree with a sibling's
  interpretation, file an amendment — don't silently rewrite.
- **Spend more than ~$5 on cloud calls in a single turn** without explicit
  approval. The Together free tier is fine; Anthropic / OpenAI calls add up
  fast.
- **Skip pre-commit hooks via `--no-verify`** unless you've tried the
  documented bypass envs first and explained why in the commit message.

### The "10% capacity" anti-pattern

If your turn ends with "queue empty, scheduled wake, standing by" — and you
did nothing else — you used ~10% of your capacity. The Autonomy patterns above
exist to fill the other 90%. A wake-cycle that produces a draft, an audit
finding, a one-LOC fix, OR a small filed gap is a productive cycle even if it
didn't ship a "real" gap PR.

Concretely: in each turn, after the queue check, ask:

- Is there a P0 / P1 gap I filed earlier that I haven't started?
- Is there a sibling claim I could cross-validate cheaply?
- Is there a publication / doc gap I could push forward by 30%?
- Did I spot anything in the last hour worth filing?

If yes to any: do it. Then schedule wake. The wake chain stays alive
either way.

### Self-paced spend ceiling

You're trusted with up to roughly **$5 of cloud spend per autonomous loop
session** (Together + Anthropic combined) without asking. Track it loosely;
if a single sweep would exceed $2, prefer running it on Ollama
(qwen2.5:14b is the verified-working local backend per
docs/eval/EVAL-060-methodology-fix.md and the EVAL-064 sweep). Anything
likely to exceed $5 in one go: stop and ask.

---

*This doc is the only prompt you need. Pass it to any new agent to add it to the fleet.*

*The Autonomy section was added 2026-04-20 in response to a "we're using 10% of
our capacity" observation during a live session. Earlier versions of this doc
encoded the queue-only floor; the autonomy patterns above are the documented
ceiling.*
