import { test, expect } from '@playwright/test';

const llmE2E = process.env.CHUMP_E2E_LLM === '1' || process.env.CHUMP_E2E_LLM === 'true';

/**
 * PWA path that exercises real inference (local Ollama by default).
 * Expect slow first token / long generation — timeouts come from playwright.config.ts.
 * Skipped in CI unless **CHUMP_E2E_LLM=1** (P4.3 — optional LLM e2e).
 */
test.describe('Daily driver — LLM (PWA)', () => {
  test('model replies with marker text', async ({ page }) => {
    test.skip(!llmE2E, 'Set CHUMP_E2E_LLM=1 to run (requires working local/cloud model)');
    await page.goto('/');
    await page.locator('#msg-input').fill('Reply with exactly: E2E_LLM_OK');
    await page.locator('#send-btn').click();
    const bubbles = page.locator('.message.assistant .bubble');
    await expect(bubbles.last()).toContainText('E2E_LLM_OK');
  });
});
