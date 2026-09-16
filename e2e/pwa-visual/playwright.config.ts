import { defineConfig, devices } from '@playwright/test';

// INFRA-6926: isolated harness — serves the repo root as static files (no
// chump --web daemon, no LLM backend) so each spec can import a single
// web/v2/*.js component module directly and mock its fetch() calls.
const PORT = 4173;

export default defineConfig({
  testDir: './specs',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? 'github' : 'list',
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    trace: 'on-first-retry',
  },
  webServer: {
    command: `python3 -m http.server ${PORT} --directory ../..`,
    url: `http://127.0.0.1:${PORT}`,
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
