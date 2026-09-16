import { test, expect } from '@playwright/test';

// INFRA-6926: render-sanity harness for <chump-cost-meter> ahead of its
// INFRA-1587 CSS migration slice. No baseline image is committed — this
// asserts the shadow DOM painted real content, not a pixel-for-pixel match.
test('chump-cost-meter renders its four figures from a mocked payload', async ({ page }) => {
  await page.route('**/api/telemetry/cost', (route) =>
    route.fulfill({
      json: {
        session_cost_usd: 1.234,
        github: { calls: 42, remaining_core: 4800, remaining_graphql: 3900 },
        budget: { warning: null, ceiling_usd: 0 },
      },
    })
  );

  await page.goto('/e2e/pwa-visual/fixtures/cost-meter.html');

  const host = page.locator('chump-cost-meter');
  const meter = host.locator('.cost-meter');
  await expect(meter).toBeVisible();
  await expect(meter).not.toHaveClass(/loading/);

  const rows = meter.locator('.cost-meter-row');
  await expect(rows).toHaveCount(4);
  await expect(meter.locator('.cost-meter-value').first()).toHaveText('$1.234');

  const box = await meter.boundingBox();
  expect(box?.width).toBeGreaterThan(0);
  expect(box?.height).toBeGreaterThan(0);
});
