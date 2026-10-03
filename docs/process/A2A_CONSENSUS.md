# A2A consensus is always-on and mandatory (INFRA-2515, operator decision 2026-06-05)

Moved out of `CLAUDE.md` by ZERO-WASTE-125 (rulebook line-budget cut).

The agent-to-agent coordination layer (`FEEDBACK kind=proposal` → curator
votes → deliberator tally → `consensus_result`) must **always be on and
always be in use**. A proposal that dies at `NO_QUORUM` because nobody
voted is the fleet *failing to coordinate* — and after the grace window it
needlessly pages the operator. So:

- **Vote on every open proposal in your inbox, every cycle.** When the
  SessionStart digest (or a `VOTE NEEDED` nudge) surfaces an open
  `FEEDBACK kind=proposal`, cast `chump vote <corr_id> +1|-1|0 --reason '<why>'`
  **before** picking up a gap. Abstain (`0`) with a reason if it's out of
  your lane — that still counts toward quorum. Silence is not an option.
- **Route routine fleet decisions through consensus, not unilaterally** —
  priority/class re-rankings, scale changes, doctrine tweaks: broadcast a
  proposal and let the fleet vote.
- **It self-enforces.** The deliberator (`com.chump.deliberator`, every 30
  min) re-surfaces starved proposals to your inbox to solicit votes, and
  `fleet-doctor`'s `a2a-consensus` check turns **RED** if the recv-side
  flag is off or the tallier is dead. Don't disable
  `CHUMP_FLEET_RECV_SIDE_V0` / `CHUMP_A2A_LAYER` — the bootstrap sets
  them; the farmer/daemon team keeps the deliberator scheduled.

**Hourly auto-bootstrap (INFRA-1808).** The first manual
`chump-fleet-bootstrap.sh` install run self-installs an
`com.chump.bootstrap-auto-install` LaunchAgent that re-runs
`chump-fleet-bootstrap.sh --install` every hour (idempotent) and emits
`kind=fleet_bootstrap_auto_install` per cycle. This closes the
"shipped installer script, nobody ran it" gap that let pr-auto-rebase /
claude-reaper / bot-merge-watchdog sit uninstalled for days after landing.
