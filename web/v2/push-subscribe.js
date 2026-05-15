// web/v2/push-subscribe.js — INFRA-1301
//
// Browser-side Web Push subscription registration. On first call:
//   1. Asks user for notification permission (one-time)
//   2. Fetches VAPID public key from /api/push/vapid-public-key
//   3. Subscribes via service worker PushManager
//   4. POSTs subscription JSON to /api/push/register
//
// Subsequent calls: checks existing subscription, re-registers if missing.
//
// Operator-controllable via PWA Settings or:
//   chumpEnablePush()  — request + register
//   chumpDisablePush() — unsubscribe + revoke server-side

function operatorId() {
  let id = localStorage.getItem('chump_operator_id');
  if (!id) {
    id = `operator-${Math.random().toString(16).slice(2, 10)}`;
    localStorage.setItem('chump_operator_id', id);
  }
  return id;
}

function urlBase64ToUint8Array(base64String) {
  const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
  const rawData = atob(base64);
  const outputArray = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; ++i) outputArray[i] = rawData.charCodeAt(i);
  return outputArray;
}

async function getVapidPublicKey() {
  const r = await fetch('/api/push/vapid-public-key');
  if (!r.ok) throw new Error(`vapid key fetch ${r.status}`);
  const d = await r.json();
  if (!d.vapid_public_key) throw new Error('vapid_public_key missing');
  return d.vapid_public_key;
}

async function subscribeUser() {
  if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
    throw new Error('Push not supported in this browser');
  }
  const reg = await navigator.serviceWorker.ready;
  let sub = await reg.pushManager.getSubscription();
  if (!sub) {
    const key = await getVapidPublicKey();
    sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(key),
    });
  }
  return sub;
}

async function registerWithServer(subscription) {
  // /api/push/subscribe (existing Phase 3.1 schema): {endpoint, keys:{p256dh, auth}}.
  // We also stamp operator_id locally so future delivery layer can route by operator.
  // Store the operator-id ↔ endpoint binding in localStorage so the client can
  // identify itself to /api/push/unsubscribe without server lookup.
  const subJson = subscription.toJSON ? subscription.toJSON() : subscription;
  const payload = {
    endpoint: subJson.endpoint,
    keys: subJson.keys || {},
  };
  const r = await fetch('/api/push/subscribe', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  if (!r.ok) throw new Error(`subscribe ${r.status}`);
  // No body on 204. Store endpoint locally for future unsubscribe.
  localStorage.setItem('chump_push_endpoint', subJson.endpoint || '');
  localStorage.setItem('chump_push_operator', operatorId());
  return { ok: true, endpoint: subJson.endpoint };
}

async function enablePush() {
  // 1. permission
  if (Notification.permission === 'denied') {
    throw new Error('Notifications blocked by user; flip in browser settings');
  }
  if (Notification.permission === 'default') {
    const p = await Notification.requestPermission();
    if (p !== 'granted') throw new Error('Notification permission not granted');
  }
  // 2. subscribe + register
  const sub = await subscribeUser();
  await registerWithServer(sub);
  localStorage.setItem('chump_push_enabled', '1');
  return sub;
}

async function disablePush() {
  let endpoint = localStorage.getItem('chump_push_endpoint') || '';
  if ('serviceWorker' in navigator) {
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    if (sub) {
      if (!endpoint) endpoint = sub.endpoint;
      await sub.unsubscribe();
    }
  }
  if (endpoint) {
    await fetch('/api/push/unsubscribe', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ endpoint }),
    });
  }
  localStorage.removeItem('chump_push_enabled');
  localStorage.removeItem('chump_push_endpoint');
}

// Expose to operator (Settings page can call these on toggle).
window.chumpEnablePush = enablePush;
window.chumpDisablePush = disablePush;

// Auto-enable on page load IF operator already opted in (localStorage flag set).
// This re-registers after browser cache wipes that drop subscriptions silently.
async function autoReregisterIfOptedIn() {
  if (localStorage.getItem('chump_push_enabled') !== '1') return;
  try {
    await enablePush();
  } catch (e) {
    console.warn('[chump-push] auto-reregister failed:', e.message || e);
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', autoReregisterIfOptedIn);
} else {
  autoReregisterIfOptedIn();
}
