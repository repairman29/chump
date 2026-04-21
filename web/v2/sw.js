// Chump v2 service worker — offline-first shell cache.
const CACHE = 'chump-v2-shell-2';
const SHELL = [
  '/v2/',
  '/v2/index.html',
  '/v2/manifest.json',
  '/v2/app.js',
  '/v2/chat.js',
  '/icon.svg',
  '/icon-192.png',
  '/icon-512.png',
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((names) => Promise.all(names.filter((n) => n !== CACHE).map((n) => caches.delete(n))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  // API calls: network first, no cache.
  if (url.pathname.startsWith('/api/')) return;
  // Shell assets: cache first, network fallback.
  e.respondWith(
    caches.match(e.request).then((hit) => hit || fetch(e.request))
  );
});
