# Investigate-and-report Sonnet template (INFRA-2357 / META-269)

> **The meta-question's answer.** When the operator's META-monitor fires
> `daemon_silent`, `queue_stagnant`, or any other "something is off" signal,
> the **first** autonomous response should be **investigate**, not **fix**.
> Investigate first — fix only after diagnosis confirmed.

## Why this exists

META-269 framing: "I just keep asking myself why we don't know something
is 'off-track' and then make an agent go figure it out. Why is that hard?"

The fleet has two existing Sonnet dispatch paths:

1. **`docs/process/SUBAGENT_DISPATCH.md`** — the **fix-and-ship** template.
   Sonnet picks a gap, edits files, commits, pushes, opens PR. Has a
   shipping epilogue + pre-push checklist. This is for **known work**.

2. **(new — this doc)** — the **investigate-and-report** template.
   Sonnet reads code/state/events to diagnose a question, writes a markdown
   report, returns. **DOES NOT** modify files, **DOES NOT** claim gaps,
   **DOES NOT** push. This is for **unknown diagnosis**.

When a META-monitor surfaces a "something is off" signal, the autonomous
response is path (2), not path (1). Fix-Sonnets called prematurely
amplify mis-diagnosis into a bad PR; investigate-Sonnets surface evidence
so the operator (or a downstream fix-Sonnet) can act with grounded
context.

## Required sections in every investigate brief

When dispatching, the brief sent to Sonnet **must** include all 4 sections:

### 1. SCOPE — what to look at

Explicit, narrow. Cite directory paths, ambient kind names, gap IDs,
PR numbers. Bad: "investigate the fleet". Good: "investigate why
`com.chump.fix-trunk-dispatcher` emitted 0 `fix_trunk_dispatched`
events in `.chump-locks/ambient.jsonl` between 2026-05-30 and
2026-06-01 despite trunk being RED on 4 PRs (cite PR#s)".

### 2. DURATION — max wall-clock

Cap. Default 15 min. Investigate-Sonnets without a cap will explore
indefinitely. Pattern:
```
DURATION: max 15 min wall-clock. If you have not completed all
required checks within 15 min, stop and write what you found so far.
```

### 3. OUTPUT — markdown report path + structure

Specify the report path and the section structure. Default path:
`docs/investigations/<topic-slug>-<UTC-timestamp>.md`.

Required structure:
```markdown
# Investigation: <topic>

**Dispatched:** <UTC timestamp>
**Wall clock:** <actual minutes used>

## Question
<copy SCOPE verbatim>

## Method
- File N: read, found X
- Command N: ran, returned Y
- Cross-ref N: compared A vs B

## Findings
<bullet list — most-load-bearing observation first>

## Diagnosis
<one paragraph: what the data says is happening>

## Recommended next action
- [ ] Specific fix-class action (e.g. "file gap to remove unused expectation row")
- [ ] OR specific further-investigation question
- [ ] OR "no action needed — false alarm" (acceptable!)
```

### 4. CONSTRAINTS — what NOT to do

The hard guardrails. Verbatim:
```
CONSTRAINTS (HARD):
- DO NOT modify any file outside the report path.
- DO NOT run `chump gap reserve`, `chump claim`, or any chump CLI that mutates state.db.
- DO NOT run `git commit`, `git push`, `gh pr create`, or any state-changing git command.
- DO NOT run `launchctl bootout`, `launchctl bootstrap`, or any daemon control command.
- You MAY read any file. You MAY run any read-only shell command.
- If you observe a critical bug that needs immediate action, write it in the report's
  "Recommended next action" section. DO NOT act on it yourself.
```

## How to dispatch

Call `scripts/dispatch/investigate-agent.sh <topic-slug> [report-path]`:

```bash
bash scripts/dispatch/investigate-agent.sh fix-trunk-dispatcher-silent
# → writes docs/investigations/fix-trunk-dispatcher-silent-<UTC>.md
```

The dispatch script:
1. Validates the topic slug (alpha+dash only).
2. Generates the report path and emits `kind=investigate_dispatched` to ambient.
3. Sets `CHUMP_INVESTIGATE_NO_WRITE=1` and `CHUMP_INVESTIGATE_REPORT_PATH=<path>`.
4. Either: (a) spawns `claude -p` with the full brief when auth + budget OK, OR
   (b) writes a signal file at `.chump-locks/investigate-pending-<slug>.json`
   for SessionStart-pickup per INFRA-2341 (subprocess-auth pivot).
5. Returns the report path so the caller can wait/poll.

## How META-monitors should use this

Any monitor that emits a "something is off" signal **should** dispatch
an investigate-Sonnet rather than directly file a fix gap. The investigate
report informs the gap-file decision.

Examples:

| Signal | Investigate-Sonnet topic | Report path |
|--------|------------------------|-------------|
| `daemon_silent daemon=X` | `daemon-silent-X` | `docs/investigations/daemon-silent-X-<ts>.md` |
| `queue_stagnant pickable=N` | `queue-stagnant` | `docs/investigations/queue-stagnant-<ts>.md` |
| `pr_stuck pr=N` | `pr-stuck-N` | `docs/investigations/pr-stuck-N-<ts>.md` |
| `graphql_exhausted` | `graphql-exhausted` | `docs/investigations/graphql-exhausted-<ts>.md` |

Sibling rule: **fix-Sonnet is dispatched only after** the investigate
report's "Recommended next action" calls for a specific fix-class action.
This is the meta-question's answer at the protocol level — we don't
fire-and-forget fix-Sonnets at uncertain signals.

## Example brief

```text
ROLE: investigate-and-report-Sonnet (INFRA-2357)

SCOPE: Investigate why `com.chump.fix-trunk-dispatcher` emitted 0
`fix_trunk_dispatched` events in `.chump-locks/ambient.jsonl` over the
last 24h, despite trunk being RED on PRs #2925, #2926, #2927, #2928.
Specifically check:
- Is the daemon LOADED? (launchctl list output)
- Is the dispatcher script executable + parseable? (ls + bash -n)
- Does the dispatcher script's path-filter exclude valid fix-trunk gaps?
- Are there any errors in /tmp/chump-fix-trunk-dispatcher.err.log?

DURATION: max 15 min wall-clock. Stop and write findings even if incomplete.

OUTPUT: write to /Users/jeffadkins/Projects/Chump/docs/investigations/fix-trunk-dispatcher-silent-20260601T060000Z.md
using the structure from docs/process/INVESTIGATE_AGENT_TEMPLATE.md.

CONSTRAINTS (HARD):
- DO NOT modify any file outside the report path.
- DO NOT run chump CLI that mutates state.db.
- DO NOT run git commit/push/PR.
- DO NOT run launchctl mutate commands.
- You MAY read any file. You MAY run any read-only shell command.
- If you find a critical bug, write it in "Recommended next action".
  DO NOT act on it.

Begin investigation. End with the report file written.
```

## Audit trail

Every dispatch emits `kind=investigate_dispatched` with `topic`,
`report_path`, `dispatched_at`. Every completion emits
`kind=investigate_completed` with the same `topic` + `report_path` +
`wall_clock_seconds`. Operator can audit dispatch frequency + report
existence via:

```bash
grep '"kind":"investigate_dispatched"' .chump-locks/ambient.jsonl | tail -20
ls -la docs/investigations/ | tail -20
```

## Anti-pattern: dispatching fix-Sonnet on uncertain signals

Operator-paged 2026-05-30T09:27Z (per CLAUDE.md anti-pattern #9 style
note in OPERATOR_PLAYBOOK.md): firing fix-Sonnets on raw alerts without
investigation amplifies false positives into bad PRs. The fleet shipped
INFRA-1575 and INFRA-238 as "feature X missing" gaps that were
mis-diagnoses (feature had shipped, the checkout was stale).

If the signal is high-cardinality (5+ similar firings in 1h),
**throttle to investigate first**, then bundle the findings into a
single fix gap or a single advisory report.

## See also

- `docs/process/SUBAGENT_DISPATCH.md` — fix-and-ship Sonnet template
- `docs/process/FRESHNESS_DISCIPLINE.md` — pre-investigation verification rules
- `docs/process/OPERATOR_PLAYBOOK.md` — anti-patterns including #9
- `scripts/dispatch/investigate-agent.sh` — dispatch entry point
- `scripts/ci/test-investigate-agent.sh` — smoke test
