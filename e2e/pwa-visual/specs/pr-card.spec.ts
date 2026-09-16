import { test, expect } from '@playwright/test';

// INFRA-6926: render-sanity harness for <chump-pr-card> ahead of its
// INFRA-1587 CSS migration slice. No baseline image is committed — this
// asserts the shadow DOM painted real content, not a pixel-for-pixel match.
test('chump-pr-card renders a badge and checks list from a mocked PR payload', async ({ page }) => {
  await page.route('**/api/pr/1234', (route) =>
    route.fulfill({
      json: {
        url: 'https://github.com/example/chump/pull/1234',
        state: 'OPEN',
        merge_state_status: 'CLEAN',
        auto_merge: false,
        head_sha: 'abcdef1234567890',
        base_branch: 'main',
        checks: [{ name: 'ci', status: 'COMPLETED', conclusion: 'SUCCESS' }],
      },
    })
  );

  await page.goto('/e2e/pwa-visual/fixtures/pr-card.html');

  const host = page.locator('chump-pr-card');
  const card = host.locator('.pr-card');
  await expect(card).toBeVisible();
  await expect(card).not.toHaveClass(/loading/);
  await expect(card.locator('.pr-card-badge')).toHaveText('Ready to merge');

  const box = await card.boundingBox();
  expect(box?.width).toBeGreaterThan(0);
  expect(box?.height).toBeGreaterThan(0);
});
