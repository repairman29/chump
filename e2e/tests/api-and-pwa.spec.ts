import { test, expect } from '@playwright/test';
import { ensureOllamaOrSkip } from '../lib/ollama-check';

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
    expect(j.tool_policy).toBeDefined();
    expect(Array.isArray(j.tool_policy.tools_ask)).toBeTruthy();
  });

  test('GET /api/repo/context', async ({ request }) => {
    const r = await request.get('/api/repo/context', { timeout: 30_000 });
    expect(r.status()).toBe(200);
    const j = await r.json();
    expect(typeof j.multi_repo_enabled).toBe('boolean');
    expect(j).toHaveProperty('effective_root');
    expect(Array.isArray(j.profiles)).toBeTruthy();
    expect(j).toHaveProperty('active_profile');
  });

  test('POST /api/approve (idempotent for unknown id)', async ({ request }) => {
    const r = await request.post('/api/approve', {
      data: { request_id: '00000000-0000-0000-0000-000000000000', allowed: false },
    });
    expect(r.status()).toBe(200);
    const j = await r.json();
    expect(j.ok).toBe(true);
  });

  test('GET /api/jobs (async job log)', async ({ request }) => {
    const r = await request.get('/api/jobs?limit=5');
    expect(r.status()).toBe(200);
    const j = await r.json();
    expect(Array.isArray(j.jobs)).toBeTruthy();
  });

  test('GET /api/analytics (G7 dashboard)', async ({ request }) => {
    const r = await request.get('/api/analytics');
    expect(r.status()).toBe(200);
    const j = await r.json();
    expect(typeof j.total_sessions).toBe('number');
    expect(typeof j.total_turns).toBe('number');
    expect(typeof j.total_tool_calls).toBe('number');
    expect(typeof j.avg_latency_ms).toBe('number');
    expect(typeof j.thumbs_up).toBe('number');
    expect(typeof j.thumbs_down).toBe('number');
    expect(Array.isArray(j.recent_sessions)).toBeTruthy();
  });

  test('POST /api/messages/999999999/feedback -> 404', async ({ request }) => {
    const r = await request.post('/api/messages/999999999/feedback', {
      data: { feedback: 1 },
    });
    expect(r.status()).toBe(404);
  });
});

test.describe('PWA shell', () => {
  test('loads home and shows message composer', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#msg-input')).toBeVisible();
    await expect(page.locator('#send-btn')).toBeVisible();
  });

  test('navigate between views via sidebar', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#msg-input')).toBeVisible();
    await page.locator('#settings-btn').click();
    await expect(page.locator('chump-view-settings')).toBeVisible();
    await page.locator('[data-view="tasks"]').click();
    await expect(page.locator('chump-view-tasks')).toBeVisible();
  });

  test('settings view shows v2 shell info', async ({ page }) => {
    await page.goto('/');
    await page.locator('#settings-btn').click();
    await expect(page.locator('chump-view-settings')).toBeVisible();
    await expect(page.locator('chump-view-settings')).toContainText('v2 shell');
  });

  test('sessions toggle activates chat view', async ({ page }) => {
    await page.goto('/');
    await page.locator('#sessions-toggle').click();
    await expect(page.locator('[data-view="chat"]')).toHaveAttribute('aria-current', 'page');
  });
});

/** Narrow viewport: touch-style chrome without a real device lab (P5.2 automation). */
test.describe('PWA mobile viewport', () => {
  test.beforeEach(async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
  });

  test('composer and send remain usable', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#msg-input')).toBeVisible();
    await expect(page.locator('#send-btn')).toBeVisible();
    const sendBox = await page.locator('#send-btn').boundingBox();
    expect(sendBox && sendBox.height).toBeGreaterThanOrEqual(40);
  });

  test('nav items accessible in mobile viewport', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('[data-view="chat"]')).toBeVisible();
    await expect(page.locator('[data-view="settings"]')).toBeVisible();
    await page.locator('#settings-btn').click();
    await expect(page.locator('chump-view-settings')).toBeVisible();
  });
});

test.describe('Chat /task path (tolerates slow local Ollama)', () => {
  // INFRA-1072: `test.skip()` inside beforeAll is unreliable in current
  // Playwright — the tests still execute and time out for 5min each instead
  // of skipping cleanly. Probe Ollama once in beforeAll and use the proven
  // conditional `test.skip(condition, reason)` form at the top of each test.
  let ollamaAvailable = false;

  test.beforeAll(async () => {
    ollamaAvailable = await ensureOllamaOrSkip();
  });

  test('/task creates assistant reply in thread', async ({ page }) => {
    test.skip(!ollamaAvailable, 'Ollama not available — LLM-dependent test cannot run');
    const title = `pw-task-${Date.now()}`;
    await page.goto('/');
    await page.locator('#msg-input').fill(`/task ${title}`);
    await page.locator('#send-btn').click();
    const bubbles = page.locator('chump-chat').locator('.msg.assistant .bubble');
    await expect(bubbles.last()).toContainText('Created task', { timeout: 300_000 });
    await expect(bubbles.last()).toContainText(title);
  });

  test('New chat clears thread after a quick reply', async ({ page }) => {
    test.skip(!ollamaAvailable, 'Ollama not available — LLM-dependent test cannot run');
    await page.goto('/');
    await page.locator('#msg-input').fill(`/task nt-${Date.now()}`);
    await page.locator('#send-btn').click();
    await expect(page.locator('chump-chat').locator('.msg.assistant')).toHaveCount(1, {
      timeout: 300_000,
    });
    await page.locator('#msg-input').fill('');
    await page.locator('#msg-input').fill(`/task nt2-${Date.now()}`);
    await page.locator('#send-btn').click();
    await expect(page.locator('chump-chat').locator('.msg')).toHaveCount(2, { timeout: 120_000 });
  });
});
