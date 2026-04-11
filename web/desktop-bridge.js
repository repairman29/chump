/**
 * Chump Tauri desktop bridge (optional helpers).
 * The main PWA bundle uses __CHUMP_FETCH + chumpApiUrl in index.html for streaming chat.
 * Use this module from DevTools or future UI code: dynamic import is required (no bundler).
 *
 * Example:
 *   const b = await import('./desktop-bridge.js');
 *   const api = await b.createChumpDesktopApi();
 *   await api.healthSnapshot();
 */
export async function createChumpDesktopApi() {
  const { invoke } = await import(
    'https://cdn.jsdelivr.net/npm/@tauri-apps/api@2.2.0/core/+esm'
  );
  return {
    getApiBase: () => invoke('get_desktop_api_base'),
    healthSnapshot: () => invoke('health_snapshot'),
    resolveToolApproval: (requestId, allowed, token) =>
      invoke('resolve_tool_approval', {
        requestId,
        allowed,
        token: token ?? null,
      }),
    /** Returns raw SSE string; prefer fetch streaming from index.html for UX. */
    submitChatRaw: (bodyJson, token) =>
      invoke('submit_chat', { bodyJson, token: token ?? null }),
  };
}
