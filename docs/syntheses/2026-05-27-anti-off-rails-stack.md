# 2026-05-27: Anti-Off-Rails + Autonomy Stack

One-day session shipped the full 7-of-9 layer defense stack against sub-agent
off-rails behavior, with the remaining 2 layers queued for tomorrow.

## Shipped to main today (chronological)

| PR | Gap | Layer |
|---|---|---|
| #2627 | META-109 | Wizard-daemon Phase 1 (DRIVE primitive) |
| #2628 | INFRA-2040 | Silent-fleet-death watchdog |
| #2629 | INFRA-2041 | Ruleset snapshots + admin-merge-cycle wrapper |
| #2630 | META-107 | Wizard Phase 2 (real-fails routing + dispatch + cascade) |
| #2631 | INFRA-2043 | PreToolUse hook fix (live A2A unblock) |
| #2632 | INFRA-2042 | Wizard UNKNOWN merge_state handler |
| #2634 | INFRA-2044 | docs-delta test fix (admin-merge churn root cause) |
| #2635 | INFRA-2050 | voice-banlist diff-hunk scoping |
| #2636 | INFRA-2048+49 | Wizard cache fallback + dry-run guards |
| #2638 | RESILIENT-025 | Pre-commit subject guard (Layer 1) |
| #2639 | INFRA-2055 | Execute-gap mandatory exit emit (Layer 3) |
| #2642 | RESILIENT-029 | Stash-on-reap last-resort preservation |
| #2643 | INFRA-2051 | Wizard outcome detection (Layer 4) |
| #2645 | RESILIENT-033 | Orphan event registrations (audit-gate unblock) |
| #2647 | RESILIENT-026 | Pre-commit paths + pre-push branch guard (Layer 2) |
| #2648 | INFRA-2056 | Sub-agent heartbeat |
| #2649 | RESILIENT-027 | Orphan-worktree watchdog |

## Queued for tomorrow

- RESILIENT-028 (auto-finisher dispatch)
- RESILIENT-030 (typed dispatch contract)
- RESILIENT-031 (admin-merge guard with --noise-class)
- RESILIENT-032 (state.db sync for fresh-worktree gap visibility)
- META-113 (verify-existence discipline — never bare ls)

## Lessons honest-coded

1. Admin-merge was a load-bearing crutch hiding 4 real infra problems
2. Sub-agent off-rails class is reducible to commit-metadata mismatch (RESILIENT-025+026 catches this if hook is on main BEFORE dispatch)
3. Worktree-fork-timing: defenses protect FUTURE dispatches, not the in-flight wave
4. Recovery cost is low when SHA preservation works (git keeps loose objects 90d)
5. Self-hosted runner saturation is the hidden bottleneck — natural CI takes 7-15min when healthy, indefinite when saturated
