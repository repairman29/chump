# Shepherd loop playbook (META-085 Phase 0)

> Filed 2026-05-23 by `curator-opus-shepherd-2026-05-23` after a 28-cycle drive.
> Phase 0 of [META-085](../gaps/META-085.yaml) — captures the convention layer
> so the next operator/curator inherits the patterns without rediscovering them.
> Phases 1-3 (mechanical wrappers + auto-allowlist daemon + `chump gap ship-orphan`)
> remain in META-085 as sub-gaps.

## Role: PR shepherd

A shepherd curator runs an Opus session that:
- Watches the open PR queue for new failures
- Diagnoses the root cause when multiple PRs share a failure signature (cluster)
- Posts structured comments on PRs they diagnose-but-don't-fix
- **Optionally** pushes the fix where the owning session is stalled

Cadence: 2-minute cron loop is the working default. Reactive-to-event would
be better (see META-085 follow-up).

## Pattern 0 — A2A first; GitHub comment is fallback (INFRA-1932)

**When you diagnose a PR you don't fix yourself**, the first action is
**broadcast an A2A message to the lane owner** — *not* post a GitHub
comment. GitHub comments are durable + public; A2A is fast +
peer-to-peer + builds a coordination graph the operator can audit.

```bash
# Default: A2A peer broadcast first
export CHUMP_SESSION_ID="curator-opus-shepherd-YYYY-MM-DD"
bash scripts/coord/broadcast.sh --to <lane-owner-session> WARN \
  "Real <gate-name> fix needed on #<PR> <GAP-ID>. Failure: <kind>=<value>. Fix recipe: <1-3 lines>. <2min mechanical. — Opus shepherd"

# Fallback ONLY if no A2A reply within 1 cycle (5min): post GH comment
gh pr comment <PR> --body "..."
```

**Why A2A beats GH comment as default:**
- Peer sees it inside their existing inbox loop (0 context-switch)
- Operator can audit "agent X notified agent Y at HH:MM" via ambient stream
- Reply gives sender feedback the channel works (validated 2026-05-24:
  wizard fixed #2497 in <5min from A2A diagnosis broadcast)

**Who to address** (heuristic):
- Failure on a CI gate → `curator-opus-ci-audit-YYYY-MM-DD`
- Failure on a META-070 Tier-C preflight gate → `curator-opus-target-YYYY-MM-DD`
- Failure on a docs/markdown link → `curator-opus-md-links-YYYY-MM-DD`
- Cross-PR cascade or keystone candidate → `orchestrator-opus-YYYY-MM-DD`
- Operator-level decision (pause daemon, hand-merge) → `chump-Chump-<operator-id>`

If you guess wrong, no bounce-back — but the message lands in *someone's*
inbox and the right peer can re-route. Better than no signal.

**Pattern 0 retires the old "diagnose-but-don't-fix" default of posting
a GH comment first.** The GH comment is now the *fallback* for when A2A
goes silent (>1 cycle = 5min no reply).

## Pattern 1 — Always check leases before any push

Before any commit + push (yours or rescue), grep active leases for path overlap:

```bash
ls .chump-locks/claim-*.json 2>/dev/null | xargs jq -r '.gap_id + " " + (.paths|tostring)'
```

The `SessionStart` hook digest surfaces this automatically — read it BEFORE
acting. Skip work that overlaps any active sibling lease.

## Pattern 2 — Batch cluster rescues in ONE loop

When N PRs share a failure signature (most common: `audit` step 110 EVENT_REGISTRY
coverage drift), rescue them as a batch, not as N separate sessions:

```bash
for entry in "PR1:branch1:new-kind-1" "PR2:branch2:new-kind-2"; do
    pr="${entry%%:*}"
    rest="${entry#*:}"
    branch="${rest%%:*}"
    kind="${rest#*:}"
    # ... worktree + append + push pattern (see Pattern 3)
done
```

**Pre-batch step**: find the kinds first via PR diff (3 syntaxes exist —
shell `printf`, Rust `EmitArgs { kind: "..." }`, and `EVENT_REGISTRY.yaml`
blocks). Single-syntax grep misses ~⅓ of cases.

## Pattern 3 — `-X theirs + re-append` for hotspot-file rebases

When rebase conflicts on a heavy-additive file like
`scripts/ci/event-registry-reserved.txt`, **don't manually resolve**.
Use the merge-strategy + re-append pattern:

```bash
git -c user.email=jeffadkins1@gmail.com -c user.name="Jeff Adkins" \
    rebase -X theirs origin/main
# main's version wins; my allowlist line(s) get dropped
echo 'my_new_kind  # reason: <gap-id> — emit site' >> scripts/ci/event-registry-reserved.txt
git add scripts/ci/event-registry-reserved.txt
git commit --amend --no-edit
CHUMP_OPERATOR_RECOVERY=1 git push --force-with-lease origin "HEAD:<branch>"
```

**Why `-X theirs` works** here: the conflict is purely additive on both sides
(every PR adds different lines at end-of-file). Taking main's version + re-adding
my line is the SAFE answer; manual three-way merge wastes cycles.

**Hotspot files in this repo** (touch with care; serialize rescues if possible):
- `scripts/ci/event-registry-reserved.txt`
- `.github/workflows/ci.yml`
- `Cargo.lock`
- `src/main.rs`
- `web/v2/app.js`

The 5 above all have custom merge drivers (`ci-yml-add-row`, `rust-main-append`,
`cargo-toml-append`, `js-append`) in `.gitattributes`. Local rebase activates
them; `gh pr update-branch` does NOT (it's server-side).

## Pattern 4 — Structured shepherd comments with "X-of-Y" cluster context

Every diagnose-but-don't-fix comment should be signed and linked to siblings:

```markdown
**Opus (PR shepherd loop, session-anchored) — diagnosis**

Audit step 110 EVENT_REGISTRY coverage fail because <reason>.

**Fix pattern (same as #2438/#2436 shepherd rescues earlier in cluster):**
1. <concrete step>
2. <concrete step>

**Cluster context**: N open PRs share this exact failure right now
(#XXXX #XXXX #XXXX) — same root, each needs its own per-PR fix.
```

Future operators arriving cold pick up much faster when they see the cluster
membership in every comment.

## Pattern 5 — Skip bot-merge, use manual ship path

`scripts/coord/bot-merge.sh --gap <id> --auto-merge` hits the
[INFRA-1532](../gaps/INFRA-1532.yaml) double-instance bug reliably enough that
manual is the new default for shepherd-class shipments:

```bash
CHUMP_OPERATOR_RECOVERY=1 git push -u origin <branch>
gh pr create --base main --head <branch> --title "..." --body "..."
gh pr merge <PR> --auto --squash
```

Total: ~10 seconds and predictable. bot-merge is ~3-15 minutes with a coin-flip
on whether it hangs.

When INFRA-1532 ships (bot-merge self-watchdog + single-instance lock), revisit.

## Pattern 6 — Heartbeat orchestrator every 4 cycles

In a 2-min loop that's 8 min. Avoids two failure modes:
- Orchestrator reroutes work because they think you're dead
- Orchestrator can't see what's shipping in real-time

Status ping template:

```
[curator-opus-<role>] cycle-N heartbeat. SHIPPED: <list of PRs merged or armed>.
IN PROGRESS: <current claim + ETA>. BLOCKERS: <if any, with proposed unstuck>.
QUEUE: <count fails, count DIRTY>. Inbox: <empty | N messages, action>.
```

## Pattern 7 — Release lease + clean worktree immediately after auto-merge ARMED

Once your PR is `auto-merge ARMED` and CI is running, you're done. The lease
and worktree are dead weight:

```bash
rm -f .chump-locks/claim-<gap>-*.json
git worktree remove --force /tmp/chump-<gap>
```

Don't wait for `chump gap ship` — auto-merge handles that downstream. Holding
the lease blocks other curators from picking up overlapping work.

## Pattern 8 — When PROOF-OF-MERGE blocks a status-flip

For gaps already merged on remote but failing local PROOF-OF-MERGE checks,
`chump gap ship` now auto-fetches `origin/main` before the check (INFRA-2423).
No bypass env var is needed. The minimal override stack is:

```bash
CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
CHUMP_ALLOW_STALE_DESTRUCTIVE=1 \
chump gap ship <gap-id> --closed-pr <N> --update-yaml
```

(`CHUMP_BYPASS_PROOF_OF_MERGE` is deleted per INFRA-2423. Auto-fetch handles
the "local main is stale" case automatically.)

This 2-env stack is an improvement. **Filed as META-085 FIX 3**: `chump gap ship-orphan`
subcommand that bundles this without the override ceremony.

## Pattern 12 — Verify-at-source via freshness preamble (META-115)

Before filing a **"file missing"** gap or running a **destructive op** against
state.db / hooks / launchd plists / branches, **run the freshness preamble**
to know your stale state up front:

```bash
bash scripts/coord/freshness-preamble.sh         # exits 0/1/2
# or chain via the gate:
bash scripts/coord/freshness-gate.sh && chump claim INFRA-NNNN
```

The preamble classifies your local view into **FRESH / STALE / CRITICAL_STALE**
based on four signals:
- `commits-behind` — `git fetch origin main && git rev-list HEAD..origin/main --count`
- `binary-age` — seconds since `$(which chump)` was last rebuilt
- `cron-health` — `chump cron health` (fail-soft to "unavailable" if not present)
- `bootstrap` — `chump fleet-bootstrap --check` exit code

The gate refuses the chained operation on `CRITICAL_STALE` unless
`CHUMP_ACCEPT_STALE=1` is set (audit emit: `kind=freshness_critical_stale_bypassed`).

The `verify-existence` skill is the canonical check for the actual file/symbol;
the preamble is the surrounding-context check that catches **why** verify-existence
might lie (your local tree is 60+ commits behind, so the file truly DOES exist
on origin/main but not in your view).

**Real-world precedent — 2026-05-27 shepherd session:** the shepherd hit
**3+ stale-tree false-positives** in one loop:
- `recovery-queue-emit.sh phantom-missing` — local main was 48-63 commits behind,
  file existed on origin/main; shepherd was about to file a "file missing" gap.
- `fleet-hold-check.sh` false-missing earlier in the same session.
- `chump --temp` returning multi-line output instead of enum.

In all three cases, running the preamble first would have surfaced
`CRITICAL_STALE` and prompted a rebase before the operator/curator went
chasing ghosts.

## Pattern 13 — Hung-hook detection before Sonnet-takeover (META-116)

When a dispatched Agent appears **abandoned** (no completion notification +
lease released + worktree state-fresh + no PR opened), **DO NOT take over
until you've ruled out a hung pre-commit child**:

```bash
ps aux | grep -E 'git.commit|pre-commit' | grep -v grep
# Or use the operational tool:
bash scripts/coord/dispatch-health-check.sh        # report-only; non-zero on detection
bash scripts/coord/dispatch-health-check.sh --kill # also kills hung children
```

If the check surfaces a `pre-commit` or `git commit` child older than
`CHUMP_DISPATCH_HUNG_THRESHOLD_S` (default 120s), the agent is **blocked, not
abandoned**. Killing the hook PID unblocks the agent's own commit. The agent
then completes normally on its own (commit → push → PR → arm auto-merge →
completion notification). **The kill IS the rescue; takeover is a mistake.**

Shepherd-takeover IS appropriate when:
- Agent task notification arrived with `BLOCKED` status (explicit failure)
- Agent crashed without sending notification AFTER N hours (genuine death)
- No hung children visible in `ps aux` (rules out hook-hang class)

**Real-world precedent — 2026-05-27 14:56Z, INFRA-2000 dispatch:** Sonnet's
commit hung on pre-commit for 5+ min; shepherd assumed Sonnet abandoned and
tried takeover with `--no-verify`; the takeover ALSO wedged on the same hook.
Shepherd killed both hook PIDs at 14:56Z → Sonnet's blocked commit unblocked
+ completed normally (commit `e7300f5af`). Takeover work was duplicate.

Full diagnosis-before-takeover discipline lives in
[`SUBAGENT_DISPATCH.md`](SUBAGENT_DISPATCH.md) "Detecting hung subagents"
subsection. Pattern 13 here is the shepherd-side trigger; the operational
script + smoke test are at `scripts/coord/dispatch-health-check.sh` +
`scripts/ci/test-dispatch-hang-detection.sh` (both shipped via META-116 #2658).

## Pattern 15 — No idle curators in loops (operator norm 2026-05-29)

**Operator standing rule.** When you are running inside a `/loop` or a
scheduled-task cron (CronCreate, `chump fleet autopilot`, etc.), **every
cycle must produce a ship-class action**. "Queue is healthy, nothing to
do" is **not** a valid loop outcome and **never** earns a no-op return.

**Allowed cycle outcomes** (pick one or more):

1. **Claim + ship**: `chump claim <ID>` → implement → push → arm. The
   gap can be xs (file headers, 5-line scripts, registry entries) as
   long as it actually ships and closes value.
2. **Accept an inbound A2A handoff/dispatch**: someone broadcast a
   HANDOFF or your gap-id appears in their lease coverage — take it.
3. **Decompose an umbrella + dispatch Sonnet**: when the queue has an
   umbrella gap with rough-shape description, run `chump gap decompose`
   and either ship a sub-slice yourself or dispatch a Sonnet sub-agent
   on it. Either way the cycle ends with new pickable AC in flight.
4. **Drill into a wedge + ship the fix same-cycle**: if you find a
   queue-wide blocker (failing required check, unmapped manifest entry,
   broken workflow, etc.), the fix ships in the same loop turn that
   discovered it. No "filed gap, will fix next cycle."
5. **Pattern-14 verification surfaces a real action**: a rollup audit
   that finds a genuine misalignment counts only if it produces a
   shipped diff or a structured handoff to the owning curator.

**Forbidden cycle outcomes**:

- "Queue is flowing, no intervention needed" without a ship.
- "Waiting for CI to clear" as a primary activity (CI clears on its
  own; the loop's job is to find the next pickable gap).
- "Conserving tokens for the next N hours" — the operator funds the
  burn; cost-anxiety is not a curator's call to make.
- "All gaps look claimed by others" — `chump gap list --status open`
  routinely shows 50+ pickable P0/P1 xs/s gaps. If you see "nothing,"
  scan deeper (by pillar, by week, by Marcus-arc tag).

**The discipline at the top of every loop turn**:

```bash
# 1. Inbox sweep (existing Pattern 0).
scripts/coord/chump-inbox.sh read --no-advance

# 2. Pickable scan — proves at least one ship-class candidate exists.
chump gap list --status open | grep -E "P0/(xs|s)|P1/(xs|s)" | head -10

# 3. Active lease check — confirm you're NOT about to collide.
ls .chump-locks/claim-*.json

# 4. Commit to ONE of the 5 allowed outcomes BEFORE writing any more
#    diagnostic output. The turn is over only when a ship action
#    (PR open, gap claimed + diff started, Sonnet dispatched, structured
#    HANDOFF sent) has been taken.
```

**Heartbeat compatibility**: Pattern 6 (heartbeat orchestrator every 4
cycles) still applies. The heartbeat is a status PING; it does NOT
substitute for the ship action that this Pattern requires.

**When you genuinely shipped nothing**: the loop should not run at all.
Either stop the cron with `CronDelete <id>` or convert to a sparser
schedule the operator approved. Continuing a token-spending loop
without shipping is the explicit anti-pattern this norm codifies.

## What NOT to do

| Anti-pattern | Why it hurts |
|---|---|
| **Push to event-registry-reserved.txt in parallel with sibling rescue** | Self-collision → forced re-rebases for everyone. Use a flock (META-085 FIX 1). |
| **Edit a sibling-leased file** | Lease holder will collide on their next commit. Always check the hook digest. |
| **Rely on `gh pr update-branch`** for hotspot-file conflicts | Server-side, doesn't run repo merge drivers. Use local rebase (Pattern 3). |
| **Send orchestrator a status ping every cycle** | Spam. Heartbeat every 4 cycles is the contract. |
| **Manually resolve event-registry-reserved.txt conflicts line-by-line** | Slow + error-prone. Pattern 3 takes 5 sec; manual takes 5 min. |
| **Fix a sibling's PR without the X-of-Y context** | Next operator can't tell if more PRs need the same fix. |
| **Take over a Sonnet dispatch without `ps aux` check first** | 2026-05-27 INFRA-2000 was a hung hook, not an abandoned agent. The kill is the rescue (Pattern 13). |

## Stopping criteria

Stop the loop when:
- Inbox + queue + ambient all show **zero actionable items for 3 consecutive cycles**
- Operator interrupt
- An unrecoverable blocker that needs human decision

Don't stop just because the queue is calm — calm queues fill up fast.

## Related artifacts

- [META-085](../gaps/META-085.yaml) — parent (this is Phase 0 / docs slice)
- [META-069](../gaps/META-069.yaml) — subagent dispatch discipline (Opus orchestrates, Sonnet executes)
- [META-071](../gaps/META-071.yaml) — CI ↔ preflight parity matrix
- [INFRA-1532](../gaps/INFRA-1532.yaml) — bot-merge.sh self-watchdog (the bug behind Pattern 5)
- [INFRA-1878](../gaps/INFRA-1878.yaml) — `chump gap list` ⚠ detector false-positive
- [INFRA-1860](../gaps/INFRA-1860.yaml) — PostToolUse inbox auto-poll (related observability)
