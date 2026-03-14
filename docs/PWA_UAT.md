# Chump PWA – UAT checklist

Run the PWA: from repo root, `./run-web.sh` (or `./run-web.sh --port 3001`). Open **http://localhost:3000** (or your port) in a browser.

## 1. Service worker

- [ ] Open DevTools → Application → Service Workers. After load, you see a worker for `http://localhost:3000` (or your origin) with script `sw.js`, status **activated** (or **waiting** then refresh to activate).
- [ ] Console shows `[Chump PWA] service worker registered /` (no registration error).

## 2. Manifest & installability

- [ ] DevTools → Application → Manifest: name **Chump**, start_url `/`, display **standalone**; no errors; icon shows (SVG or PNG).
- [ ] Desktop: **Install** / **Add to desktop** appears in address bar or menu (Chrome/Edge) when criteria are met (HTTPS or localhost).
- [ ] Install the app; launch from desktop/start menu; opens in standalone window with Chump UI; icon is Chump (not generic).

## 3. Offline shell

- [ ] Load the app once (so SW caches shell). DevTools → Application → Cache Storage → **chump-v2**: contains `/`, `/index.html`, `/manifest.json`, `/icon.svg`.
- [ ] DevTools → Network → enable **Offline** (or disconnect network). Reload: shell (chat UI) loads from cache; no blank page. API requests can fail (expected when offline).

## 4. Run from repo

- [ ] Started with `./run-web.sh` from Chump repo root: UI, manifest, and SW are the ones from repo `web/` (e.g. change `web/index.html` title, restart, reload — change is visible). No dependency on OpenClaw or Maclawd.

---

**Sign-off:** _________________  **Date:** _________
