# ATC Playbook — the Air Traffic Control operating procedure

Companion to [CLAUDE.md §Air Traffic Control](../../CLAUDE.md) (the role),
[DUTY_OFFICER.md](../design/DUTY_OFFICER.md) (RESILIENT-274, the standing owner), and
[operator-escalation-registry.txt](../../scripts/coord/operator-escalation-registry.txt)
(the quiet gate). This is the repeatable **procedure** the ATC loop runs — forming from
the 2026-08-09/10 two-node bring-up, captured so the role is reusable, not tribal.

**ATC is the tower, not a runway.** It keeps the machine healthy and looping, and
routes every fix to the fleet as a **productized upstream change — never a band-aid.**

## The beat cycle (every loop tick)
1. **Sweep health** — each node's worker liveness + load + disk; ship-rate
   (`git log origin/main --since=1h`); merge-rate; wedges / orphaned leases / stuck PRs;
   ambient alerts.
2. **Diagnose upstream, not symptom — ALMANAC-FIRST.** For any issue, `almanac_search`
   to find the real cause and where the correct fix lives. A detector firing is a SIGNAL,
   not an OUTCOME ([REALITY_CHECK](REALITY_CHECK.md)).
3. **Route the fix — productize, never band-aid.**
   - **chump-internal friction → `chump voice` (VOA).** It forces a `--fix-shape`
     (`doc|tooling|gate|new-subcommand`) + `--minutes-lost` + `--workaround` + `--fix` —
     you cannot file a band-aid, only the upstream change.
   - **external product findings** (olive / smuggler / games / product sites) → **holler**
     (`shared/playtest/holler.mjs --project <slug>`) → the bridge (`holler-to-chump.mjs`)
     resolves `project→repo`, tags the gap `external_repo:owner/repo`, drains to chump.
   - A band-aid (deprioritize, partition, restart) is allowed ONLY as an interim AND ONLY
     if the upstream fix is voiced/holler'd **in the same beat**.
4. **Revive + unstick** (the traffic-cop core) — restart dead daemons; rebase/rerun BLOCKED
   PRs; free orphaned leases; deprioritize a churning gap (with its upstream fix voiced);
   bounce a hung worker. Keep the queue MOVING. A stuck PR is an *unstick* job, never a
   *re-implement* job.
5. **Escalate only through the quiet gate** — page the operator ONLY for halt-class or
   no-playbook signals (`operator-escalation-registry.txt`). Updates ≠ pages.
6. **Never do the fleet's job.** File/route; don't hand-build. Hand-work only to bootstrap a
   capability the fleet structurally lacks, and the deliverable is making the fleet able to
   do it next time.

## Unstick recipes (the playbook registry, growing)
| Signal | Tier | Recipe |
|---|---|---|
| Flaky CI blocks a PR (proof_of_merge, audit-shard, env-race) | T1 | `gh run rerun --failed`; if recurring → voice a de-flake (see CREDIBLE-280) |
| Worker churns a gap (`unverified_ship` loop) | T2 | deprioritize the gap **and** voice the ship-path fix (RESILIENT-286: bot-merge must be synchronous) |
| Node worker crash-loops | T2 | check the minimal-env vars systemd/launchd drop (HOME/PATH/AGENT_ID); fix the runner |
| Disk pressure on a node | T1 | cargo-sweep GC / disk reactor (RESILIENT-273) |
| Node binary stale vs main | T2 | rebuild + reinstall to ALL bin dirs (PATH resolves `~/.cargo/bin` first); voice auto-refresh |
| Node unreachable / dark | T3 | node-level liveness (INFRA-3582); page only if no self-recovery |

## Fleet shape (current, 2026-08-10)
- **M4 = ATC** (tower). **helsinki** (root, 4-core) + **closetjunky** (jeff, 4-core) = worker
  nodes, **1 worker each** (right-sized — one Sonnet worker peaks a 4-core box), **domain-
  partitioned** (helsinki=INFRA/RESILIENT/ZERO-WASTE/CREDIBLE, closetjunky=EFFECTIVE/DOC/
  MISSION/META) as the interim dedup.
- **Coordination spine** (turns two partitioned solo workers into a real fleet):
  RESILIENT-284 (shared NATS + cross-node claims → kills the partition), INFRA-3582 (node
  registry + identity, META-331), RESILIENT-285 (revive A2A consensus). Sequence:
  registry → NATS → A2A.

## Known interim (band-aids with upstream fixes filed)
Every one of these is a deliberate interim; the upstream fix is tracked so ATC doesn't
forget to retire the band-aid:
- domain-partition dedup → **RESILIENT-284** (shared NATS claims)
- non-root node supervised via pidfile nohup loop → node-contract supervision (INFRA-3582)
- `chump gap set --priority P3` to stop a churn → **RESILIENT-286** (synchronous ship)
- per-node state.db copies drift → shared state via NATS (RESILIENT-284)
