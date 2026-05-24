import { test, expect } from '@playwright/test';

// INFRA-1586: PWA header dedup — assert #app-header has ≤4 direct children
// at 1440px, 640px, and 375px after removing model/cost/pillar/autopilot chips.
// Expected: #app-title + chump-repo-switcher + chump-heartbeat (3 elements).

const VIEWPORTS = [
  { width: 1440, height: 900, label: '1440px desktop' },
  { width: 640, height: 900, label: '640px tablet' },
  { width: 375, height: 812, label: '375px mobile' },
];

for (const vp of VIEWPORTS) {
  test(`#app-header has ≤4 direct children at ${vp.label}`, async ({ page }) => {
    await page.setViewportSize({ width: vp.width, height: vp.height });
    await page.goto('/');

    const childCount = await page.locator('#app-header > *').count();
    expect(childCount, `#app-header child count at ${vp.label}`).toBeLessThanOrEqual(4);

    // The four deduped chips must NOT appear in the header
    await expect(page.locator('#app-header chump-model-picker')).toHaveCount(0);
    await expect(page.locator('#app-header chump-cost-meter')).toHaveCount(0);
    await expect(page.locator('#app-header chump-pillar-health')).toHaveCount(0);
    await expect(page.locator('#app-header chump-autopilot-toggle')).toHaveCount(0);

    // The three retained elements must remain
    await expect(page.locator('#app-header #app-title')).toHaveCount(1);
    await expect(page.locator('#app-header chump-repo-switcher')).toHaveCount(1);
    await expect(page.locator('#app-header chump-heartbeat')).toHaveCount(1);
  });
}
