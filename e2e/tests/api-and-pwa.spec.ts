import { test, expect } from '@playwright/test';

test.describe('API (no browser)', () => {
  test('GET /api/health', async ({ request }) => {
    const r = await request.get('/api/health');
    expect(r.ok()).toBeTruthy();
    const j = await r.json();
    expect(j.status).toBe('ok');
    expect(j.service).toBe('chump-web');
  });

  test('GET /api/stack-status', async ({ request }) => {
    const r = await request.get('/api/stack-status', { timeout: 30_000 });
    expect(r.status(), 'GET /api/stack-status').toBe(200);
    const j = await r.json();
    expect(j.status).toBe('ok');
    expect(j).toHaveProperty('inference');
  });
});

test.describe('PWA shell', () => {
  test('loads home and shows message composer', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#msg-input')).toBeVisible();
    await expect(page.locator('#send-btn')).toBeVisible();
    await expect(page.locator('#new-chat-btn')).toBeVisible();
  });

  test('ui_selftest=1 reports pass (SSE parser)', async ({ page }) => {
    await page.goto('/?ui_selftest=1');
    await expect(page.locator('#toast')).toContainText(/ui_selftest=1: all passed/i, {
      timeout: 20_000,
    });
  });

  test('settings: theme light then dark', async ({ page }) => {
    await page.goto('/');
    await page.locator('#settings-btn').click();
    await expect(page.locator('#settings-modal')).toBeVisible();
    await page.locator('#settings-theme').selectOption('light');
    await page.locator('#settings-save').click();
    await expect(page.locator('#settings-modal')).not.toBeVisible();
    await expect(page.locator('body')).toHaveClass(/theme-light/);
    await page.locator('#settings-btn').click();
    await page.locator('#settings-theme').selectOption('dark');
    await page.locator('#settings-save').click();
    await expect(page.locator('body')).not.toHaveClass(/theme-light/);
  });

  test('sidecar: open, Tasks tab, Providers tab', async ({ page }) => {
    await page.goto('/');
    await page.locator('#sidecar-toggle').click();
    await expect(page.locator('body')).toHaveClass(/sidecar-open/);
    await page.locator('button[data-tab="tasks"]').click();
    await expect(page.locator('#new-task-btn')).toBeVisible();
    await page.locator('button[data-tab="providers"]').click();
    await expect(page.locator('#sidecar-providers')).toHaveClass(/active/);
  });

  test('sessions drawer toggle', async ({ page }) => {
    await page.goto('/');
    await page.locator('#sessions-toggle').click();
    await expect(page.locator('body')).toHaveClass(/sessions-open/);
    await expect(page.locator('#sessions-search')).toBeAttached();
  });

  test('attachment chip after choosing a .txt file', async ({ page }) => {
    await page.goto('/');
    await page.locator('#file-input').setInputFiles({
      name: 'e2e-attach.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('hello e2e\n'),
    });
    await expect(page.locator('#attachment-chips .attachment-chip')).toContainText('e2e-attach.txt');
    await page.locator('#attachment-chips .chip-remove').first().click();
    await expect(page.locator('#attachment-chips .attachment-chip')).toHaveCount(0);
  });
});

test.describe('Chat quick path (no LLM)', () => {
  test('/task creates assistant reply in thread', async ({ page }) => {
    const title = `pw-task-${Date.now()}`;
    await page.goto('/');
    await page.locator('#msg-input').fill(`/task ${title}`);
    await page.locator('#send-btn').click();
    const bubbles = page.locator('.message.assistant .bubble');
    await expect(bubbles.last()).toContainText('Created task', { timeout: 30_000 });
    await expect(bubbles.last()).toContainText(title);
  });

  test('New chat clears thread after a quick reply', async ({ page }) => {
    await page.goto('/');
    await page.locator('#msg-input').fill(`/task nt-${Date.now()}`);
    await page.locator('#send-btn').click();
    await expect(page.locator('#chat-container .message.assistant')).toHaveCount(1, {
      timeout: 30_000,
    });
    // New chat lives in the sessions drawer; open it so the button is not covered by the header.
    await page.locator('#sessions-toggle').click();
    await expect(page.locator('body')).toHaveClass(/sessions-open/);
    await page.locator('#new-chat-btn').click();
    await expect(page.locator('#chat-container .message')).toHaveCount(0, { timeout: 15_000 });
  });
});
