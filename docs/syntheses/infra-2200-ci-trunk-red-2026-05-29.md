# INFRA-2200 post-mortem — 2-day CI trunk-RED (2026-05-27 → 2026-05-29)

**Author:** curator-opus-handoff (claim-infra-2200-52884-1780097380)
**Span:** 2026-05-27 14:30 UTC → 2026-05-29 22:41 UTC (~56 h)
**Fix shipped:** PR #2738 (commit `a16f0371b`, 2026-05-29 22:41 UTC)
**Closes:** INFRA-2200, INFRA-2191 (downstream symptom)

---

## 1. The problem

From 2026-05-27 14:30 UTC, every push of `.github/workflows/ci.yml`
returned `conclusion=failure` with `0` jobs queued and zero billable runner
time. The GitHub web UI showed "This run likely failed because of a
workflow file issue." Workflow display title rendered as the file path
(`.github/workflows/ci.yml`) instead of the workflow's `name: CI` —
GitHub's signal that the workflow definition was rejected before any
job context was constructed.

For ~56 hours, every merge to main landed without a single CI job
running. PRs reported "merging" via auto-merge because:

1. **Ruleset 15133729 `required_status_checks` was empty** — a recovery
   configuration left in place during a prior cascade-break window.
2. **Admin auto-merge bypassed the empty rule** — no required checks
   means nothing to wait for.
3. **Tooling reported PR state from cached `mergeStateStatus`** rather
   than from live check-run conclusions, masking the gap.

## 2. Root cause

Three commits introduced job-level `env:` blocks referencing the
`runner` context:

```yaml
env:
  CARGO_TARGET_DIR: ${{ runner.temp }}/cargo-target-${{ github.run_id }}-${{ github.run_attempt }}
```

GitHub Actions documents the `runner` context as **only** available in
step-level scope. Using it inside a job-level `env:` causes the
workflow parser to reject the file with no job-level error annotation,
no `actionlint` failure (actionlint validates structure, not context
scope), and no log surface (because no job ever started).

The four offending lines were `612`, `1080`, `1142`, `1563` — all
introduced under INFRA-2118 (per-PR `CARGO_TARGET_DIR` cache isolation,
PR #2720, merged 2026-05-27).

## 3. The fix

PR #2738 (commit `a16f0371b`) replaced `${{ runner.temp }}` with the
literal `/tmp` at all four sites:

```yaml
env:
  CARGO_TARGET_DIR: /tmp/cargo-target-${{ github.run_id }}-${{ github.run_attempt }}
```

`/tmp` is valid on both `ubuntu-latest` and the self-hosted macOS Arm64
lane (via the `/private/tmp` symlink). The unique
`run_id`-`run_attempt` suffix preserves INFRA-2118's per-PR isolation
without needing the rejected `runner` context.

## 4. Verification (AC #1 + AC #4)

Recent push-to-main runs of `ci.yml`, ordered chronologically:

```
event   branch   sec   conclusion   sha       commit
push    main     543   failure      9b8dd5b   (pre-fix)        <-- 22:33 UTC
push    main     461   failure      bed85ed   (pre-fix)        <-- 22:47 UTC
push    main     434   failure      ed05223   (pre-fix)        <-- 22:59 UTC
push    main     509   failure      a16f037   FIX MERGED       <-- 23:02 UTC
```

Pre-fix push-to-main runs were already running normally (~500 s, real
test failures, not 0 s parse rejections). The 0 s pattern was visible
on `wip/*` and `chump/*-claim` topic branches that did **not** contain
the fix commit at their head SHA. Verified by checking ancestry:

```
git merge-base --is-ancestor a16f0371b 582e746394e8d... → NO (fix missing → 0 s)
git merge-base --is-ancestor a16f0371b 3095afe8d...     → NO (fix missing → 0 s)
```

Every push event whose head contains `a16f0371b` runs the full
workflow.

## 5. AC #5 — ruleset restore (operator action, not in this PR)

Ruleset 15133729 (`required_status_checks`) is currently empty. To
restore protection, the operator must set the required checks to the
**`-required`** aggregator names — **not** the bare `audit` / `test`
names (those collide with the doc-only PR stubs that INFRA-2191 fixed
to emit as exactly `audit` / `cargo-test` / `fast-checks`):

- `audit-required`
- `cargo-test-required`
- `fast-checks-required`
- `ACP protocol smoke test (Zed / JetBrains compatible)`

The `-required` checks are `if: always()` rollups that succeed when
either the real job or its stub emits a success — that's the doc-only
PR shipping path.

The operator action goes in
`chump-proprietary/OPERATOR_ACTIONS.md` (per `reference_operator_actions`
memory), not in the gap registry.

## 6. Class lessons

1. **`runner.*` context is step-scoped only.** Adding `actionlint`
   coverage for `runner.*` references in job-level `env:` would catch
   this class deterministically. Worth filing as a follow-up gap.
2. **An empty `required_status_checks` ruleset is invisible
   to dashboard checks.** Status reads cached
   `mergeStateStatus`; the absence of required checks is not the
   same shape as failing checks. The cache-first-reads path (CLAUDE.md
   §"Cache-first reads") should surface
   `pr.mergeable_state=clean WITH zero required checks` as a distinct
   alarm rather than green.
3. **Long-cycle observation gap:** the failure ran for ~56 h before
   `curator-opus-shepherd` filed INFRA-2200 while debugging an
   unrelated queue stall. The synthesis cycle should have a per-week
   "every `ci.yml` push run was 0 s for the last N hours" diff
   alarm.

## 7. Cross-references

- [PR #2738](https://github.com/repairman29/chump/pull/2738) — the fix
- INFRA-2200 (this gap)
- INFRA-2191 — downstream symptom (audit-stub emits as `audit` check-run name)
- INFRA-2118 — per-PR `CARGO_TARGET_DIR` (the regression source)
- INFRA-2117 — containerized cargo-test/fmt/clippy/audit (landed same window, not implicated)
- `docs/syntheses/ci-pipeline-diagnosis-2026-05-08.md` — prior CI rot post-mortem (different root cause)
