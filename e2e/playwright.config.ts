import { defineConfig, devices } from '@playwright/test';

// Default matches automation (3847) and run-ui-e2e probing order; always set CHUMP_E2E_BASE_URL via ./scripts/run-ui-e2e.sh for accuracy.
const baseURL = process.env.CHUMP_E2E_BASE_URL || 'http://127.0.0.1:3847';

/** Local slow Ollama / big models: long test and expect timeouts. Opt out with CHUMP_E2E_FAST=1 when tuning speed. */
const fast = process.env.CHUMP_E2E_FAST === '1' || process.env.CHUMP_E2E_FAST === 'true';
const testTimeoutMs = fast ? 60_000 : 600_000;
const expectTimeoutMs = fast ? 15_000 : 300_000;

export default defineConfig({
  testDir: './tests',
  // One worker avoids hammering a single local Ollama instance; override: PW_WORKERS=4 npx playwright test
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 1,
  workers: parseInt(process.env.PW_WORKERS || '1', 10),
  reporter: process.env.CI ? 'github' : 'list',
  timeout: testTimeoutMs,
  expect: { timeout: expectTimeoutMs },
  use: {
    baseURL,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    actionTimeout: fast ? 15_000 : 120_000,
    navigationTimeout: fast ? 30_000 : 120_000,
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
