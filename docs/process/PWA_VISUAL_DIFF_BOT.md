# PWA Visual-Diff Bot (INFRA-1605)

> **What it does.** Every PR that touches the PWA shell (`web/**`,
> `desktop/src-tauri/**`, the snapshot specs, or the workflow itself) runs
> the INFRA-1591 visual snapshot suite in headless chromium and posts a
> single PR comment with a markdown table of view-level pixel diffs +
> downloadable diff PNG artifact bundle.
>
> **Why it matters.** External design collaborators (Marcus, ultrareview
> operators, future visual reviewers) need to *see* visual changes inline
> on the PR without checking out the branch and running the suite
> locally. This bot is the stitching layer that brings the operator's eye
> to the PR rather than the PR to the operator's eye.
>
> **What it is not.** A merge gate. The workflow is `continue-on-error:
> true` and is NOT in the required-checks set. Visual diffs are a
> design-review signal, not a green-light condition.

## How to read the comment

The bot posts (and upserts on subsequent pushes — no thread spam) one of
three comment variants:

### Variant 1: changes detected

```
### Visual diff — N view(s) changed

| View | Viewport | Pixel delta | Diff |
|---|---|---|---|
| onboarding-step-1 | 1440px | 2.3% | [diff-onboarding-step-1.png](…artifact link…) |
| chat-empty-state  | 375px  | 0.7% | [diff-chat-empty.png](…artifact link…) |

Artifact bundle: Download diff PNGs (link)

Re-baseline locally if intentional:
(cd e2e && npx playwright test --grep "@visual|pwa-visual" --update-snapshots)
```

Each row links to the diff PNG inside the workflow's artifact bundle.
The artifact also contains the baseline + actual PNGs side by side so
Marcus can scrub the full triplet, not just the overlay.

### Variant 2: no changes detected

```
### Visual diff — no changes detected

The INFRA-1591 snapshot suite ran against this PR and found no
pixel-level diffs against the committed baselines.
```

Posted only when the suite actually ran. If your PR touches one of the
trigger paths but the comment doesn't show up, the workflow probably
didn't fire — check the Actions tab.

### Variant 3: forward-compat no-op

```
### Visual diff bot — waiting on INFRA-1591

The PWA visual snapshot suite (INFRA-1591) has not landed yet.
```

The workflow was wired ahead of INFRA-1591 on purpose so the routing
layer is live the moment the snapshot suite ships. While we wait, every
PR gets one (uppserted) no-op comment so the bot's existence is visible
and the path becomes self-discoverable.

## Adding a new view to the diff set

1. **Where the specs live.** Visual snapshots are owned by INFRA-1591.
   When that lands, specs will be under either
   `e2e/tests/pwa-visual-*.spec.ts` (flat) or `e2e/tests/pwa-visual/*.spec.ts`
   (subdir). The workflow's detection step (`Detect INFRA-1591 snapshot
   suite`) matches both shapes, so either layout works.

2. **Add a new view.** Inside one of those specs, add a test that
   navigates to the route you want to capture and screenshots it:

   ```ts
   import { test, expect } from '@playwright/test';

   test('pwa-visual: settings page @visual', async ({ page }) => {
     await page.goto('/v2/settings');
     await expect(page).toHaveScreenshot('settings-1440px.png', {
       maxDiffPixelRatio: 0.005,  // 0.5% threshold, matches INFRA-1591
     });
   });
   ```

   Tag it with `@visual` so the workflow's `--grep "@visual|pwa-visual"`
   picks it up.

3. **Re-baseline locally.** First run will fail because no baseline
   exists. Capture one with:

   ```bash
   cd e2e
   npx playwright test --grep "@visual|pwa-visual" --update-snapshots
   git add e2e/tests/**/*-snapshots/ && git commit -m "snapshot: add settings-page baseline"
   ```

4. **The manifest contract.** INFRA-1591 writes a per-run JSON manifest
   at `e2e/test-results/visual-diffs.json` with shape:

   ```json
   {
     "diffs": [
       {
         "view": "settings-page",
         "viewport": "1440px",
         "pixel_delta_pct": "2.3%",
         "baseline_path": "e2e/test-results/pwa-visual-settings.spec/settings-1440px-baseline.png",
         "actual_path":   "e2e/test-results/pwa-visual-settings.spec/settings-1440px-actual.png",
         "diff_path":     "e2e/test-results/pwa-visual-settings.spec/settings-1440px-diff.png"
       }
     ]
   }
   ```

   The bot reads this and renders the markdown table. If the manifest
   doesn't exist for a given run (e.g. the suite is older than the
   INFRA-1591 contract), the bot falls back to the "no changes detected"
   variant — better than dumping a 500-row table of every artifact path.

## Failure modes + recovery

| Symptom | Cause | Fix |
|---|---|---|
| No comment on a PR that touched `web/**` | Workflow didn't fire | Check Actions tab for `pwa-visual-diff` — most likely the path filter missed (e.g. the PR only touched `web/v2/icons/`) |
| Comment says "waiting on INFRA-1591" even though specs exist | Detection step's glob didn't match | Make sure spec filename matches `pwa-visual*.spec.ts` OR lives under `e2e/tests/pwa-visual/` |
| Comment shows N diffs but the diff PNGs are 404 in the artifact | Snapshot suite didn't write to `e2e/test-results/` | Verify INFRA-1591's `--output=test-results` flag is set in the playwright invocation |
| Comment keeps getting posted as new threads on every push | `BOT_MARKER` HTML comment got stripped | Ensure the marker `<!-- chump-visual-diff-bot:INFRA-1605 -->` is the first line of the comment body |

## Tuning + bypassing

- **Disable on a PR.** `gh workflow disable pwa-visual-diff` — the bot
  will not run on any PR until re-enabled. Useful for PRs that touch the
  PWA shell but intentionally regress visuals (e.g. dark-mode rollout).
- **Force a re-run on a stale PR.** `gh workflow run pwa-visual-diff
  --ref <branch>` — the upsert path will replace the existing comment.
- **Per-PR concurrency.** Pushing a new commit while the bot is
  mid-snapshot cancels the in-flight run (`cancel-in-progress: true`).
  The new commit's bot run will post the updated comment.

## Related

- **INFRA-1591** — the snapshot suite this bot consumes. Must land for
  Variant 1/2 to fire; until then, the bot posts Variant 3 (no-op).
- **INFRA-1332** — `e2e-pwa-advisory.yml` — same continue-on-error
  design-signal pattern; this bot followed that shape.
- **INFRA-624 / INFRA-671** — `pr-triage-bot.yml` — the PR-comment +
  bot-identity + upsert pattern that this workflow inherits.
- **`docs/strategy/PRODUCTIZATION_PLAN_2026-05-22.md`** — the
  consumer-quality-gate initiative this bot is one fruiting body of
  (META-068).

## Tier-D classification

This workflow is classified **Tier D — cannot mirror locally** in
[`CI_GATES_INVENTORY.md`](./CI_GATES_INVENTORY.md). Rationale: it spins
up the PWA dev server + headless chromium + posts PR comments via the
GitHub API. The `e2e-pwa-advisory.yml` precedent (same Tier-D entry)
applies.
