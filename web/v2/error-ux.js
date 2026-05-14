// PRODUCT-100 — PWA visible error states + offline indicator
//
// Provides:
//   apiFetch(path, opts)     — fetch wrapper with toast on failure, retry, staleness
//   window.chumpApiStatus    — { live, staleMs, offline } observable
//   <chump-status-pill>      — top-of-page indicator (green/yellow/red)
//
// Replaces the pattern:  fetch('/api/...').then(...).catch(() => {})
// With:                  apiFetch('/api/...').then(...).catch(() => {})
//                        — errors are surfaced; silence is gone.

// ── Configuration ──────────────────────────────────────────────────────────────
const RETRY_DELAYS_MS  = [2_000, 5_000, 15_000];  // backoff sequence on failure
const STALE_WARN_MS    = 120_000;                  // 2 min before yellow pill
const TOAST_COLLAPSE_MS = 120_000;                 // 2 min before collapsing toasts
const TOAST_TIMEOUT_MS  = 8_000;                   // individual toast lifespan

// ── ApiStatus singleton ────────────────────────────────────────────────────────
class ApiStatus {
  #lastSuccessAt = 0;       // epoch ms of last successful API response
  #offlineAt = null;        // epoch ms when we went offline (null = online)
  #toastCount = 0;          // toasts shown since going offline
  #stickyBanner = null;     // the collapsed sticky banner element

  get isOffline()    { return !navigator.onLine || this.#offlineAt !== null; }
  get lastSuccessAt(){ return this.#lastSuccessAt; }
  get staleMs()      { return this.#lastSuccessAt ? Date.now() - this.#lastSuccessAt : 0; }

  recordSuccess() {
    this.#lastSuccessAt = Date.now();
    this.#offlineAt = null;
    this.#toastCount = 0;
    this.#dismissStickyBanner();
    document.dispatchEvent(new CustomEvent('chump:api-status', { detail: 'live' }));
  }

  recordFailure(path) {
    if (!this.#offlineAt) this.#offlineAt = Date.now();
    this.#toastCount++;
    document.dispatchEvent(new CustomEvent('chump:api-status', { detail: 'offline' }));

    const offlineMs = Date.now() - this.#offlineAt;
    if (offlineMs > TOAST_COLLAPSE_MS) {
      this.#ensureStickyBanner();
    } else {
      this.#showToast(path);
    }
  }

  // ── Toast UI ───────────────────────────────────────────────────────────────

  #showToast(path) {
    const container = this.#toastContainer();
    const toast = document.createElement('div');
    toast.className = 'chump-error-toast';
    toast.innerHTML = `
      <span class="toast-msg">⚠ Couldn't reach <code>${this.#esc(path)}</code></span>
      <button class="toast-retry">Retry</button>
      <button class="toast-dismiss" aria-label="Dismiss">×</button>`;
    toast.querySelector('.toast-retry').addEventListener('click', () => {
      toast.remove();
      // Re-fire the last apiFetch call for this path (best-effort).
      apiFetch(path).catch(() => {});
    });
    toast.querySelector('.toast-dismiss').addEventListener('click', () => toast.remove());
    container.appendChild(toast);
    // Auto-dismiss after TOAST_TIMEOUT_MS.
    setTimeout(() => { if (toast.parentNode) toast.remove(); }, TOAST_TIMEOUT_MS);
  }

  #toastContainer() {
    let c = document.getElementById('chump-toast-container');
    if (!c) {
      c = document.createElement('div');
      c.id = 'chump-toast-container';
      document.body.appendChild(c);
    }
    return c;
  }

  #ensureStickyBanner() {
    if (this.#stickyBanner) return;
    const banner = document.createElement('div');
    banner.id = 'chump-offline-banner';
    banner.innerHTML = `
      <span>🔴 Backend unreachable — retrying in background</span>
      <button id="chump-offline-retry">Retry now</button>`;
    banner.querySelector('#chump-offline-retry').addEventListener('click', () => {
      apiFetch('/api/health').catch(() => {});
    });
    document.body.prepend(banner);
    this.#stickyBanner = banner;
  }

  #dismissStickyBanner() {
    if (this.#stickyBanner) {
      this.#stickyBanner.remove();
      this.#stickyBanner = null;
    }
    // Also clear individual toasts on recovery.
    document.getElementById('chump-toast-container')?.remove();
  }

  #esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
}

// Expose singleton.
const chumpApiStatus = new ApiStatus();
window.chumpApiStatus = chumpApiStatus;

// ── apiFetch — the core wrapper ────────────────────────────────────────────────

/**
 * Fetch wrapper for /api/* endpoints.
 * On success: records last-success timestamp → pill goes green.
 * On failure: shows toast → auto-retries with backoff → collapses to banner after 2 min.
 *
 * @param {string}  path     — API path (e.g. '/api/health')
 * @param {object}  opts     — standard fetch options
 * @param {object}  apiOpts  — {retryCount: number, silent: boolean}
 * @returns {Promise<Response>}
 */
async function apiFetch(path, opts = {}, { retryCount = 0, silent = false } = {}) {
  try {
    const res = await fetch(path, opts);
    if (res.ok || res.status < 500) {
      // 2xx–4xx: treat as "server is alive" for staleness purposes.
      chumpApiStatus.recordSuccess();
      return res;
    }
    throw new Error(`HTTP ${res.status}`);
  } catch (err) {
    if (!silent) chumpApiStatus.recordFailure(path);

    // Auto-retry with backoff.
    const delay = RETRY_DELAYS_MS[retryCount];
    if (delay !== undefined) {
      await new Promise(r => setTimeout(r, delay));
      return apiFetch(path, opts, { retryCount: retryCount + 1, silent });
    }

    throw err; // Exhausted retries — let caller handle.
  }
}

// Expose globally so other modules can use apiFetch without imports.
window.apiFetch = apiFetch;

// ── navigator.onLine integration ──────────────────────────────────────────────

window.addEventListener('offline', () => {
  document.dispatchEvent(new CustomEvent('chump:api-status', { detail: 'offline' }));
  // Trigger recordFailure with a placeholder path so sticky banner logic runs.
  chumpApiStatus.recordFailure('(network)');
});

window.addEventListener('online', () => {
  // Probe immediately to confirm connectivity.
  apiFetch('/api/health', {}, { silent: true }).catch(() => {});
});

// ── <chump-status-pill> ───────────────────────────────────────────────────────
// Top-of-page status indicator.
// States: live (green) / stale (yellow, shows "Nm ago") / offline (red)

class ChumpStatusPill extends HTMLElement {
  #intervalId = null;
  #unsub = null;

  connectedCallback() {
    this.#render('init');
    this.#unsub = (e) => this.#onStatus(e.detail);
    document.addEventListener('chump:api-status', this.#unsub);
    document.addEventListener('chump:stream-status', this.#unsub);
    // Poll for staleness tick.
    this.#intervalId = setInterval(() => this.#tick(), 15_000);
  }

  disconnectedCallback() {
    if (this.#unsub) document.removeEventListener('chump:api-status', this.#unsub);
    if (this.#unsub) document.removeEventListener('chump:stream-status', this.#unsub);
    if (this.#intervalId) clearInterval(this.#intervalId);
  }

  #onStatus(detail) {
    if (detail === 'live' || detail === 'connecting') this.#render('live');
    else if (detail === 'offline' || detail === 'reconnecting') this.#render('offline');
    else if (detail === 'paused') this.#render('paused');
    else this.#tick();
  }

  #tick() {
    if (!navigator.onLine) { this.#render('offline'); return; }
    const staleMs = chumpApiStatus.staleMs;
    if (staleMs === 0) { this.#render('init'); return; }
    if (staleMs > STALE_WARN_MS) this.#render('stale', staleMs);
    else this.#render('live');
  }

  #render(state, staleMs = 0) {
    const labels = {
      live:    { dot: '🟢', text: 'live',           cls: 'pill-live'    },
      stale:   { dot: '🟡', text: this.#ago(staleMs), cls: 'pill-stale'   },
      offline: { dot: '🔴', text: 'offline',         cls: 'pill-offline' },
      paused:  { dot: '⚪', text: 'paused',          cls: 'pill-paused'  },
      init:    { dot: '⚪', text: '',                cls: 'pill-init'    },
    };
    const { dot, text, cls } = labels[state] || labels.init;
    this.className = `chump-status-pill ${cls}`;
    this.title = `API: ${state}${staleMs ? ` (last ok ${this.#ago(staleMs)})` : ''}`;
    this.textContent = text ? `${dot} ${text}` : dot;
  }

  #ago(ms) {
    const s = Math.floor(ms / 1000);
    if (s < 60)   return `${s}s ago`;
    const m = Math.floor(s / 60);
    if (m < 60)   return `${m}m ago`;
    return `${Math.floor(m / 60)}h ago`;
  }
}

customElements.define('chump-status-pill', ChumpStatusPill);
