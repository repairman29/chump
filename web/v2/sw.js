// Chump v2 service worker — offline-first shell cache.
const CACHE = 'chump-v2-shell-3';
const SHELL = [
  '/v2/',
  '/v2/index.html',
  '/v2/manifest.json',
  '/v2/app.js',
  '/v2/chat.js',
  '/v2/inference-profile.js',
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

// INFRA-1301: Web Push notification handler.
// Receives encrypted pushes from chump server (when delivery layer ships
// as a follow-up) and surfaces them as native notifications.
self.addEventListener('push', (event) => {
  let data = { title: 'Chump', body: '', urgency: 'now', operator_id: '' };
  if (event.data) {
    try {
      const parsed = event.data.json();
      data = { ...data, ...parsed };
    } catch (_e) {
      data.body = event.data.text();
    }
  }
  const options = {
    body: data.body || '',
    icon: '/icon-192.png',
    badge: '/icon-192.png',
    tag: data.operator_id ? `inbox-${data.operator_id}` : 'chump-inbox',
    renotify: data.urgency === 'now',
    data: { url: '/v2/', ...data },
  };
  event.waitUntil(self.registration.showNotification(data.title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || '/v2/';
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((wins) => {
      const existing = wins.find((w) => w.url.includes('/v2/'));
      if (existing) {
        existing.focus();
        existing.postMessage({ type: 'chump-inbox-focus' });
        return;
      }
      return clients.openWindow(url);
    })
  );
});
