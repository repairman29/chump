# CREDIBLE-279 false-done triage — 81 BOOKKEEPING-CLOSED gaps

Generated 2026-08-17 by `scripts/ops/false-done-triage.py` against the 81 done
gaps whose closed_pr is one of the 6 PRs (#3103/#3127/#3165/#3178/#3199/#3200)
proven by `scripts/ops/false-done-sweep.py --multi-close-only` to have shipped
zero implementation files (set membership, not a heuristic).

## Verdict counts

| Verdict | Count | Meaning |
|---|---|---|
| NOT_FOUND (acted on) | 6 | Zero commits anywhere in git history touch any path the gap names. Applied: re-filed as a fresh gap (done is terminal — INFRA-456 recycled-ID guard blocks in-place reopen without CHUMP_ALLOW_RECYCLE=1 operator bypass, which was not exercised). |
| FOUND_ELSEWHERE (needs human confirmation) | 31 | git history has a commit, other than the credited PR, that later touched a named path. NOT auto-applied — several early candidates in this tier turned out to be the file's ORIGINAL creation commit (unrelated to the gap's specific claim) or a mass-touch sweep/WIP commit that coincidentally spans dozens of unrelated gaps' named files. Each needs a human to read the candidate PR's actual diff before `chump gap set <ID> --closed-pr <N>` is run. |
| AMBIGUOUS (needs human triage) | 32 | More than one distinct candidate PR touched the gap's named paths — never silently guessed. |
| UNJUDGEABLE | 12 | Gap text (title+description+AC+evidence+notes) names no concrete repo path at all, so there is nothing to search git history for. |

## NOT_FOUND — acted on (reopened via re-file)

`chump gap set <old-id> --status open` is blocked by the INFRA-456 recycled-ID guard
(done is terminal without an operator-authorized `CHUMP_ALLOW_RECYCLE=1` bypass, which
this triage did not exercise). Each is re-filed as a fresh gap instead, with a note on
the original pointing at the replacement:

| Original (still shows done, now noted) | Re-filed as | Named path(s) with zero history |
|---|---|---|
| CREDIBLE-126 (#3178) | CREDIBLE-185 | docs/process/OPERATOR_PAGE_BUDGET.md |
| META-229 (#3103) | META-328 | auto-admin-merge-daemon.sh, scripts/coord/auto-admin-merge-daemon.sh |
| RESILIENT-028 (#3127) | RESILIENT-307 | docs/process/FINISHER_PROMPT.md |
| RESILIENT-046 (#3165) | RESILIENT-309 | routines.yaml, scripts/ops/routine-health-check.sh |
| RESILIENT-112 (#3165) | RESILIENT-314 | sccache-reaper.sh, scripts/coord/sccache-reaper.sh |
| RESILIENT-144 (#3178) | RESILIENT-317 | pr-rescue-false-close.sh, scripts/coord/pr-rescue-false-close.sh |

## FOUND_ELSEWHERE — candidates, NOT auto-applied

| Gap | Credited (bookkeeping) PR | Candidate PR | Candidate commit subject |
|---|---|---|---|
| CREDIBLE-053 | #3178 | #1460 | docs(INFRA-766): canonical state contract — name every store, declare canonical authority, enumerate |
| CREDIBLE-112 | #3127 | #591 | INFRA-135: scripts/ reorg — categorize 290 root scripts/* into 9 subdirs (Phase 3) (#591) |
| CREDIBLE-118 | #3200 | #3132 | fix(RESILIENT-150): bypass-trailer validators key on schema fields, not the word "bypass" (#3132) |
| CREDIBLE-123 | #3103 | #3560 | roadmap: fleet fabric — manage the machines ChumpOS runs on + productize Linux-node provisioning for |
| CREDIBLE-142 | #3103 | #3590 | WIP on main: 220f99a0 MISSION-044: surface a friction metric (attempts-per-ship / turns-to-first-shi |
| CREDIBLE-152 | #3200 | #3590 | WIP on main: 220f99a0 MISSION-044: surface a friction metric (attempts-per-ship / turns-to-first-shi |
| CREDIBLE-153 | #3200 | #3590 | WIP on main: 220f99a0 MISSION-044: surface a friction metric (attempts-per-ship / turns-to-first-shi |
| EFFECTIVE-041 | #3103 | #3590 | WIP on main: 220f99a0 MISSION-044: surface a friction metric (attempts-per-ship / turns-to-first-shi |
| EFFECTIVE-043 | #3165 | #3590 | WIP on main: 220f99a0 MISSION-044: surface a friction metric (attempts-per-ship / turns-to-first-shi |
| EFFECTIVE-048 | #3165 | #3590 | WIP on main: 220f99a0 MISSION-044: surface a friction metric (attempts-per-ship / turns-to-first-shi |
| EFFECTIVE-060 | #3103 | #3590 | WIP on main: 220f99a0 MISSION-044: surface a friction metric (attempts-per-ship / turns-to-first-shi |
| EFFECTIVE-118 | #3200 | #3590 | WIP on main: 220f99a0 MISSION-044: surface a friction metric (attempts-per-ship / turns-to-first-shi |
| EFFECTIVE-151 | #3200 | #3590 | WIP on main: 220f99a0 MISSION-044: surface a friction metric (attempts-per-ship / turns-to-first-shi |
| EFFECTIVE-167 | #3200 | #3590 | WIP on main: 220f99a0 MISSION-044: surface a friction metric (attempts-per-ship / turns-to-first-shi |
| EFFECTIVE-229 | #3103 | #3738 | INFRA-1944: broadcast.sh --await delivery-confirmation receipts (A2A slice A) (#3738) |
| EFFECTIVE-273 | #3103 | #3590 | WIP on main: 220f99a0 MISSION-044: surface a friction metric (attempts-per-ship / turns-to-first-shi |
| EFFECTIVE-305 | #3200 | #3560 | roadmap: fleet fabric — manage the machines ChumpOS runs on + productize Linux-node provisioning for |
| EFFECTIVE-307 | #3200 | #3590 | WIP on main: 220f99a0 MISSION-044: surface a friction metric (attempts-per-ship / turns-to-first-shi |
| INFRA-2005 | #3200 | #3852 | feat(INFRA-2322): pre-push actionlint gate — catch matrix-in-if and version-typo before main (#3852) |
| INFRA-3338 | #3200 | #3560 | roadmap: fleet fabric — manage the machines ChumpOS runs on + productize Linux-node provisioning for |
| META-042 | #3127 | #3860 | feat(INFRA-2362): queue-tender productization — cost tracking + observability spec (#3860) |
| META-112 | #3127 | #3852 | feat(INFRA-2322): pre-push actionlint gate — catch matrix-in-if and version-typo before main (#3852) |
| PRODUCT-046 | #3165 | #2562 | feat(CREDIBLE-078): exempt remaining 25 tests + audit --strict passes with 0 flagged (#2562) |
| RESILIENT-042 | #3127 | #3550 | RESILIENT-269: integrator skips conflicting branch instead of aborting whole batch (#3550) |
| RESILIENT-043 | #3165 | #3852 | feat(INFRA-2322): pre-push actionlint gate — catch matrix-in-if and version-typo before main (#3852) |
| RESILIENT-123 | #3103 | #3779 | RESILIENT-325: pre-push auto-rebase onto fresh main — eliminate conflict-rot at the source (#3779) |
| RESILIENT-125 | #3165 | #3813 | RESILIENT-331: chairman-pulse board power-output readout + farmer outcome counts (#3813) |
| RESILIENT-126 | #3178 | #3677 | INFRA-1798: mandatory Glance phase — every curator loop reads + acts on inbox first (#3677) |
| RESILIENT-151 | #3199 | #3197 | fix(CREDIBLE-150): serialize durable_resume state-db env tests (#3197) |
| RESILIENT-160 | #3165 | #3631 | RESILIENT-281: sweep grep -c ... || echo 0 idiom, add pre-commit/CI guard (#3631) |
| RESILIENT-167 | #3200 | #3631 | RESILIENT-281: sweep grep -c ... || echo 0 idiom, add pre-commit/CI guard (#3631) |

## AMBIGUOUS — multiple candidate PRs, needs human pick

| Gap | Credited (bookkeeping) PR | Candidate PRs |
|---|---|---|
| CREDIBLE-131 | #3127 | #3178, #1658, #1706 |
| CREDIBLE-151 | #3199 | #3560, #3491 |
| EFFECTIVE-035 | #3103 | #3590, #2980 |
| EFFECTIVE-042 | #3127 | #3590, #3816 |
| EFFECTIVE-046 | #3165 | #3590, #2991 |
| EFFECTIVE-047 | #3165 | #3590, #2974 |
| EFFECTIVE-050 | #3178 | #3590, #2981 |
| EFFECTIVE-053 | #3178 | #3590, #2976 |
| EFFECTIVE-058 | #3103 | #3590, #3310 |
| EFFECTIVE-100 | #3200 | #3590, #3652 |
| EFFECTIVE-122 | #3127 | #3590, #3036 |
| EFFECTIVE-125 | #3165 | #3590, #3032 |
| EFFECTIVE-126 | #3178 | #3590, #3310 |
| EFFECTIVE-142 | #3103 | #3590, #3041 |
| EFFECTIVE-144 | #3178 | #3590, #3648 |
| EFFECTIVE-152 | #3200 | #3590, #3026 |
| EFFECTIVE-153 | #3200 | #3590, #3408 |
| EFFECTIVE-160 | #3165 | #3590, #3310 |
| EFFECTIVE-168 | #3200 | #3590, #3310 |
| EFFECTIVE-169 | #3200 | #3590, #3549 |
| EFFECTIVE-274 | #3127 | #3590, #3141 |
| EFFECTIVE-293 | #3178 | #3590, #3159 |
| FLEET-048 | #3165 | #3779, #3560, #3631 |
| FLEET-053 | #3178 | #3165, #3780, #3560, #1144 |
| META-166 | #3178 | #3752, #3213 |
| MISSION-050 | #3178 | #3524, #3560 |
| RESILIENT-007 | #3127 | #3808, #2014, #3560 |
| RESILIENT-047 | #3165 | #3808, #85 |
| RESILIENT-122 | #3127 | #3752, #3779 |
| RESILIENT-124 | #3127 | #3062, #3590 |
| RESILIENT-153 | #3200 | #3808, #3146 |
| RESILIENT-172 | #3199 | #3511, #1084, #379, #3593, #3791 |

## UNJUDGEABLE — no concrete path named

| Gap | Credited (bookkeeping) PR |
|---|---|
| CREDIBLE-094 | #3178 |
| EFFECTIVE-135 | #3165 |
| META-135 | #3127 |
| META-142 | #3103 |
| META-144 | #3178 |
| META-293 | #3178 |
| MISSION-053 | #3178 |
| PRODUCT-047 | #3165 |
| PRODUCT-048 | #3165 |
| RESILIENT-048 | #3165 |
| RESILIENT-053 | #3165 |
| RESILIENT-094 | #3165 |

## Reproduce

```
python3 scripts/ops/false-done-sweep.py --multi-close-only --json > /tmp/bookkeeping.json
python3 scripts/ops/false-done-triage.py --json-in /tmp/bookkeeping.json --json
```

