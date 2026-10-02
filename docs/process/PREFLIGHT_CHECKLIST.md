# Session pre-flight — full checklist and rationale

Moved out of `CLAUDE.md` by ZERO-WASTE-125 (rulebook line-budget cut).

```bash
git fetch origin main --quiet && git status
ls .chump-locks/*.json 2>/dev/null && cat .chump-locks/*.json || echo "(no active leases)"
bash scripts/setup/chump-fleet-bootstrap.sh --check  # META-066, must exit 0
bash scripts/coord/auth-status.sh                    # RESILIENT-086: VALIDITY probe
chump farmer status                                  # RESILIENT-069: lights-on check
tail -30 .chump-locks/ambient.jsonl 2>/dev/null || echo "(no ambient stream yet)"
scripts/coord/chump-inbox.sh read --no-advance   # INFRA-1115: peer DMs
chump-coord watch &                              # FLEET-006 (skip if NATS unavailable)
chump gap list --status open                     # canonical .chump/state.db
chump gap preflight <GAP-ID>                     # exits 1 if not pickable — stop if so
chump --briefing <GAP-ID>                        # MEM-007 per-gap context
bash scripts/coord/freshness-preamble.sh         # META-115: FRESH/STALE/CRITICAL_STALE gate
bash scripts/dev/mission-scoreboard.sh           # MISSION-014: did yesterday move docs/MISSION.md?
```

**Why each step:** `auth-status.sh` catches the trap where a
depleted/stale credential outranks a valid one (exit 2) and prints the
exact fix — don't re-diagnose auth by hand. `chump farmer status` RED
(exit 1) means no NEW claims (chump claim / chump gap reserve refuse); the
Farmer's own recovery routes around it.

**Freshness discipline** — before any "X is missing" claim, run
[`verify-existence`](../../.claude/skills/verify-existence/SKILL.md) or
`git ls-tree origin/main path/to/X`. Local `ls` lies when your checkout is
40+ commits behind. Full rules: [`FRESHNESS_DISCIPLINE.md`](./FRESHNESS_DISCIPLINE.md)
(DOC-059 / META-114).

The SessionStart hook (INFRA-1150 a2a-inbox-inject) auto-surfaces unread
peer broadcasts at the top of every session digest under a `Pending
broadcasts` header. Process + reply per
[`OPUS_MESSAGE_PROTOCOL.md`](./OPUS_MESSAGE_PROTOCOL.md) **before** picking
up a new gap. Send addressed DMs via
`scripts/coord/broadcast.sh --to <session-id> WARN "..."`; read with
`scripts/coord/chump-inbox.sh read`.

`ambient.jsonl` is your peripheral vision — watch for `lease_overlap`,
`silent_agent`, `edit_burst`, `queue_config_drift`, `pr_stuck`,
`subagent_budget_exceeded`, `lessons_injection_active`. Full event-kind
guide: [`CLAUDE_GOTCHAS.md`](./CLAUDE_GOTCHAS.md).

If `chump-fleet-bootstrap.sh --check` exits non-zero, run without
`--check` to install missing launchd plists + git hooks. The first manual
run self-installs an `com.chump.bootstrap-auto-install` LaunchAgent
(INFRA-1808) that re-runs hourly — idempotent, safe — but does not remove
the need for the manual run on a fresh machine.
