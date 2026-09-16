import { test, expect } from '@playwright/test';

// INFRA-6926: render-sanity harness for <chump-workflow-timeline> ahead of
// its INFRA-1587 CSS migration slice. No baseline image is committed — this
// asserts the shadow DOM painted the four phase rows on first connect,
// before any SSE data arrives (the component renders synchronously).
test('chump-workflow-timeline renders its four phase rows on connect', async ({ page }) => {
  // The component opens an EventSource to /api/gap/:id/stream; the harness
  // doesn't need it to succeed since #render() paints before #connect().
  await page.route('**/api/gap/*/stream', (route) => route.abort());

  await page.goto('/e2e/pwa-visual/fixtures/workflow-timeline.html');

  const host = page.locator('chump-workflow-timeline');
  const timeline = host.locator('.wf-timeline');
  await expect(timeline).toBeVisible();

  const rows = timeline.locator('.wf-phase');
  await expect(rows).toHaveCount(4);
  await expect(rows.nth(0).locator('.wf-phase-name')).toHaveText('Preflight');
  await expect(rows.nth(3).locator('.wf-phase-name')).toHaveText('Ship');

  const box = await timeline.boundingBox();
  expect(box?.width).toBeGreaterThan(0);
  expect(box?.height).toBeGreaterThan(0);
});
