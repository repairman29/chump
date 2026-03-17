// Service worker: cache shell for offline. Cache GET /api/sessions, /api/tasks, /api/briefing for offline (Phase 3.2).
const CACHE = 'chump-v7';
const SHELL = ['/', '/manifest.json', '/index.html', '/icon.svg'];
const API_CACHE_GET = ['/api/sessions', '/api/tasks', '/api/briefing'];

function shouldCacheApi(request) {
  if (request.method !== 'GET') return false;
  const u = new URL(request.url);
  return API_CACHE_GET.some((p) => u.pathname === p || u.pathname.startsWith(p + '?'));
}

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener('fetch', (e) => {
  if (e.request.url.includes('/api/')) {
    if (shouldCacheApi(e.request)) {
      e.respondWith(
        fetch(e.request)
          .then((res) => {
            const clone = res.clone();
            caches.open(CACHE).then((c) => c.put(e.request, clone));
            return res;
          })
          .catch(() => caches.match(e.request).then((r) => r || new Response('{"error":"offline"}', { status: 503, headers: { 'Content-Type': 'application/json' } })))
      );
    } else {
      e.respondWith(fetch(e.request));
    }
  } else {
    e.respondWith(caches.match(e.request).then((r) => r || fetch(e.request)));
  }
});
