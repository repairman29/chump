/**
 * Chump Tauri desktop bridge (optional helpers).
 * The main PWA bundle uses __CHUMP_FETCH + chumpApiUrl in index.html for streaming chat.
 * Use from DevTools: `const b = await import('./desktop-bridge.js'); const api = await b.createChumpDesktopApi();`
 *
 * Uses `window.__TAURI__.core.invoke` (tauri.conf `withGlobalTauri`) — no CDN; works offline.
 */
function getTauriInvoke() {
  const c =
    typeof globalThis !== 'undefined' &&
    globalThis.window &&
    globalThis.window.__TAURI__ &&
    globalThis.window.__TAURI__.core;
  if (c && typeof c.invoke === 'function') {
    return (cmd, args) => c.invoke(cmd, args);
  }
  return null;
}

export async function createChumpDesktopApi() {
  let invoke = getTauriInvoke();
  const deadline = Date.now() + 4000;
  while (!invoke && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 25));
    invoke = getTauriInvoke();
  }
  if (!invoke) {
    throw new Error(
      'Chump desktop API needs the Tauri shell (window.__TAURI__.core.invoke). Open the Cowork app, not a browser tab.'
    );
  }
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
