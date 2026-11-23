// Chump v2 service worker — network-first with cache:'no-cache' HTTP disk-cache bypass (PRODUCT-372).
const CACHE = 'chump-v2-shell-6';
const SHELL = [
  '/v2/',
  '/v2/index.html',
  '/v2/manifest.json',
  '/icon.svg',
];

self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await Promise.all(SHELL.map(async (u) => {
      try {
        const res = await fetch(new Request(u, { cache: 'reload' }));
        if (res && res.ok) await cache.put(u, res);
      } catch {}
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    const names = await caches.keys();
    const stale = names.filter((n) => n !== CACHE);
    await Promise.all(stale.map((n) => caches.delete(n)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.pathname.startsWith('/api/')) return;
  if (url.origin !== self.location.origin) return;
  e.respondWith(
    fetch(new Request(e.request, { cache: 'no-cache' }))
      .then((res) => {
        if (res && res.ok) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(e.request, copy)).catch(() => {});
        }
        return res;
      })
      .catch(() => caches.match(e.request))
  );
});

// INFRA-1301: Web Push notification handler.
self.addEventListener('push', (event) => {
  let data = { title: 'Chump', body: '', urgency: 'now', operator_id: '' };
  if (event.data) {
    try {
      const parsed = event.data.json();
      data = { ...data, ...parsed };
    } catch {
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
