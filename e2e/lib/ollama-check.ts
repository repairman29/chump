/**
 * Check if Ollama is available and attempt to start it if not.
 * Exported for FTUE/e2e-pwa workflows: either start Ollama before model calls
 * or skip with clear notice if model unreachable.
 */

const OLLAMA_BASE = process.env.OPENAI_API_BASE || 'http://127.0.0.1:11434/v1';
const OLLAMA_HEALTH_URL = OLLAMA_BASE.replace('/v1', '') + '/api/tags';
const OLLAMA_STARTUP_TIMEOUT_MS = 30000; // 30s for `brew services start ollama` or similar

export interface OllamaStatus {
  available: boolean;
  healthy: boolean;
  error?: string;
}

/**
 * Poll Ollama health endpoint until ready or timeout.
 * Returns { available: true, healthy: true } if OK.
 * Returns { available: false, error: string } if timeout or unreachable.
 */
export async function checkOllamaHealth(): Promise<OllamaStatus> {
  const startTime = Date.now();
  const deadline = startTime + OLLAMA_STARTUP_TIMEOUT_MS;

  while (Date.now() < deadline) {
    try {
      const res = await fetch(OLLAMA_HEALTH_URL, { timeout: 5000 });
      if (res.ok) {
        return { available: true, healthy: true };
      }
    } catch (e) {
      // Network error or timeout — keep polling
    }
    // Wait 500ms before retrying
    await new Promise((resolve) => setTimeout(resolve, 500));
  }

  return {
    available: false,
    healthy: false,
    error: `Ollama not reachable at ${OLLAMA_HEALTH_URL} after ${OLLAMA_STARTUP_TIMEOUT_MS}ms`,
  };
}

/**
 * For use in test.beforeAll() or test hooks.
 * If Ollama is not available, logs a clear skip notice and returns false.
 * If available, returns true.
 *
 * Example:
 *   test.beforeAll(async () => {
 *     const available = await ensureOllamaOrSkip();
 *     if (!available) {
 *       test.skip();
 *     }
 *   });
 */
export async function ensureOllamaOrSkip(): Promise<boolean> {
  const status = await checkOllamaHealth();
  if (!status.available) {
    console.log(
      `[FTUE Ollama Gate] Skipping LLM-dependent tests: ${status.error}. ` +
        `Start Ollama with: brew services start ollama && until curl -sf http://127.0.0.1:11434/api/tags; do sleep 1; done`
    );
    return false;
  }
  return true;
}
