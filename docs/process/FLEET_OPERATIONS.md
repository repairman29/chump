# Fleet Operations — Raise, Scale, Teardown, Troubleshoot

**Canonical entry point:** `scripts/dispatch/run-fleet.sh` (INFRA-203, INFRA-211)

A "fleet" is a set of N concurrent Claude Code agents, coordinated via `chump-local` or the Anthropic API, each picking and shipping high-priority gaps. This runbook covers the operator surface: launching fleets, adjusting scale/filters, tearing down, and diagnosing stalls.

---

## Quick start: raise a fleet

```bash
scripts/dispatch/run-fleet.sh                           # default: 8 agents, P0+P1, all domains
tmux attach -t chump-fleet                              # watch the panes (optional)
```

The script:
1. Spawns a tmux session `chump-fleet` with N+1 panes (one control + N workers)
2. Each worker loops: pick gap → claim → create worktree → `claude -p` → ship → release → repeat
3. The control pane streams `ambient.jsonl`, PR queue depth, and per-agent health
4. Default timeout per agent: 600 seconds (INFRA-371; raise via `FLEET_TIMEOUT_S`)

---

## Scaling: adjust fleet parameters

**Change the number of agents:**
```bash
FLEET_SIZE=4 scripts/dispatch/run-fleet.sh    # start 4-agent fleet (kill prior, if running)
FLEET_SIZE=16 scripts/dispatch/run-fleet.sh   # scale up to 16
FLEET_SIZE=0 scripts/dispatch/run-fleet.sh    # tear down (stop only, no new agents)
```

**Filter by priority and effort:**
```bash
FLEET_PRIORITY_FILTER="P0"                    # only P0 gaps
FLEET_EFFORT_FILTER="xs"                      # only extra-small (quick wins)
scripts/dispatch/run-fleet.sh
```

**Filter by domain:**
```bash
FLEET_DOMAIN_FILTER="INFRA"                   # only INFRA gaps
FLEET_DOMAIN_FILTER="INFRA,DOC"               # INFRA or DOC
scripts/dispatch/run-fleet.sh
```

**Assign domains per-agent (round-robin):**
```bash
FLEET_AGENT_DOMAINS="INFRA,EVAL,DOC"          # agent 1→INFRA, agent 2→EVAL, agent 3→DOC (wraps)
scripts/dispatch/run-fleet.sh
```

**Increase per-agent timeout** (for harder gaps):
```bash
FLEET_TIMEOUT_S=1800 scripts/dispatch/run-fleet.sh    # 30 min per agent (default 600s)
```

**Dry run** (print plan, don't start):
```bash
FLEET_DRY_RUN=1 scripts/dispatch/run-fleet.sh
```

---

## API credit & backend selection

**Cost guard (INFRA-420):** Default is `chump-local` (free Together tier). The `claude` backend (Anthropic API / claude-opus-4.7) is ~50× more expensive per token. Both paths are production-ready; pick based on workload and budget.

```bash
FLEET_BACKEND=chump-local scripts/dispatch/run-fleet.sh    # default: free tier, no ANTHROPIC_API_KEY needed
FLEET_BACKEND=claude scripts/dispatch/run-fleet.sh         # requires CHUMP_FLEET_ALLOW_CLAUDE_BACKEND=1
```

**API key sourcing (INFRA-351):** If `.env` exists in the repo root (e.g., `ANTHROPIC_API_KEY=sk-...`), `run-fleet.sh` auto-sources it so agents consume workspace API quota instead of your personal subscription cap. Bypass with `CHUMP_FLEET_NOENV=1` if needed.

```bash
cat .env | head -3                            # check which API keys are loaded
CHUMP_FLEET_NOENV=1 scripts/dispatch/run-fleet.sh        # skip .env sourcing
```

---

## Live monitoring: the control pane

Once the fleet is running, `tmux attach -t chump-fleet` shows:

1. **Ambient pane (top-left):** Tails `.chump-locks/ambient.jsonl` (events from all agents + concurrent sessions). Watch for:
   - `lease_overlap`: Two agents claimed the same gap (rare; indicates a lease-collision bug)
   - `silent_agent`: Agent claimed a gap but never shipped (wedged or crashed)
   - `fleet_starved`: Consecutive empty picks (filters too tight or queue empty)
   - `pr_stuck`: PR opened but never merged (merge-queue stuck)

2. **Queue pane (top-right):** Live PR queue depth + open PRs. A growing queue is normal during scale-up; a stable, non-zero queue means the fleet is catching up.

3. **Agents pane (bottom):** Per-agent lease files, worktree status, and branch heads. A healthy agent cycles through states: `PICKING` → `CLAIMED` → `SHIPPING` → idle.

**Single-shot snapshot** (no tmux):
```bash
scripts/dispatch/fleet-status.sh --once
```

**Per-pane snapshot:**
```bash
scripts/dispatch/fleet-status.sh --pane ambient   # just the events stream
scripts/dispatch/fleet-status.sh --pane queue     # PR queue only
scripts/dispatch/fleet-status.sh --pane agents    # per-agent state only
```

---

## Starvation & poll jitter

If you see `fleet_starved` events, the fleet is picking consecutive empty gaps. Root causes:

- **Filters too tight.** `FLEET_DOMAIN_FILTER=INFRA` with only 1 INFRA gap left will starve if a different agent claims it first.
  - **Diagnosis:** `scripts/dispatch/fleet-status.sh --pane starvation` shows last 24h starve events per filter combo.
  - **Fix:** Loosen `FLEET_DOMAIN_FILTER` or increase `FLEET_PRIORITY_FILTER` (`P0,P1,P2` instead of `P0,P1`).

- **Queue empty.** All gaps done (good news!).
  - **Check:** `chump gap list --status open` returns nothing.

- **Poll synchronization.** All N agents polled at the same instant, picked the same gap, and 3 hit "worktree create failed."
  - **How it's prevented:** Default ±30% jitter on pick intervals (CHUMP_POLL_JITTER).
  - **Symptom:** Spike of `worktree_create_failed` in ambient.jsonl at the same timestamp.

**Jitter control:**
```bash
CHUMP_POLL_JITTER=15 scripts/dispatch/run-fleet.sh      # reduce to 15% randomization
CHUMP_STARVE_THRESHOLD=5 scripts/dispatch/run-fleet.sh   # alert after 5 consecutive empty picks (default 3)
```

---

## Tear down: stop the fleet gracefully

**Option 1: graceful tmux kill**
```bash
tmux kill-session -t chump-fleet
```
Agents in-flight will finish their current gap (up to `FLEET_TIMEOUT_S`), then exit. Leases are auto-cleaned up.

**Option 2: the dedicated stop command**
```bash
FLEET_SIZE=0 scripts/dispatch/run-fleet.sh
```
Kills the session and removes all lease files.

**Option 3: Ctrl-C in a pane**
```bash
# Inside tmux: Ctrl-C stops that one agent's loop (others keep running).
# Ctrl-C in the control pane stops just the control loop (workers keep going).
```

**After teardown:** Check for orphaned worktrees and leases:
```bash
ls .chump-locks/*.json                         # should be empty or gone after 1 min
ls .chump/worktrees/*/                         # stale worktrees auto-cleaned hourly by scripts/ops/stale-worktree-reaper.sh
```

---

## Troubleshooting

### "Fleet_starved" constantly in ambient.jsonl

The fleet is picking empty gaps. See **Starvation & poll jitter** above. Check:
```bash
chump gap list --status open | head     # how many gaps left?
chump gap list --status open | wc -l    # count
```

If the queue is not empty, loosen your filters:
```bash
FLEET_PRIORITY_FILTER="P0,P1,P2" scripts/dispatch/run-fleet.sh
FLEET_DOMAIN_FILTER="" scripts/dispatch/run-fleet.sh        # all domains
```

### An agent never ships (silent_agent ALERT)

An agent claimed a gap 10+ minutes ago but never `bot-merge.sh`. The gap's worktree is probably running `claude -p` in a hung state. Check:
```bash
tmux list-panes -t chump-fleet -F "#{pane_index} #{pane_pid} #{pane_current_command}"   # find the agent's PID
ps -p <PID> -o pid,ppid,etime,state,comm      # inspect the process tree
```

**Hung Claude process (INFRA-275):** If `claude` is stuck at `_dyld_start` (macOS dynamic linker), the `syspolicyd` wedge is active:
```bash
scripts/dev/chump-binary-unwedge.sh                    # heal the wedged binary
CHUMP_DOCTOR_FORCE=1 scripts/dev/chump-binary-unwedge.sh          # skip probe, go straight to fix
```

After healing, terminate the hung agent's pane and the fleet loop will spawn a replacement worker.

### PR queue growing (not merging)

Opened PRs are not auto-merging. Check:
```bash
gh pr list --state open --search "author:me" --limit 5   # open PRs from fleet agents
gh pr checks <PR#>                                       # are CI checks passing?
```

If CI is failing:
- The PR has required checks that aren't passing yet (build, tests, lint).
- Auto-merge is armed (confirmed in the PR description: `auto-merge: enabled`), but the gate is holding.

**Manual fallback if auto-merge is stuck:**
```bash
gh pr merge <PR#> --auto --squash                        # re-arm for next passing CI run
```

See [`docs/process/CLAUDE_GOTCHAS.md` → "if auto-merge is stuck"](./CLAUDE_GOTCHAS.md) for the full recovery playbook.

### Ambient.jsonl is huge (multi-GB)

The stream grows ~4MB/day under fleet load. Rotation is not automatic; it will bloat over weeks.

**Manual rotation:**
```bash
mv .chump-locks/ambient.jsonl .chump-locks/ambient.jsonl.archive-$(date +%Y%m%d)
gzip .chump-locks/ambient.jsonl.archive-*
```

The stream resumes in a fresh `ambient.jsonl` after you kill and restart the fleet.

### "FLEET_BACKEND=claude" refused without opt-in

You tried to run the fleet on the Anthropic API without explicitly opting in:
```bash
# This is blocked for cost protection:
FLEET_BACKEND=claude scripts/dispatch/run-fleet.sh

# Unblock with:
CHUMP_FLEET_ALLOW_CLAUDE_BACKEND=1 FLEET_BACKEND=claude scripts/dispatch/run-fleet.sh
```

The cost guard exists because a full fleet session can burn $50–100 on the claude backend in a few hours (INFRA-420, documented 2026-05-02).

---

## Learned cliffs (operational gotchas)

1. **Default timeout is 600s, not 1800s (INFRA-371).** Most gaps ship quickly on a warm cargo cache. Longer timeouts just burn tokens on churning agents. If you see high churn, raise `FLEET_TIMEOUT_S=1800` only for the next run, then investigate why gaps are slow.

2. **API key sourcing can silently fail (INFRA-351).** If `.env` has your keys but a pane is still hitting subscription-cap limits, check that the file exists and `source` ran without errors in the launcher output.

3. **Worktree creation races under high pick throughput (INFRA-212).** When all 8 agents pick at the same instant, 3–4 often fail to create worktrees (filesystem concurrency). This is why poll jitter (±30%) is on by default. Don't disable it.

4. **Lease collision is rarer than you'd think but possible (INFRA-260).** Two agents can claim the same gap within the same second if the clock skew is bad. The second agent will fail `gap-claim.sh` and pick the next gap. You'll see a `lease_overlap` ALERT in ambient.jsonl.

5. **Fleet starvation is usually just a tight filter, not a queue-is-empty state.** Before you think the queue is done, check: `chump gap list --status open | wc -l`. Starvation often means "INFRA-only fleet with 0 INFRA gaps left, but 10 DOC gaps waiting."

6. **Ctrl-C in the control pane kills only the control loop, not the workers.** To stop the whole fleet, use `tmux kill-session -t chump-fleet` or `FLEET_SIZE=0 scripts/dispatch/run-fleet.sh`.

7. **Each fleet worker has its own lease file (`.chump-locks/<session_id>.json`).** They auto-expire after the session TTL (~5 min idle). If a worker crashes hard, its lease will auto-clean up; no manual intervention needed. The control pane watches the lease files to detect dead agents.

8. **Ambient rotation is manual today.** Set a cron job or monthly reminder if you run fleet frequently. The stream is durable (appended, not overwritten), so leaving it for 6 months isn't dangerous — just slow to tail.

---

## Monitoring during scale-up (first 5 minutes)

After you start the fleet:

1. **Check the control pane:** Is the queue pane showing PRs opened? Are agent leases appearing in the agents pane?
2. **Tail ambient.jsonl manually (if you don't have tmux):** `tail -f .chump-locks/ambient.jsonl | jq . 2>/dev/null || tail -f .chump-locks/ambient.jsonl`
3. **After 2 minutes, expect 3–5 PRs opened.** If nothing by minute 3, check:
   - Did a worker wedge? `scripts/dispatch/fleet-status.sh --once`
   - Are there gaps to pick? `chump gap list --status open`
   - Is the API key loaded? `env | grep -E ANTHROPIC|TOGETHER|OPENAI`
4. **After 5 minutes, the fleet should be cruising.** Workers loop every 30–120 seconds; you'll see steady ambient events and 1–2 new PRs every 2–3 min.

---

## Reference: full environment knobs

| Knob | Default | Effect |
|------|---------|--------|
| `FLEET_SIZE` | 8 | Number of agent panes |
| `FLEET_TIMEOUT_S` | 600 | Per-agent `claude -p` timeout (seconds) |
| `FLEET_PRIORITY_FILTER` | `P0,P1` | Comma-separated priorities to pick |
| `FLEET_DOMAIN_FILTER` | (all) | Comma-separated domains (e.g., `INFRA,DOC`) |
| `FLEET_AGENT_DOMAINS` | (all) | Assign domains round-robin to agents (overrides `FLEET_DOMAIN_FILTER`) |
| `FLEET_EFFORT_FILTER` | `xs,s,m` | Comma-separated effort sizes |
| `FLEET_SESSION` | `chump-fleet` | Tmux session name |
| `FLEET_LOG_DIR` | `/tmp/chump-fleet-<sid>` | Directory for per-agent logs |
| `FLEET_DRY_RUN` | 0 | If 1, print plan and exit |
| `FLEET_BACKEND` | `chump-local` | `chump-local` (free) or `claude` (Anthropic API, needs opt-in) |
| `CHUMP_POLL_JITTER` | 30 | Randomize poll intervals by ±N% |
| `CHUMP_STARVE_THRESHOLD` | 3 | Consecutive empty picks before `fleet_starved` ALERT |
| `FLEET_INLINE_BRIEFING` | 1 | Inline gap YAML in agent prompt (saves tokens) |
| `CHUMP_LESSONS_AT_SPAWN_N` | 0 | Include top-N lessons in prompt (off by default, saves tokens) |
| `CHUMP_AMBIENT_INSTALL_SKIP` | 1 | Skip ambient-hook install on each session (saves tokens) |
| `CHUMP_FLEET_NOENV` | 0 | If 1, skip sourcing `.env` (use your CLI's own API keys) |
| `CHUMP_FLEET_ALLOW_CLAUDE_BACKEND` | 0 | If 1, allow `FLEET_BACKEND=claude` |
| `CARGO_TARGET_DIR` | (default) | Shared Cargo target dir across worktrees (INFRA-210) |

---

## See also

- [`scripts/dispatch/run-fleet.sh`](../../scripts/dispatch/run-fleet.sh) — source code + detailed comments
- [`scripts/dispatch/fleet-status.sh`](../../scripts/dispatch/fleet-status.sh) — live monitoring pane renderer
- [`scripts/dispatch/worker.sh`](../../scripts/dispatch/worker.sh) — per-agent loop implementation
- [`docs/process/CLAUDE_GOTCHAS.md` → Fleet launcher](./CLAUDE_GOTCHAS.md#fleet-launcher-infra-203-canonical-entry-point) — deeper operational details (starvation, heartbeats, reaper integration)
- [`CLAUDE.md` → Fleet launcher](../../CLAUDE.md#fleet-launcher-one-line) — one-liner reference (hot overlay)
