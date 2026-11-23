// PRODUCT-372 — Shared SSE Multiplexer & Polling Request Coalescer
//
// 1. Multiplexes all same-origin /api/ambient/stream* EventSource consumers onto
//    ONE shared upstream EventSource('/api/ambient/stream'), applying ?kind=,
//    ?kinds=, and ?prefixes= filters per subscriber on the client.
// 2. Coalesces duplicate concurrent GET polls to expensive status endpoints
//    (/api/fleet-status, /api/stack-status, /api/health/pillars, etc.) with a
//    short 3.5s cache window so header, footer, wizard, and cockpit share a
//    single wire round-trip instead of saturating HTTP/1.1's 6-socket pool.
// 3. Tears down all active EventSource handles on pagehide/beforeunload.

(function installChumpSseAndFetchHub() {
  if (typeof window === 'undefined') return;
  if (window.__chumpSseHubInstalled) return;
  window.__chumpSseHubInstalled = true;

  // ── Part 1: Read-only GET Poll Coalescer ──────────────────────────────────
  const COALESCE_PATHS = new Set([
    '/api/fleet-status',
    '/api/stack-status',
    '/api/health/pillars',
    '/api/health/doctor',
    '/api/health',
    '/api/gap-queue',
    '/api/dashboard-summary',
    '/api/telemetry/cost',
    '/api/repo/context',
    '/api/slots',
  ]);
  const DEDUP_TTL_MS = 3500;
  const inFlight = new Map();
  const recentCache = new Map();

  if (typeof window.fetch === 'function') {
    const baseFetch = window.fetch.bind(window);
    window.fetch = async function coalescedFetch(input, init) {
      const method = (init && init.method) ? String(init.method).toUpperCase() : 'GET';
      if (method !== 'GET' || typeof input !== 'string') {
        if (method !== 'GET') {
          recentCache.clear();
        }
        return baseFetch(input, init);
      }

      let parsedUrl = null;
      try {
        parsedUrl = new URL(input, window.location.origin);
      } catch {
        return baseFetch(input, init);
      }
      if (parsedUrl.origin !== window.location.origin || !COALESCE_PATHS.has(parsedUrl.pathname)) {
        return baseFetch(input, init);
      }

      const key = parsedUrl.pathname + parsedUrl.search;
      const now = Date.now();
      const cached = recentCache.get(key);
      if (cached && (now - cached.ts) < DEDUP_TTL_MS) {
        return new Response(cached.bodyText, {
          status: cached.status,
          statusText: cached.statusText,
          headers: cached.headers,
        });
      }

      let pending = inFlight.get(key);
      if (!pending) {
        pending = (async () => {
          try {
            const res = await baseFetch(input, init);
            const bodyText = await res.text();
            const entry = {
              ts: Date.now(),
              status: res.status,
              statusText: res.statusText,
              headers: Array.from(res.headers.entries()),
              bodyText,
            };
            if (res.ok) {
              recentCache.set(key, entry);
            }
            return entry;
          } finally {
            inFlight.delete(key);
          }
        })();
        inFlight.set(key, pending);
      }

      const snap = await pending;
      return new Response(snap.bodyText, {
        status: snap.status,
        statusText: snap.statusText,
        headers: snap.headers,
      });
    };
  }

  // ── Part 2: Shared EventSource Multiplexer ────────────────────────────────
  if (typeof window.EventSource !== 'function') return;

  const NativeEventSource = window.EventSource;
  const activeNativeStreams = new Set();

  function trackNative(es) {
    activeNativeStreams.add(es);
    const origClose = es.close.bind(es);
    es.close = function closedWrapper() {
      activeNativeStreams.delete(es);
      return origClose();
    };
    return es;
  }

  let sharedUpstream = null;
  let sharedReadyState = 0;
  const subscribers = new Set();

  function parseFilters(rawUrl) {
    try {
      const parsed = new URL(rawUrl, window.location.origin);
      if (parsed.origin !== window.location.origin) return null;
      if (parsed.pathname !== '/api/ambient/stream') return null;

      const singleKind = parsed.searchParams.get('kind');
      const kindsCsv = parsed.searchParams.get('kinds');
      const prefixesCsv = parsed.searchParams.get('prefixes');

      const kinds = new Set();
      if (singleKind) {
        singleKind.split(',').map((s) => s.trim()).filter(Boolean).forEach((k) => kinds.add(k));
      }
      if (kindsCsv) {
        kindsCsv.split(',').map((s) => s.trim()).filter(Boolean).forEach((k) => kinds.add(k));
      }
      const prefixes = prefixesCsv
        ? prefixesCsv.split(',').map((s) => s.trim()).filter(Boolean)
        : [];

      return {
        fullUrl: parsed.toString(),
        hasFilter: kinds.size > 0 || prefixes.length > 0,
        kinds,
        prefixes,
      };
    } catch {
      return null;
    }
  }

  function matchesSubscriber(filter, payload) {
    if (!filter || !filter.hasFilter) return true;
    if (!payload || typeof payload !== 'object') return false;
    const k = String(payload.kind || payload.event || '');
    if (!k) return false;
    if (filter.kinds.has(k)) return true;
    for (const pfx of filter.prefixes) {
      if (k.startsWith(pfx)) return true;
    }
    return false;
  }

  function ensureUpstream() {
    if (sharedUpstream || subscribers.size === 0) return;
    sharedReadyState = 0;
    const es = trackNative(new NativeEventSource('/api/ambient/stream'));
    sharedUpstream = es;

    es.onopen = (ev) => {
      sharedReadyState = 1;
      for (const sub of subscribers) {
        sub._notifyOpen(ev);
      }
    };

    es.onerror = (ev) => {
      sharedReadyState = es.readyState;
      for (const sub of subscribers) {
        sub._notifyError(ev);
      }
    };

    const dispatchRaw = (type, ev) => {
      let parsed = null;
      try {
        parsed = JSON.parse(ev.data);
      } catch {
        parsed = null;
      }
      for (const sub of subscribers) {
        if (!matchesSubscriber(sub._filter, parsed)) continue;
        sub._notifyEvent(type, ev);
      }
    };

    es.addEventListener('ambient', (ev) => dispatchRaw('ambient', ev));
    es.onmessage = (ev) => dispatchRaw('message', ev);
  }

  function maybeCloseUpstream() {
    if (subscribers.size > 0 || !sharedUpstream) return;
    try {
      sharedUpstream.close();
    } catch {}
    sharedUpstream = null;
    sharedReadyState = 2;
  }

  class VirtualAmbientEventSource {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSED = 2;

    constructor(rawUrl, options) {
      this._filter = parseFilters(rawUrl);
      this.url = this._filter ? this._filter.fullUrl : String(rawUrl);
      this.withCredentials = !!(options && options.withCredentials);
      this.onopen = null;
      this.onmessage = null;
      this.onerror = null;
      this._closed = false;
      this._listeners = new Map();

      subscribers.add(this);
      ensureUpstream();
      if (sharedReadyState === 1) {
        queueMicrotask(() => {
          if (!this._closed) this._notifyOpen(new Event('open'));
        });
      }
    }

    get readyState() {
      if (this._closed) return 2;
      return sharedUpstream ? sharedUpstream.readyState : sharedReadyState;
    }

    addEventListener(type, listener) {
      if (typeof listener !== 'function') return;
      let set = this._listeners.get(type);
      if (!set) {
        set = new Set();
        this._listeners.set(type, set);
      }
      set.add(listener);
    }

    removeEventListener(type, listener) {
      const set = this._listeners.get(type);
      if (set) set.delete(listener);
    }

    dispatchEvent(ev) {
      this._notifyEvent(ev.type, ev);
      return true;
    }

    close() {
      if (this._closed) return;
      this._closed = true;
      this._listeners.clear();
      subscribers.delete(this);
      maybeCloseUpstream();
    }

    _notifyOpen(ev) {
      if (this._closed) return;
      if (typeof this.onopen === 'function') {
        try { this.onopen(ev); } catch {}
      }
      const set = this._listeners.get('open');
      if (set) set.forEach((fn) => { try { fn(ev); } catch {} });
    }

    _notifyError(ev) {
      if (this._closed) return;
      if (typeof this.onerror === 'function') {
        try { this.onerror(ev); } catch {}
      }
      const set = this._listeners.get('error');
      if (set) set.forEach((fn) => { try { fn(ev); } catch {} });
    }

    _notifyEvent(type, ev) {
      if (this._closed) return;
      if (type === 'message' && typeof this.onmessage === 'function') {
        try { this.onmessage(ev); } catch {}
      }
      const set = this._listeners.get(type);
      if (set) set.forEach((fn) => { try { fn(ev); } catch {} });
    }
  }

  function MultiplexedEventSource(url, options) {
    const filter = parseFilters(url);
    if (filter) {
      return new VirtualAmbientEventSource(url, options);
    }
    return trackNative(new NativeEventSource(url, options));
  }

  MultiplexedEventSource.CONNECTING = 0;
  MultiplexedEventSource.OPEN = 1;
  MultiplexedEventSource.CLOSED = 2;

  window.EventSource = MultiplexedEventSource;

  const tearDownAll = () => {
    subscribers.clear();
    if (sharedUpstream) {
      try { sharedUpstream.close(); } catch {}
      sharedUpstream = null;
    }
    for (const es of Array.from(activeNativeStreams)) {
      try { es.close(); } catch {}
    }
    activeNativeStreams.clear();
  };

  window.addEventListener('pagehide', tearDownAll);
  window.addEventListener('beforeunload', tearDownAll);
})();
