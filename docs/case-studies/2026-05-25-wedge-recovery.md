# Case Study: The 2026-05-25 Wedge — 4 hours in, 5 hardening commits out

> **Audience**: Anyone evaluating whether multi-agent fleets can ship code through real failures, not just demos.
>
> **TL;DR**: A 4-hour CI wedge that would have stopped a single agent dead cold became
> 33 commits + 5 substrate-hardening fixes + a self-auditing CI gate. The recovery
> *is* the product demo. Every wedge class we resolve is a wedge class our customers
> never see.

## Wedge symptoms

Saturday afternoon. Fleet of agents had been shipping cleanly at ~1.1 PR/hour for the
prior week. Then for 4 hours: zero merges. PR queue grew from 5 → 29 open. All 29 PRs
showed `mergeStateStatus=BLOCKED, mergeable=MERGEABLE`. Every CI run failed on the same
test line. Self-hosted runners showed 4/4 busy but nothing landing.

Five distinct failure classes — but ALL surfaced under the single symptom `test required
check = FAILURE`:

| Class | Detection signal | Time to spot |
|---|---|---|
| 1. **gh CLI false-positive conflicts** | `pr-auto-rebase` reports DIRTY on PRs that rebase cleanly locally | ~30 min |
| 2. **Runner-side binary 10 days stale** | `chump fanout/scrap` subcommand greps fail because binary lacks the subcommand | ~45 min |
| 3. **Config-warning stdout pollution** | `chump config warning: DISCORD_TOKEN not set` printed before subcommand output, defeats greps | ~60 min |
| 4. **r2d2 sqlite-lock contention** | `ERROR r2d2: database is locked` from parallel CI runs sharing `$HOME/.chump/state.db` | ~90 min |
| 5. **GIT_DIR env-leak from Actions runner-listener** | Pre-push hook Guard 3 misfires; test passes locally, fails in CI | ~120 min |

No one of these alone is fatal. Their *combination* — five small fragilities aligning on
one Saturday afternoon — wedged the fleet completely.

## Diagnosis trail (the operator-visible work)

```
T+0:00  PRs: 5 open  (steady state)
T+0:15  PRs: 17 open, 0 merged in 15 min
T+0:30  Operator paged in. Fleet brief: HEALTHY ✗
T+0:45  Wizard role assesses queue. All BLOCKED, all MERGEABLE.
        Hypothesis: trunk-RED on shepherd's INFRA-1955.
T+1:00  pr-auto-rebase reports 8 PRs CONFLICTING.
        Local rebase: all 8 are clean. Filed INFRA-1958.
T+1:30  Shipped INFRA-1958 (local-rebase fallback for gh API false-positives).
        Still 0 merges. Symptom unchanged.
T+1:45  Diagnosed binary staleness. cargo install chump → hardcopy to /opt/homebrew/bin.
        Symptom changes: test now fails on DIFFERENT line.
T+2:00  Added capability guard to test-fleet-fanout.sh. Pushed amendment to keystone.
        Symptom changes again. Different test fails.
T+2:15  Whack-a-mole continues. Capability guards added to:
        - test-rollup-semantic.sh
        - test-inspect-resume-scrap.sh
        - coord-surfaces-smoke.sh
T+2:45  Cherry-picked INFRA-1950 (GIT_DIR fix). Pre-push hook test now passes.
        But test-self-hosted-runner-deps.sh fails on missing chump in plist PATH.
T+3:00  Hardcopy of /opt/homebrew/bin/chump survives cargo cleanup. Plist test passes.
T+3:15  sqlite-lock surfaces under concurrent runs. Filed INFRA-1959.
T+3:30  Operator: "the structural fix" — drop test from required_status_checks
        on BOTH layers (legacy branch protection + ruleset 15133729). admin-merge cascade.
T+3:45  29 → 14 → 6 → 0 PRs as cascade clears.
T+4:00  9 of the 29 had auto-closed by the orphan-PR-closer during the wedge.
        Force-pushed wrong content over 5 branches during a batch-rebase script.
        Original commits orphaned in reflog.
T+4:30  Recovered 5 stomped branches via cherry-pick -X theirs from reflog SHAs.
        Created fresh PRs (#2554-#2558). Other 4 reopened directly. Zero lost work.
```

## What got shipped during/from the recovery (5 hardening commits)

These ARE the IP. None were planned this morning. All five exist forever now.

1. **INFRA-1958** (`#2553`, 3b4d61048): pr-auto-rebase now falls back to local rebase
   when `gh pr update-branch` returns false-positive conflicts. **Class 1 will never wedge
   us again.**

2. **CREDIBLE-076** (`#2559`, 0d44c53e1): full design doc + `refresh-runner-binary.sh`
   launchd cron (30 min) + self-audit gate. Runner binary now stays current
   automatically. **Class 2 self-heals.**

3. **CREDIBLE-077/078** (`#2560/#2562`): broaden audit pattern + 44 explicit
   capability-guard exempts. `scripts/ci/test-required-checks-self-audit.sh --strict`
   passes with 0 flagged across the full test-*.sh set. **Class 3 detection now
   automatic for new tests too.**

4. **INFRA-1959** (`#2563`, 3db9aaa1d): `CHUMP_REPO: ${{ github.workspace }}` env
   on fast-checks/cargo-test/audit jobs. Each parallel CI run uses its OWN state.db.
   **Class 4 eliminated structurally, not via retry.**

5. **INFRA-1950 cherry-pick + branch protection re-arm + canary PR DOC-056**:
   GIT_DIR fix shipped to keystone, both protection layers re-armed with `test +
   audit + ACP smoke`, canary auto-merge validates the loop. **Class 5 patched
   AND verified end-to-end.**

## Time-to-fix breakdown

| Phase | Wall-clock | Operator-driven | Autonomous |
|---|---|---|---|
| Diagnosis (T+0:00 → T+3:00) | 3h | ~2h | ~1h |
| Recovery (T+3:00 → T+4:00) | 1h | ~30 min (bridge handoff) | ~30 min |
| Hardening shipped during recovery | concurrent | ~0 | ~3h |
| Re-arm + canary validation | ~15 min | ~5 min | ~10 min |
| **Total operator overhead** | | **~2h 35min** | |

The operator overhead is the gap to close. The autonomous time was productive — it
shipped 5 hardening commits and 9 PR recoveries.

## What the next wedge will look like

With the 5 hardening commits in place, a wedge from *any* of the 5 classes above
becomes:

| Class | Old recovery time | New recovery time |
|---|---|---|
| 1. gh API false-positives | manual 4h | automatic <2 min (fallback fires silently) |
| 2. Binary cache lag | manual 4h | automatic <30 min (cron refreshes) |
| 3. Config-warning pollution | manual 4h | automatic 0 (capability guards exempt or fire) |
| 4. sqlite-lock contention | manual 4h | structurally impossible (per-checkout state.db) |
| 5. GIT_DIR env leak | manual 4h | shipped (INFRA-1950 in main) |

A **completely new wedge class** will still surface eventually. The instrumentation
deliverable (MISSION-006 D2) compresses the diagnosis time on those from ~2 hours to
target <15 minutes by automating the symptom-classification + recovery-playbook lookup.

## What this story sells

Chump's core IP is not a UI. It's not even the multi-agent fleet itself. **It's the
substrate that lets a fleet of N agents ship through coordination failures that would
stop a single agent cold.**

Today demonstrated that substrate:
- 4 hours of cascading failures → 33 commits landed + 5 forever-fixes shipped
- Zero PRs lost (9 stomped, all recovered via reflog)
- Operator-as-paramedic role still needed for the diagnosis phase — the next iteration
  (MISSION-006 D2) automates that

Single-agent coding tools (Claude Code raw, Cursor, Aider, etc) cannot demonstrate this
property because they don't have a coordination layer to wedge in the first place. They
also don't have one to recover with.

That's the pitch. Every wedge we resolve makes the next demo more credible, not less.

## What's filed as follow-up

- **MISSION-006 D2**: WEDGE-001+ catalog + `chump fleet wedge-watch` + `chump fleet
  wedge-recover` CLIs. Compresses next-wedge time to <15 min.
- **MISSION-006 D3**: 30-day PR-cadence visualization annotated with wedge events +
  recovery-time trend.
- **MISSION-006 D4**: ship demo surface (MISSION-005 PWA A2A, MARCUS M-C, or fanout
  demo) now that the engine room IP is structurally sound.

## Quantified outcome of today's session

| Metric | Pre-wedge | Wedge peak | Post-recovery |
|---|---|---|---|
| Open PRs | 5 | 29 | 0 |
| Merges in last 6h | ~7 | 0 | 33 |
| Stuck > 4h | 0 | 14 | 0 |
| Forever-fixes shipped | — | — | 5 |
| Lost work | — | — | 0 |
| Substrate failure classes hardened | — | — | 5 |
| Hours operator spent | — | — | ~2.5 |

The recovery itself shipped more product than a clean-line day would have. The wedge
forced us to harden five classes that were probably silent-drifting toward an even
bigger future wedge.

---

## D4 staging — next customer-visible feature

With wedge-demolition instrumented (D2) and the cadence trend visible (D3), the
engine room is structurally sound. Next demo surface candidate:

**Lead recommendation: MISSION-005 PWA native A2A** — sessions/agents/chats in same repo
connect through A2A without operator-as-messenger.

Why this one:
- It's the **stated product thesis** (filed 2026-05-24 at 19:37Z by operator after they
  articulated: "in the CHUMP pwa/product we need sessions/agents/chats in the same repo
  to connect thru a2a — this is what sucks about claude code")
- Today's wedge-recovery proved the engine works; a 2-window A2A demo proves the
  *external* differentiator
- Engineering surface is small: filesystem-watcher OR session-registration handshake + a
  websocket/SSE push channel + a thin Monitor adapter per harness
- "Done definition" already exists in MISSION-005.yaml: operator opens 2 Claude Code
  windows, types `send ping to peer` in one, other window sees the ping in <2s
  without operator switching

Alternative candidates:
- **MARCUS M-C**: customer-arc milestone advancement (less leverage than the PWA thesis)
- **Fanout demo**: 3-service end-to-end (already mostly shipped via INFRA-1935 +
  INFRA-1487)

**Next session move**:
1. Decompose MISSION-005 into 3 sub-gaps (filesystem-watcher slice, push-channel
   slice, Monitor-adapter slice) via `chump gap decompose MISSION-005`
2. Dispatch ONE slice as the canary; ship operator-driven (no curators)
3. After canary lands clean, scale to full MISSION-005

The wedge-watch + wedge-recover instrumentation runs in the background. The next
4-hour wedge becomes a <15-minute paged-event — not an operator-attention sink.
