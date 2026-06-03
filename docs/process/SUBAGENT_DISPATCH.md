# Subagent dispatch — shipping epilogue + briefing protocol

> **Filed in:** [META-025](../gaps/META-025.yaml) — measured 25-33% subagent
> self-ship rate this session against ~80% work-quality. Two bottlenecks:
> (1) ship-stage hand-off (fixed by the shipping epilogue below), and
> (2) clarifying-question hesitation (fixed by the no-clarifying-questions
> directive below). **Every subagent prompt must include both.**

## Dispatch defaults by model (META-069, 2026-05-23)

The orchestrator's job is to pick the right model for the work. Empirical
default after the 2026-05-23 session that found Opus-instance time was the
actual bottleneck:

| Role | Model | Use for |
|---|---|---|
| **Orchestrator** | Opus | Planning, synthesis, real-talk, architectural calls, reviewing subagent output, PR queue triage |
| **Per-gap implementer** | Sonnet | Single-gap implementation, smoke tests, the actual diff. Default for `xs`/`s`/`m` gaps |
| **Mechanical sweeper** | Haiku | Yaml regeneration, gap-status updates, gardening passes, batch fixups |

**Rule**: when an Opus instance picks an `xs` or `s` gap, the default move
is to dispatch a Sonnet subagent rather than hand-implement. Hand-implement
only when the work requires architectural judgment Sonnet won't have.

## Pre-push checklist (META-069, 2026-05-23 — paste into every Sonnet brief)

Today's session shipped ~6 PRs that failed deterministic CI gates on first
push (orphan event kinds, env-var coverage misses, malformed AC yaml, format
lints). Each round-trip costs 5-10 min of CI time. Every Sonnet brief should
include this checklist for the subagent to run **before** `git push`:

```
[ ] New event kinds in EVENT_REGISTRY.yaml? → grep YOUR diff for new
    `kind:` entries. For each, verify the emit site contains a literal
    `"X"` or `"X".to_string()` pattern the audit grep can detect.
    If your emit uses struct-field syntax (e.g.
    EmitArgs { kind: "X".to_string(), ...}), preemptively add to
    scripts/ci/event-registry-reserved.txt with a reason note.

[ ] New CHUMP_* env vars introduced? → grep your diff for
    `std::env::var("CHUMP_*")` or shell `${CHUMP_*}` usage. For each NEW
    var, append a documented entry under the gap header in
    scripts/ci/env-vars-internal.txt.

[ ] Any docs/gaps/*.yaml touched? → run:
      python3 -c "import yaml; yaml.safe_load(open('docs/gaps/<file>.yaml'))"
    If errors, the chump gap set --acceptance-criteria parser broke on
    a special char (especially '|'). Repair by hand. (See INFRA-1799 for
    the underlying fix to the gap-set parser.)

[ ] Any Usage:/--help strings added? → must be literal command names,
    not templated `{sub}` substitutions. Lint rejects templating.

[ ] `chump preflight` GREEN — fmt + clippy + check + event-registry-audit.
    Don't push without this.
```

5 checks, ~30 seconds total. Catches ~60-70% of today's deterministic failure
classes. As INFRA-1787 (env-var coverage), INFRA-1788 (docs-delta), INFRA-1790
(markdown intra-doc-links), and the rest of Opus #3's CI-gates inventory
follow-ups ship, this checklist gets gradually absorbed into `chump preflight`
proper and shrinks.

## The no-clarifying-questions directive (paste into every subagent prompt)

Add this as the **first section** of every subagent prompt, before the task
description:

```
## Execution contract (read before anything else)

- **No clarifying questions.** You have everything you need. If something is
  ambiguous, make the most reasonable call, note it in your final report, and
  keep moving. Do not stop to ask.
- **Auto-decide on ambiguous AC.** If an acceptance criterion is vague, apply
  the most conservative interpretation that still satisfies the letter of the
  criterion. Document your interpretation in one line; do not pause.
- **Scope is fixed.** Do not expand beyond the deliverables listed. Do not
  do adjacent cleanup, refactors, or "while I'm here" changes.
- **Ship or report BLOCKED.** Every session ends with either a PR number or
  a one-line BLOCKED reason. "I wasn't sure" is not a valid BLOCKED reason —
  make the call and ship.
```

This single addition is responsible for the majority of the expected ship-rate
improvement. The hesitation / clarifying-question mode is the most common
subagent failure pattern after ship-stage wedges.

---

## The 25%→80% problem

Across this session's 4 dispatched subagents, 1 self-shipped a PR and 3 wrote
complete work that stalled at `bot-merge.sh`. Across the historical
`chump_improvement_targets` dispatch telemetry, 33% shipped / 33% killed /
33% stalled. The work-quality of agents that produce IS high — 425-line
position docs, 460-line preregs, multi-file fixtures with schema validators.
The failure is at the ship-stage hand-off where `chump gap …` commands hang
or `bot-merge.sh` waits forever.

The single subagent that did self-ship (EVAL-094 → PR #909) was the one
whose briefing included explicit fall-back-to-manual-recovery instructions.
That's the canary. **Every subagent prompt should include the shipping
epilogue below.**

## The shipping epilogue (paste into every subagent prompt)

```
## Shipping (CRITICAL — read in full before ending)

```bash
# Canonical path:
scripts/coord/bot-merge.sh --gap <YOUR-GAP-ID> --auto-merge
```

**If `chump gap …` or `bot-merge.sh` hangs > 30s** (no output, no progress):

```bash
# Heal the wedged binary (INFRA-275). Idempotent; safe to run.
scripts/dev/chump-binary-unwedge.sh
```

> **STOP: wall-clock budget is `CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S` (default 900s = 15 min).**
> If `bot-merge.sh` has been running for 15 minutes with no progress markers
> (`▶ <stage> starting …` / `✓ <stage> done`), **do not wait** — execute
> manual recovery NOW. Passive waiting is what stalls subagents; the doctor
> + manual path are always faster than an indefinite hang.

### `bot-merge-graphql-wedge` (INFRA-1939, 2026-05-27)

If `bot-merge.sh` exits 144 with `WEDGE: bot-merge cannot proceed under
graphql_exhausted`, the GitHub GraphQL bucket is depleted. The script
detected a recent `kind=graphql_exhausted` ambient event and refused to
poll (pre-INFRA-1939 it would silently retry forever, burning 144K+
subagent tokens per stuck attempt).

**Do not retry bot-merge.** Fall through to the manual INFRA-028 path
below — it uses REST endpoints which have their own quota and stay
available during GraphQL exhaustion. The wedge clears automatically
when the GraphQL bucket replenishes (~1 hour).

Bypass (only when you've manually verified the bucket recovered):
`CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=1 bash scripts/coord/bot-merge.sh ...`

**If still hung after the doctor, OR if the 15-min wall-clock budget expires** —
fall back to manual recovery (INFRA-028 path):

```bash
# 1. Push your branch
CHUMP_GAP_CHECK=0 git push -u origin <your-branch> --force-with-lease

# 2. Open the PR by hand
gh pr create --base main --title "<title>" --body "<body>"

# 3. Arm auto-merge
gh pr merge <PR-number> --auto --squash

# 4. Close the gap in the canonical store (if your PR closes it)
chump gap ship <GAP-ID> --closed-pr <PR-number> --update-yaml
```

**If `chump gap` itself hangs** during step 4: the doctor again, or skip
step 4 — the closer-pr-batcher will catch up on the next cron run
(INFRA-219 / INFRA-307).

**Do NOT** silently fall back to writing `docs/gaps/<ID>.yaml` directly —
concurrent siblings each scanning the filesystem for "next free ID"
produce silent collisions (INFRA-301).

**Do NOT** use `git commit --no-verify` to bypass guards. Per-guard bypass
envs (`CHUMP_GAP_CHECK=0`, `CHUMP_CHECK_BUILD=0`, `CHUMP_RAW_YAML_EDIT=1` +
`RAW_YAML_REASON: <text>` trailer) are documented in CLAUDE.md and safe
when applicable.

**PRE-EXIT VERIFICATION (mandatory, INFRA-1953) — run as the LAST executable
step before composing the final report:**

```bash
# Asserts (a) branch on origin, (b) PR exists for branch, (c) auto-merge armed.
# Exits 0 on all-pass; non-zero with diagnostic and emits
# kind=subagent_idle_without_pr to ambient so the dispatcher sees the pattern.
bash scripts/dispatch/subagent-pre-exit-check.sh <YOUR-BRANCH>
```

If the check exits non-zero with `no PR for branch`, your work has **not
shipped** — execute the manual-recovery push+create+arm path above NOW.
**Do not return `status=completed` with `result="waiting for monitor"` or
similar — that is the half-ship failure mode INFRA-1953 was filed to catch
(observed twice on 2026-05-24: INFRA-1893 #2489 + INFRA-1935 #2536).**

If the check exits non-zero with `auto-merge not armed`, re-arm via GraphQL:
```bash
PR_ID=$(gh pr view <PR-N> --json id --jq .id)
gh api graphql -f query='mutation($prId:ID!){enablePullRequestAutoMerge(input:{pullRequestId:$prId,mergeMethod:SQUASH}){pullRequest{autoMergeRequest{mergeMethod}}}}' -F prId="$PR_ID"
```
The `gh pr merge --auto` CLI sometimes silent-fails (INFRA-1906); GraphQL is the reliable path.

**Final report format** — reply with this structure under 250 words:
```
PR number: #NNNN  (or "BLOCKED" + one-line reason)
Files changed: <count>
Tests added: <count or "none">
CI state at hand-off: <green / pending / failed-with-fix-noted>
Open TBDs: <bullet list, or "none">
Notes: <2-3 sentences on tricky calls or recovery paths used>
```
```

## What goes in the briefing BEFORE the epilogue

**`--briefing` now injects umbrella context automatically (INFRA-2165).** When a
gap depends on a META-NNN umbrella, `chump --briefing <GAP-ID>` prepends the
parent META title, full AC (truncated to 80 lines), and the last 5
integration-cycle ambient events before the rest of the briefing. Dispatch
prompts for META-124 sub-gaps no longer need a "read META-124 first" instruction
— the briefing injects it automatically.

### Rescue-class dispatches MUST cite the procedure (META-246, 2026-05-31)

When dispatching a Sonnet on a **rescue-class gap** (titles starting with "trunk-red rescue", "queue stuck", "fix(... allowlist", "rescue ...", "unblock ...", or any gap filed by the PR-shepherd daemon's `pr_action_taken action=file_followup_gap`), the brief **MUST**:

1. Cite the relevant §5 failure-surface pattern from [`docs/process/PR_RESCUE_PROCEDURE.md`](./PR_RESCUE_PROCEDURE.md): "Match §5.X pattern — fix in `<canonical-file>` per that section's prescription."
2. Cite the relevant §6 cascade-impact row: "After this lands, expect §6.X cascade — trigger rebase wave / rerun wave / wait-for-CI per that row."
3. Reject scope expansion explicitly: "Do NOT also fix sibling §5.Y patterns; one rescue per PR."

This prevents the Sonnet from inventing a new rescue approach for a pattern we've already solved. Every Sonnet brief for rescue work needs explicit §5 + §6 citations.

The shipping epilogue is the LAST section of the prompt. Structure in order:

1. **No-clarifying-questions directive** (above) — verbatim, first thing.
2. **What you're building** — one paragraph, the deliverable named.
3. **Read first (in order)** — explicit file paths the agent should load
   before writing. Don't paste content; tell them what to read.
4. **The contract** — what the deliverable MUST contain (acceptance
   criteria from the gap, schema fields, success criteria).
5. **What you must NOT do** — concrete forbiddances (don't expand scope,
   don't bypass guards, don't hand-edit per-file YAMLs).
6. **The shipping epilogue** (above) — verbatim, no edits.

## Model default — always use sonnet (INFRA-515)

Fleet workers default to `FLEET_MODEL=sonnet` since 2026-05-06 (INFRA-515).
**Do not dispatch subagents on haiku.** Haiku asks clarifying questions instead
of acting, and in `--dangerously-skip-permissions` mode there is nobody to
answer — the agent sits idle for 600 s and is killed. Sonnet ships on the
first attempt; haiku ships 1-in-9. The cost differential is real but the
throughput differential is larger.

When calling the `Agent` tool manually, omit `model:` (inherits the session
default, which is sonnet for fleet sessions) or explicitly pass `"model": "sonnet"`.

## Write-ahead log — protect edits from /tmp reap (INFRA-1200)

Worktrees live in `/tmp`, which macOS can reap without warning. Before writing
any file, subagents **should** wrap the write through `chump-edit-wrap.sh` so
the new content is persisted to the stable main-repo tree first. If the
worktree is reaped, `chump-edit-replay.sh` re-applies all patches to a fresh
worktree in seconds.

```bash
# Before: write directly (unsafe — /tmp reap loses work)
cat new-content.txt > /private/tmp/chump-INFRA-NNN/src/foo.rs

# After: wrap through the WAL (safe)
cat new-content.txt | \
  CHUMP_WORKTREE_ROOT=/private/tmp/chump-INFRA-NNN \
  scripts/coord/chump-edit-wrap.sh INFRA-NNN \
  /private/tmp/chump-INFRA-NNN/src/foo.rs
```

Recovery after `/tmp` reap:

```bash
# Fresh worktree already created (e.g. via chump claim --resume)
scripts/coord/chump-edit-replay.sh INFRA-NNN /private/tmp/chump-INFRA-NNN
```

Patches are stored in `.chump-plans/<GAP-ID>/` in the main repo. They are
cleaned up automatically 7 days after the gap ships.

## Timeout rescue path — find WIP on the branch (INFRA-525)

`worker.sh` now installs a `SIGALRM` trap at `FLEET_TIMEOUT_S − 30 s`. If an
agent is killed by the fleet timeout, it first runs:

```bash
git add -A && git commit -m "WIP-<gap>: timeout-rescue" && git push -u origin <branch>
```

The work is on the remote branch even if the agent never reached `bot-merge.sh`.
Recovery:

```bash
git fetch origin
git checkout <branch>         # branch name is in the gap's lease JSON
# inspect, finish, and ship normally
scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

If the branch is missing entirely, the agent was killed before the trap fired
(rare — only possible if `SIGKILL` was used instead of `SIGTERM/SIGALRM`).
In that case, the work is lost; re-claim and re-implement.

## Anti-patterns observed

These are real failure modes from this session, not theoretical:

- **Subagent asks clarifying questions instead of shipping.** The prompt
  ends there — the operator never sees the work. Fixed by the
  no-clarifying-questions directive at the top of every prompt. Root cause:
  default model behavior optimizes for safety-via-confirmation; fleet
  subagents must be pre-authorized to make judgment calls.
- **Subagent pauses on ambiguous AC instead of making a call.** Often
  accompanied by "I need more context" or "could you clarify". The
  auto-decide rule (most conservative interpretation + document it) closes
  this. If the call turns out wrong, the gap is re-opened — cheaper than
  a stalled agent.
- **Subagent writes prereg, commits locally, never pushes.** Fixed by the
  epilogue's manual-recovery section.
- **Operator uses `Agent` tool to "check status" of an existing subagent
  instead of `SendMessage`.** Spawns a fresh agent with no context;
  wastes a slot. (See [DOC-015](../gaps/DOC-015.yaml).)
- **Multiple subagents claim same gap because lease lookups failed.**
  Mitigated by `gap-claim.sh` running before any work; subagents must
  preflight.
- **Subagent silently falls back to direct YAML write when `chump gap
  reserve` hangs.** Caught by [INFRA-301](../gaps/INFRA-301.yaml)'s
  trace-log instrumentation; remediated by the chump-doctor heal path
  in [INFRA-275](../gaps/INFRA-275.yaml).

## Re-measurement contract

[META-025](../gaps/META-025.yaml) commits to remeasuring after this
template lands: N=5 fresh subagent dispatches, self-ship rate target
≥ 70% (vs 25% baseline). Two changes are being tracked together:
(1) shipping epilogue (already in use since META-025), and
(2) no-clarifying-questions directive (added in COG-053).
If the rate still doesn't improve, the bottleneck has shifted — file a new
gap with the observed failure taxonomy rather than patching this doc further.

## Model defaults (post INFRA-515)

Fleet workers default to **`sonnet`** (`FLEET_MODEL=sonnet`). This replaced
the earlier `haiku` default — haiku's tendency to ask clarifying questions
instead of making judgment calls was the dominant source of dispatch waste.

| Context | Default model | Override |
|---|---|---|
| Fleet workers (`run-fleet.sh`) | `sonnet` | `FLEET_MODEL=haiku` to cut cost |
| IDE / interactive sessions | `haiku` | — |
| Curator / PM runs | `opus` | `CHUMP_CURATOR_MODEL=sonnet` |

Cost-sensitive sweeps: `FLEET_MODEL=haiku scripts/dispatch/run-fleet.sh`.
Opus is ~50× haiku per token — reserve for structured PM reasoning (gap
prioritization, pillar rebalancing) where reasoning quality matters.

## Timeout-checkpoint and WIP-rescue (post INFRA-525)

When `claude -p` approaches `FLEET_TIMEOUT_S`, worker.sh commits any
in-progress edits and pushes the branch before killing the process:

```
WIP-<GAP-ID>: timeout-rescue checkpoint (INFRA-525)
```

The worker emits `kind=fleet_timeout_checkpoint` (ALERT level) to
`ambient.jsonl`. Watch for it with:

```bash
tail -f .chump-locks/ambient.jsonl | grep fleet_timeout_checkpoint
```

**Operator recovery from a WIP checkpoint:**

```bash
# 1. Find the WIP branch (check ambient.jsonl or gh pr list)
git fetch origin
git checkout chump/<gap-id>-claim

# 2. Review partial work, continue the implementation

# 3. Ship normally once complete
scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

If no PR exists yet for the branch:
```bash
gh pr create --head chump/<gap-id>-claim --base main --title "<title>"
gh pr merge <N> --auto --squash
```

Opt-out of WIP checkpoints: `CHUMP_WIP_CHECKPOINT=0` — work is lost on
timeout if set (useful for short-lived test workers only).

## RESILIENT-060: Pre-dispatch guardrail (A2A L6c)

**Orchestrators MUST run `agent-dispatch-guardrail.sh` BEFORE invoking the
Agent tool.** If it exits non-zero, the dispatch must NOT proceed.

### Why it exists

Three incidents on 2026-06-03 where dispatched Sonnet agents wrote files
outside their lease paths — caught only by the post-hoc git pre-commit hook,
after the work was already done:

1. RESILIENT-058 Sonnet rewrote `src/atomic_claim.rs` via stale-base rebase,
   nearly rescinding INFRA-2524's fail-OPEN guard.
2. INFRA-2565 Sonnet edited 5 files outside lease paths including
   `.github/workflows/ci.yml`.
3. RESILIENT-059 Sonnet ran `cargo test --lib` on a binary-only crate,
   wasting 30 min on 6 false failures.

The post-hoc hook (pre-commit) catches violations after the work is done.
This guardrail catches them **before** the Agent tool fires.

### Usage

```bash
# Run BEFORE every `Agent` tool call:
bash scripts/coord/agent-dispatch-guardrail.sh <gap-id> <comma-separated-paths>
```

Exit 0 = all invariants pass — proceed with dispatch.
Exit 1 = BLOCKED — do not dispatch. Read stderr for the specific violation.

### What it checks

1. **Lease path coverage** — every path the agent plans to write must be in
   `claim.paths` of the active lease for `<gap-id>`. Always-allowed paths
   (`.chump/state.sql`, `docs/gaps/*`, `.gitignore`) are exempt.
2. **Branch / gap-id alignment** — current branch must start with
   `chump/<gap-id-lower>` (e.g. gap `INFRA-2674` → branch must begin with
   `chump/infra-2674`).
3. **cargo fmt pre-check** — if any proposed path ends in `.rs`, runs
   `cargo fmt --all -- --check` on the worktree before allowing dispatch.
   A dirty worktree means the agent would inherit a lint failure it didn't
   cause.

### When the guardrail blocks

**Do not bypass.** The correct responses are:

- **Out-of-lease path**: expand the lease by re-claiming with `--paths`
  including the additional file, then re-run the guardrail.
- **Branch mismatch**: confirm you are on the correct branch for the gap.
  If the worktree is on the wrong branch, switch before dispatching.
- **No active lease**: run `chump claim <gap-id>` to establish a lease first.
- **fmt dirty**: run `cargo fmt --all` in the worktree, commit, then
  re-run the guardrail.

There is no bypass env var. The escape valve is fixing the underlying
invariant violation, not skipping the check.

### Emitted events

- `agent_dispatch_guardrail_passed` → dispatch may proceed
- `agent_dispatch_guardrail_blocked` → dispatch refused; see `reason` field

Both events carry `{gap_id, branch, attempted_paths, leased_paths, reason}`
and are consumed by `ops-audit` and `fleet-brief`.

### Integration point in the dispatch flow

```
1. Orchestrator selects gap + determines write paths for Sonnet brief
2. → bash scripts/coord/agent-dispatch-guardrail.sh <gap-id> <paths>
3.   rc=0 → invoke Agent tool with the brief
3.   rc=1 → STOP; fix the invariant; re-run guardrail; then dispatch
```

---

## See also

- [META-025](../gaps/META-025.yaml) — parent gap, dispatch-quality findings
- [INFRA-275](../gaps/INFRA-275.yaml) — the syspolicyd binary wedge that
  causes most ship-stage hangs
- [INFRA-301](../gaps/INFRA-301.yaml) — gap-reserve.sh tripwire
- [DOC-015](../gaps/DOC-015.yaml) — Agent vs SendMessage discipline
- [INFRA-333..337](../gaps/) — sibling improvements (pre-flight,
  heartbeat, telemetry report, stall taxonomy, scope enforcement)
- [COG-053](../gaps/COG-053.yaml) — no-clarifying-questions directive +
  auto-decide rule (the parallel fix to INFRA-515's sonnet default)
- [INFRA-515](../gaps/INFRA-515.yaml) — fleet-model default flipped from
  haiku to sonnet; haiku's clarifying-question hesitation kills throughput
- [INFRA-525](../gaps/INFRA-525.yaml) — worker.sh WIP-rescue checkpoint:
  work is committed + pushed at T-30s before fleet timeout
- [CLAUDE.md](../../CLAUDE.md) "Spawning subagents" subsection (added
  with this PR)

## Detecting hung subagents (META-116, 2026-05-27)

When a dispatched Agent appears abandoned, **DO NOT take over until you've ruled out a hung child process**. Today's session had 2 false-positive "Sonnet abandoned" diagnoses where the actual cause was a hung pre-commit hook child of the Sonnet's `git commit` call — killing the hook PID unblocked Sonnet's own commit + completed normally; the shepherd-takeover was duplicate work.

### Symptom

- Agent task notification not received after expected duration (5+ min past typical completion)
- Lease released (`.chump-locks/claim-<gap>-*.json` gone)
- Worktree contains recent file-mtime changes (Sonnet built code) but no commit OR no PR
- No explicit BLOCKED report from the agent

### Diagnosis (run BEFORE taking over)

```bash
ps aux | grep -E 'git.commit|pre-commit' | grep -v grep
```

If you see ANY git-commit or pre-commit children that have been running >2min, **the agent is not abandoned — it's blocked on a hung hook**.

### Remediation

1. Kill the hung hook process: `kill -9 <pid>`. The agent's own `git commit` call unblocks.
2. The agent completes normally on its own (commit → push → PR → arm auto-merge → completion notification).
3. **You don't need to take over.** Wait for the now-unblocked agent's completion notification.

### Bypass discipline

Shepherd-takeover IS appropriate when:

- Agent task notification arrived with `BLOCKED` status (explicit failure)
- Agent crashed without sending notification AFTER N hours (genuine death)
- No hung children visible in `ps aux` (rules out the hook-hang class)

In those cases, take over via:

1. Run scoped preflight on the worktree (`cargo fmt --package X --check && cargo clippy --package X --all-targets -- -D warnings && cargo test --package X --lib`)
2. If GREEN, amend the agent's existing commit with a real INFRA-NNNN message + push
3. If RED, fix the small drift + commit + push
4. Open PR + arm auto-merge + emit `operator_recovery_requested` if workspace-wide drift expected

### Real-world precedent (2026-05-27)

- **INFRA-2000 dispatch**: Sonnet's commit hung on pre-commit for 5+ min; shepherd assumed abandoned + tried takeover (which also hung); shepherd killed both hook PIDs at 14:56Z → Sonnet's blocked commit unblocked + completed normally (commit `e7300f5af`); shepherd takeover work was duplicate.
- **INFRA-2053 first dispatch**: Sonnet hit "API Error: Overloaded" after only 1-line `lib.rs` edit. **Different failure class** — not a hung hook; API rate-limit. Diagnosis: `ps aux` showed no hung children. Correct remediation: re-dispatch fresh Sonnet (which completed cleanly).

### Operational check (META-116 ships)

Run `bash scripts/coord/dispatch-health-check.sh` to scan ps aux for hung commit children + emit `kind=dispatch_hung_hook_detected` if found. Workers and shepherd loops can wire this into their session-start preamble.

## See also

- [META-116](../gaps/META-116.yaml) — this addendum's source gap
- [`scripts/coord/dispatch-health-check.sh`](../../scripts/coord/dispatch-health-check.sh) — the operational tool

## No-operator-escalation (extends no-clarifying-questions)

The no-clarifying-questions discipline (sub-agents do NOT ask the dispatcher to clarify) now extends to no-operator-escalation (sub-agents do NOT escalate to the operator from within their PR). 

**Canonical rule:** [`AGENTS.md` → No-operator-escalation discipline](../../AGENTS.md#no-operator-escalation-discipline-operator-decision-of-record-2026-05-30).

When a sub-agent encounters a decision that isn't trivially its own:
- Conservative default + ship — note the judgment call in the commit body
- If the conservative default isn't obvious, broadcast `FEEDBACK kind=proposal` via `scripts/coord/broadcast.sh` from within the PR, then wait for consensus_resolved
- If neither works AND it's not a T1-T4 trigger, broadcast `STUCK` with the exact ambiguity and HALT the PR — do NOT ping the operator

The 4 legitimate operator-escalation triggers (T1 irreversible / T2 cred-rotation / T3 operator-domain / T4 halt-class) apply to sub-agents too.
