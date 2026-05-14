// Chump v2 — vanilla Web Components app shell.
// No build step, no CDN dependencies. Air-gap safe by construction.

// ── chumpPrefs: localStorage namespace + try/catch wrapper (INFRA-1280) ─────
// Every PWA preference lives under the `chump.*` localStorage namespace.
// Schema doc: docs/api/PWA_STATE_SCHEMA.md. Each consumer reads/writes via
// this helper, so:
//   - corruption never breaks the UI (try/catch + default fallback)
//   - every write emits kind=pwa_pref_changed for telemetry / adoption signal
//   - one place to grep for every persisted preference
//
// Privacy: no PII (no API tokens, no user content). session_ids + gap_ids OK.
window.chumpPrefs = window.chumpPrefs || (() => {
  const NS = 'chump.';
  function k(key) { return key.startsWith(NS) ? key : NS + key; }
  function emit(key, valueClass) {
    // Best-effort ambient signal via a sendBeacon-style fetch; never block.
    try {
      const ts = new Date().toISOString();
      // The /api/ambient/emit endpoint may not exist on every binary; fail silent.
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'pwa_pref_changed', key, value_class: valueClass, ts,
      }));
    } catch {}
  }
  return {
    /** Read a JSON-serialised pref. Returns `fallback` on miss or parse error. */
    get(key, fallback = null) {
      try {
        const raw = localStorage.getItem(k(key));
        if (raw == null) return fallback;
        return JSON.parse(raw);
      } catch {
        return fallback;
      }
    },
    /** Write a pref. Stringifies to JSON. Emits telemetry. */
    set(key, value) {
      try {
        localStorage.setItem(k(key), JSON.stringify(value));
        const cls = value == null ? 'null'
                  : typeof value === 'boolean' ? 'bool'
                  : typeof value === 'number'  ? 'number'
                  : Array.isArray(value)       ? 'array'
                  : typeof value === 'object'  ? 'object'
                                               : 'string';
        emit(k(key), cls);
        return true;
      } catch {
        return false;
      }
    },
    /** Remove a single pref. */
    del(key) {
      try { localStorage.removeItem(k(key)); return true; } catch { return false; }
    },
    /** Wipe ALL chump.* prefs. Used by Settings → Reset all preferences. */
    resetAll() {
      try {
        const keys = [];
        for (let i = 0; i < localStorage.length; i++) {
          const key = localStorage.key(i);
          if (key && key.startsWith(NS)) keys.push(key);
        }
        keys.forEach(key => localStorage.removeItem(key));
        emit('*', 'reset_all');
        return keys.length;
      } catch { return 0; }
    },
  };
})();

// ── Theme: apply persisted theme BEFORE first paint (avoid flash) ───────────
(() => {
  const t = window.chumpPrefs.get('theme', 'system');
  function effectiveTheme(pref) {
    if (pref === 'light' || pref === 'dark' || pref === 'high-contrast') return pref;
    // 'system' → follow OS
    return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  document.documentElement.setAttribute('data-theme', effectiveTheme(t));
  // React to OS theme changes when in system mode.
  window.matchMedia?.('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (window.chumpPrefs.get('theme', 'system') === 'system') {
      document.documentElement.setAttribute('data-theme', effectiveTheme('system'));
    }
  });
})();

// ── DashboardStream singleton (PRODUCT-099) ──────────────────────────────────
// Frontend was polling /api/dashboard, /api/jobs, /api/fleet-status, /api/gap-queue
// on 3 different setInterval timers (5/10/15s). Meanwhile the backend has been
// shipping SSE at /api/dashboard/stream that nobody consumed. Wire it up.
//
// This is a tiny event bus: ONE EventSource for the whole app; views subscribe
// via window.chumpStream.subscribe(callback). Reconnect with backoff on error.
// Pauses when the document is hidden (battery win on phone).
//
// Visible status: dispatches CustomEvent('chump:stream-status', { detail: 'live'|'reconnecting'|'paused'|'offline' })
// so any component can render a live indicator.
class DashboardStream {
  #es = null;
  #subs = new Set();
  #status = 'init';
  #reconnectDelayMs = 1000;       // grows on failure, resets on success
  #reconnectTimer = null;
  #visibilityHooked = false;
  #onlineHooked = false;
  #lastEventAt = 0;
  #lastPayload = null;            // replayed to late subscribers

  start() {
    if (this.#visibilityHooked === false) {
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'hidden') {
          this.#close('paused');
        } else if (this.#status === 'paused' || this.#status === 'offline') {
          this.#open();
        }
      });
      this.#visibilityHooked = true;
    }
    if (this.#onlineHooked === false) {
      window.addEventListener('offline', () => this.#close('offline'));
      window.addEventListener('online', () => {
        if (document.visibilityState !== 'hidden') this.#open();
      });
      this.#onlineHooked = true;
    }
    if (document.visibilityState !== 'hidden') this.#open();
  }

  subscribe(fn) {
    this.#subs.add(fn);
    // Replay the most recent payload so late subscribers don't wait 30s
    // for the next dashboard tick.
    if (this.#lastPayload) {
      try { fn(this.#lastPayload); } catch {}
    }
    return () => this.#subs.delete(fn);
  }

  status() { return this.#status; }
  lastEventAt() { return this.#lastEventAt; }

  #setStatus(next) {
    if (next === this.#status) return;
    this.#status = next;
    document.dispatchEvent(new CustomEvent('chump:stream-status', { detail: next }));
  }

  #open() {
    this.#clearReconnect();
    if (this.#es) { try { this.#es.close(); } catch {} this.#es = null; }
    try {
      this.#es = new EventSource('/api/dashboard/stream');
    } catch (e) {
      this.#scheduleReconnect();
      return;
    }
    this.#setStatus('connecting');
    this.#es.addEventListener('dashboard', (ev) => {
      this.#lastEventAt = Date.now();
      this.#setStatus('live');
      this.#reconnectDelayMs = 1000;
      let data = null;
      try { data = JSON.parse(ev.data); } catch { return; }
      const msg = { type: 'dashboard', data };
      this.#lastPayload = msg;
      this.#subs.forEach((fn) => { try { fn(msg); } catch {} });
    });
    this.#es.onerror = () => this.#scheduleReconnect();
  }

  #close(reason) {
    this.#clearReconnect();
    if (this.#es) { try { this.#es.close(); } catch {} this.#es = null; }
    this.#setStatus(reason);
  }

  #scheduleReconnect() {
    this.#clearReconnect();
    if (this.#es) { try { this.#es.close(); } catch {} this.#es = null; }
    this.#setStatus('reconnecting');
    // Full jitter on the base delay so concurrent clients don't reconnect-stampede.
    const jitter = Math.random() * 0.5 + 0.75; // 0.75x – 1.25x
    const delay = Math.round(this.#reconnectDelayMs * jitter);
    this.#reconnectDelayMs = Math.min(this.#reconnectDelayMs * 2, 30_000);
    this.#reconnectTimer = setTimeout(() => {
      if (document.visibilityState !== 'hidden' && navigator.onLine !== false) {
        this.#open();
      }
    }, delay);
  }

  #clearReconnect() {
    if (this.#reconnectTimer) { clearTimeout(this.#reconnectTimer); this.#reconnectTimer = null; }
  }
}

window.chumpStream = window.chumpStream || new DashboardStream();
window.addEventListener('DOMContentLoaded', () => window.chumpStream.start());

// ── <chump-nav> ───────────────────────────────────────────────────────────────
class ChumpNav extends HTMLElement {
  static #ITEMS = [
    { id: 'chat',      label: 'Chat',      icon: '💬' },
    { id: 'agents',    label: 'Agents',    icon: '🤝' },
    { id: 'results',   label: 'Results',   icon: '📊' },
    { id: 'agent',     label: 'Queue',     icon: '🔄' },
    { id: 'tasks',     label: 'Tasks',     icon: '⚡' },
    { id: 'decisions', label: 'Decisions', icon: '🎯' },
    { id: 'judgment',  label: 'Judgment',  icon: '⚖️' },
    { id: 'ambient',   label: 'Events',    icon: '📡' },
    { id: 'memory',    label: 'Memory',    icon: '🧠' },
    { id: 'models',    label: 'Models',    icon: '🤖' },
    { id: 'settings',  label: 'Settings',  icon: '⚙' },
  ];

  connectedCallback() {
    this.innerHTML = ChumpNav.#ITEMS.map((item) => `
      <button class="nav-item" data-view="${item.id}" aria-label="${item.label}">
        <span class="nav-icon">${item.icon}</span>
        <span class="nav-label">${item.label}</span>
      </button>
    `).join('');

    this.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-view]');
      if (!btn) return;
      this.querySelectorAll('[data-view]').forEach((b) => b.removeAttribute('aria-current'));
      btn.setAttribute('aria-current', 'page');
      document.dispatchEvent(new CustomEvent('chump:navigate', { detail: btn.dataset.view }));
    });

    // Default selection.
    this.querySelector('[data-view="chat"]')?.setAttribute('aria-current', 'page');
  }
}
customElements.define('chump-nav', ChumpNav);

// ── <chump-model-indicator> ───────────────────────────────────────────────────
class ChumpModelIndicator extends HTMLElement {
  connectedCallback() {
    this.render('detecting…');
    this.#poll();
  }

  render(label) {
    this.innerHTML = `<span class="model-chip" title="Current model">${label}</span>`;
  }

  #poll() {
    fetch('/api/health')
      .then((r) => r.json())
      .then((d) => {
        const model = d.model_id || d.active_model || 'local';
        this.render(model);
      })
      .catch(() => this.render('offline'));
  }
}
customElements.define('chump-model-indicator', ChumpModelIndicator);

// ── <chump-heartbeat> ─────────────────────────────────────────────────────────
class ChumpHeartbeat extends HTMLElement {
  #timer = null;

  connectedCallback() {
    this.#tick();
    this.#timer = setInterval(() => this.#tick(), 15_000);
  }

  disconnectedCallback() {
    clearInterval(this.#timer);
  }

  #tick() {
    fetch('/api/health')
      .then((r) => r.json())
      .then((d) => {
        const ts = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
        const sessions = d.active_sessions ?? '—';
        this.innerHTML = `<span class="hb-dot online" title="Agent online"></span><span class="hb-text">online · ${sessions} sessions · ${ts}</span>`;
      })
      .catch(() => {
        this.innerHTML = `<span class="hb-dot offline" title="Agent offline"></span><span class="hb-text">offline</span>`;
      });
  }
}
customElements.define('chump-heartbeat', ChumpHeartbeat);

// ── <chump-doctor-banner> (INFRA-990) ───────────────────────────────────────
//
// Persistent banner that surfaces config-health failures from
// GET /api/health/doctor. Renders nothing while ok=true. While ok=false,
// renders a sticky strip listing each failure with a "Configure" button
// linking to the settings view. Re-polls every 30s; on transition to ok=true
// shows a one-shot "✓ Configuration green" toast and self-hides.
//
// Accessibility: focusable Configure button, ARIA region label. ESC does NOT
// dismiss (AC #4) — banner is persistent until doctor goes green.
class ChumpDoctorBanner extends HTMLElement {
  #timer = null;
  #lastOk = null; // null | true | false — used to detect ok=false → ok=true transition

  connectedCallback() {
    this.setAttribute('role', 'region');
    this.setAttribute('aria-label', 'Configuration health');
    this.style.display = 'none'; // hidden until first poll resolves to ok=false
    this.#poll();
    this.#timer = setInterval(() => this.#poll(), 30_000);
  }

  disconnectedCallback() {
    if (this.#timer) {
      clearInterval(this.#timer);
      this.#timer = null;
    }
  }

  async #poll() {
    let data;
    try {
      const r = await fetch('/api/health/doctor', { headers: { 'Accept': 'application/json' } });
      data = await r.json();
    } catch (err) {
      // Network down or endpoint missing — don't render anything; the
      // existing offline-banner already covers the "PWA can't reach itself"
      // case. Keep this widget silent.
      return;
    }

    if (data.ok === true) {
      if (this.#lastOk === false) {
        // We just transitioned from failing → green. One-shot toast.
        this.#renderToast();
        setTimeout(() => { this.style.display = 'none'; this.innerHTML = ''; }, 3000);
      } else {
        this.style.display = 'none';
        this.innerHTML = '';
      }
      this.#lastOk = true;
      return;
    }

    this.#lastOk = false;
    this.style.display = 'block';
    const failures = Array.isArray(data.failures) ? data.failures : [];
    const items = failures.map((f) => {
      const fix = f.fix_hint ? ` — <span class="fix-hint">${this.#esc(f.fix_hint)}</span>` : '';
      return `<li><strong>${this.#esc(f.check)}</strong>: ${this.#esc(f.message)}${fix}</li>`;
    }).join('');
    this.innerHTML = `
      <div class="doctor-banner-inner">
        <div class="doctor-banner-head">
          <strong>Configuration needed before fleet can run</strong>
        </div>
        <ul class="doctor-banner-list">${items}</ul>
        <div class="doctor-banner-actions">
          <button type="button" class="doctor-configure" aria-label="Open settings to configure">Configure</button>
        </div>
      </div>
    `;
    const btn = this.querySelector('.doctor-configure');
    if (btn) {
      btn.addEventListener('click', () => {
        document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'settings' }));
      });
    }
  }

  #renderToast() {
    this.style.display = 'block';
    this.innerHTML = `<div class="doctor-banner-inner doctor-banner-toast">✓ Configuration green — fleet ready</div>`;
  }

  #esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
}
customElements.define('chump-doctor-banner', ChumpDoctorBanner);

// ── <chump-auth-toast> (INFRA-991) ──────────────────────────────────────────
//
// Surfaces kind=fleet_auth_fallback ambient events (emitted by src/auth.rs
// when an Anthropic 401 forces a mode swap) as actionable toasts so the
// operator can re-enter the broken credential without leaving the PWA.
//
// Subscribes to /api/ambient/stream?kind=fleet_auth_fallback (SSE — already
// exists for PRODUCT-091). Server-side kind filter means we don't process
// unrelated events. De-dup is client-side: at most one visible toast,
// counter increments on subsequent events in a 60s window.
//
// AC mapping:
//   1. EventSource subscribes to the existing endpoint
//   2. Toast renders with failed_mode + fallback_mode + "Re-enter key" button
//   3. De-dup ≤1 visible toast per 60s; counter shows "× N events in last 60s"
//   4. Auto-dismiss 5 min after last related event; manually dismissable
//   5. Test: synthetic line → toast visible within 2s (covered by SSE poll)
class ChumpAuthToast extends HTMLElement {
  #es = null;
  #count = 0;
  #lastEventTs = 0;
  #autoDismissTimer = null;
  #latestEvent = null; // most recent {failed_mode, fallback_mode}

  // De-dup window: subsequent events within this window increment the
  // counter on the visible toast instead of replacing it.
  static DEDUP_WINDOW_MS = 60_000;
  // Auto-dismiss timer: cleared and restarted on each new event.
  static AUTO_DISMISS_MS = 5 * 60_000;

  connectedCallback() {
    this.setAttribute('role', 'alert');
    this.setAttribute('aria-live', 'polite');
    this.style.display = 'none';
    this.#subscribe();
  }

  disconnectedCallback() {
    if (this.#es) {
      this.#es.close();
      this.#es = null;
    }
    if (this.#autoDismissTimer) {
      clearTimeout(this.#autoDismissTimer);
      this.#autoDismissTimer = null;
    }
  }

  #subscribe() {
    try {
      this.#es = new EventSource('/api/ambient/stream?kind=fleet_auth_fallback');
    } catch (err) {
      // EventSource unsupported — render nothing. Operator falls back to
      // tailing ambient.jsonl in a terminal (the pre-INFRA-991 status quo).
      return;
    }
    this.#es.addEventListener('ambient', (e) => {
      let payload;
      try { payload = JSON.parse(e.data); } catch { return; }
      if (payload.kind !== 'fleet_auth_fallback') return;
      this.#onEvent(payload);
    });
    this.#es.addEventListener('error', () => {
      // EventSource auto-reconnects; we just need to not crash. If the
      // server is down the doctor-banner will catch it.
    });
  }

  #onEvent(payload) {
    const now = Date.now();
    const withinWindow = (now - this.#lastEventTs) < ChumpAuthToast.DEDUP_WINDOW_MS;
    this.#lastEventTs = now;
    this.#latestEvent = payload;
    if (this.#count > 0 && withinWindow && this.style.display !== 'none') {
      this.#count += 1;
    } else {
      this.#count = 1;
    }
    this.#render();
    this.#restartAutoDismiss();
  }

  #restartAutoDismiss() {
    if (this.#autoDismissTimer) clearTimeout(this.#autoDismissTimer);
    this.#autoDismissTimer = setTimeout(() => this.#dismiss(), ChumpAuthToast.AUTO_DISMISS_MS);
  }

  #dismiss() {
    this.style.display = 'none';
    this.innerHTML = '';
    this.#count = 0;
    this.#latestEvent = null;
    if (this.#autoDismissTimer) {
      clearTimeout(this.#autoDismissTimer);
      this.#autoDismissTimer = null;
    }
  }

  #render() {
    if (!this.#latestEvent) return;
    const failed = this.#esc(this.#latestEvent.failed_mode || 'unknown');
    const fallback = this.#esc(this.#latestEvent.fallback_mode || 'unknown');
    const counter = this.#count > 1
      ? `<span class="auth-toast-counter">× ${this.#count} events in last 60s</span>`
      : '';
    this.style.display = 'block';
    this.innerHTML = `
      <div class="auth-toast-inner">
        <div class="auth-toast-head"><strong>Anthropic auth failed</strong> ${counter}</div>
        <div class="auth-toast-body">Worker fell back to <strong>${fallback}</strong> after <strong>${failed}</strong> mode failed.</div>
        <div class="auth-toast-actions">
          <button type="button" class="auth-toast-reenter">Re-enter key</button>
          <button type="button" class="auth-toast-dismiss" aria-label="Dismiss">Dismiss</button>
        </div>
      </div>
    `;
    const reenter = this.querySelector('.auth-toast-reenter');
    if (reenter) {
      reenter.addEventListener('click', () => {
        document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'settings' }));
      });
    }
    const dismiss = this.querySelector('.auth-toast-dismiss');
    if (dismiss) {
      dismiss.addEventListener('click', () => this.#dismiss());
    }
  }

  #esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
}
customElements.define('chump-auth-toast', ChumpAuthToast);

// ── <chump-view-tasks> ────────────────────────────────────────────────────────
class ChumpViewTasks extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Tasks</h2>
        <p class="view-subtitle">Active and recent agent tasks</p>
      </section>
      <section class="task-list" id="task-list">
        <p class="placeholder">Loading tasks…</p>
      </section>
    `;
    this.#load();
  }

  #load() {
    const list = this.querySelector('#task-list');
    fetch('/api/tasks')
      .then((r) => r.json())
      .then((tasks) => {
        if (!Array.isArray(tasks) || tasks.length === 0) {
          list.innerHTML = '<p class="placeholder">No tasks yet. Start a session to create one.</p>';
          return;
        }
        list.innerHTML = tasks.slice(0, 20).map((t) => `
          <article class="task-card">
            <header class="task-card-header">
              <span class="task-status ${t.status ?? 'unknown'}">${t.status ?? 'unknown'}</span>
              <span class="task-id">${t.id ?? ''}</span>
            </header>
            <p class="task-desc">${t.description ?? t.title ?? '(no description)'}</p>
          </article>
        `).join('');
      })
      .catch(() => {
        list.innerHTML = '<p class="placeholder">Could not load tasks (offline or server not running).</p>';
      });
  }
}
customElements.define('chump-view-tasks', ChumpViewTasks);

// ── <chump-view-memory> ───────────────────────────────────────────────────────
class ChumpViewMemory extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Memory</h2>
        <p class="view-subtitle">Lessons learned and persistent context</p>
      </section>
      <section class="memory-list" id="memory-list">
        <p class="placeholder">Loading memory…</p>
      </section>
    `;
    this.#load();
  }

  #load() {
    const list = this.querySelector('#memory-list');
    fetch('/api/briefing')
      .then((r) => r.json())
      .then((d) => {
        const items = d.lessons ?? d.memories ?? [];
        if (items.length === 0) {
          list.innerHTML = '<p class="placeholder">No lessons recorded yet.</p>';
          return;
        }
        list.innerHTML = items.slice(0, 30).map((item) => `
          <article class="memory-card">
            <p class="memory-text">${typeof item === 'string' ? item : (item.content ?? item.lesson ?? JSON.stringify(item))}</p>
          </article>
        `).join('');
      })
      .catch(() => {
        list.innerHTML = '<p class="placeholder">Memory unavailable (offline or server not running).</p>';
      });
  }
}
customElements.define('chump-view-memory', ChumpViewMemory);

// ── <chump-parallelism-governor> ─────────────────────────────────────────────
class ChumpParallelismGovernor extends HTMLElement {
  connectedCallback() {
    const saved = localStorage.getItem('parallelism-limit') || '4';
    this.innerHTML = `
      <label class="setting-row">
        <span class="setting-label">Parallelism Governor</span>
        <input
          type="range"
          min="1"
          max="16"
          value="${saved}"
          id="parallelism-slider"
          class="setting-slider"
          aria-label="Max concurrent operations"
        />
        <span class="setting-value" id="parallelism-value">${saved}</span>
      </label>
    `;
    this.querySelector('#parallelism-slider')?.addEventListener('change', (e) => {
      localStorage.setItem('parallelism-limit', e.target.value);
      this.querySelector('#parallelism-value').textContent = e.target.value;
      document.dispatchEvent(new CustomEvent('chump:parallelism-changed', { detail: parseInt(e.target.value) }));
    });
  }
}
customElements.define('chump-parallelism-governor', ChumpParallelismGovernor);

// ── <chump-view-decisions> ────────────────────────────────────────────────────
class ChumpViewDecisions extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Decisions</h2>
        <p class="view-subtitle">Decision channel inbox — pending actions</p>
      </section>
      <section class="decisions-list" id="decisions-list">
        <p class="placeholder">Loading decisions…</p>
      </section>
    `;
    this.#load();
  }

  #load() {
    const list = this.querySelector('#decisions-list');
    fetch('/api/decisions')
      .then((r) => r.json())
      .then((decisions) => {
        if (!Array.isArray(decisions) || decisions.length === 0) {
          list.innerHTML = '<p class="placeholder">No pending decisions. All caught up!</p>';
          return;
        }
        list.innerHTML = decisions.slice(0, 30).map((d) => {
          const priority = d.priority || 'normal';
          const action = d.action || 'decision';
          return `
            <article class="task-card">
              <header class="task-card-header">
                <span class="task-status ${priority}">${priority}</span>
                <span class="task-id">${d.id ?? ''}</span>
              </header>
              <p class="task-desc"><strong>${action}</strong></p>
              ${d.context ? `<p class="task-desc" style="color: var(--text-secondary); font-size: 12px; margin-top: 4px;">${d.context}</p>` : ''}
            </article>
          `;
        }).join('');
      })
      .catch(() => {
        list.innerHTML = '<p class="placeholder">Could not load decisions (offline or server not running).</p>';
      });
  }
}
customElements.define('chump-view-decisions', ChumpViewDecisions);

// ── <chump-view-judgment> (PRODUCT-079) ───────────────────────────────────────
class ChumpViewJudgment extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Needs Your Judgment</h2>
        <p class="view-subtitle">Gaps and events waiting on operator input</p>
      </section>
      <section class="task-list" id="judgment-list">
        <p class="placeholder">Loading…</p>
      </section>
    `;
    this.#load();
  }

  #load() {
    const list = this.querySelector('#judgment-list');
    fetch('/api/needs-judgment')
      .then((r) => r.json())
      .then((data) => {
        const items = data.items ?? [];
        if (items.length === 0) {
          const ago = data.last_decision_ts
            ? `Last operator decision: ${data.last_decision_ts}`
            : 'No prior decisions recorded';
          list.innerHTML = `<p class="placeholder">Fleet is moving without you. ${ago}</p>`;
          return;
        }
        list.innerHTML = items.map((item) => `
          <article class="task-card" data-id="${item.id}" data-type="${item.item_type}">
            <header class="task-card-header">
              <span class="task-status ${item.item_type}">${item.item_type}</span>
              <span class="task-id">${item.id}</span>
              ${item.priority ? `<span style="margin-left:auto;font-size:11px;opacity:.7">${item.priority}</span>` : ''}
            </header>
            <p class="task-desc">${item.summary ?? '(no summary)'}</p>
            ${item.recommended_action ? `<p class="task-desc" style="color:var(--text-secondary);font-size:12px">${item.recommended_action}</p>` : ''}
            <button class="judgment-ack-btn" style="margin-top:8px;padding:4px 10px;cursor:pointer;border-radius:4px;border:1px solid var(--border-color);background:transparent;color:var(--text-primary);font-size:12px"
              data-id="${item.id}" data-type="${item.item_type}">Mark handled</button>
          </article>
        `).join('');

        list.querySelectorAll('.judgment-ack-btn').forEach((btn) => {
          btn.addEventListener('click', () => this.#ack(btn.dataset.id, btn.dataset.type, btn));
        });
      })
      .catch(() => {
        list.innerHTML = '<p class="placeholder">Could not load (offline or server not running).</p>';
      });
  }

  #ack(itemId, itemType, btn) {
    btn.disabled = true;
    btn.textContent = 'Marking…';
    fetch('/api/needs-judgment/ack', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ item_type: itemType, item_id: itemId }),
    })
      .then(() => {
        const card = btn.closest('article');
        if (card) card.style.opacity = '0.4';
        btn.textContent = 'Handled';
      })
      .catch(() => {
        btn.disabled = false;
        btn.textContent = 'Mark handled';
      });
  }
}
customElements.define('chump-view-judgment', ChumpViewJudgment);

// ── <chump-view-settings> ─────────────────────────────────────────────────────
class ChumpViewSettings extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Settings</h2>
        <p class="view-subtitle">v2 shell · Chump PWA rebuild (PRODUCT-012, PRODUCT-044)</p>
      </section>
      <section class="settings-grid">
        <label class="setting-row">
          <span class="setting-label">Version</span>
          <span class="setting-value">v2-alpha (PRODUCT-012 shell + phase 3)</span>
        </label>
        <label class="setting-row">
          <span class="setting-label">Framework</span>
          <span class="setting-value">Vanilla JS + Web Components (no build)</span>
        </label>
        <label class="setting-row">
          <span class="setting-label">Offline</span>
          <span class="setting-value">Service Worker active — shell cached</span>
        </label>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">Appearance (INFRA-1280 Sub-gap 4)</p>
          <div id="theme-toggle" role="radiogroup" aria-label="Theme">
            <label style="display:inline-flex;align-items:center;gap:6px;margin-right:14px;">
              <input type="radio" name="chump-theme" value="system"> System
            </label>
            <label style="display:inline-flex;align-items:center;gap:6px;margin-right:14px;">
              <input type="radio" name="chump-theme" value="light"> Light
            </label>
            <label style="display:inline-flex;align-items:center;gap:6px;margin-right:14px;">
              <input type="radio" name="chump-theme" value="dark"> Dark
            </label>
            <label style="display:inline-flex;align-items:center;gap:6px;">
              <input type="radio" name="chump-theme" value="high-contrast"> High contrast
            </label>
          </div>
          <p style="color: var(--text-muted); font-size: 0.8em; margin-top: 6px;">
            Default: System (follows OS prefers-color-scheme).
          </p>
        </div>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">Inference Settings</p>
          <div id="cascade-slots" style="margin-bottom: 16px; font-size: 0.9em; color: var(--text-muted);">
            <p>Loading cascade slot info…</p>
          </div>
        </div>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">Fleet Control</p>
          <chump-parallelism-governor></chump-parallelism-governor>
        </div>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">Operator Configuration (INFRA-988)</p>
          <div id="operator-config" style="font-size: 0.9em;">
            <p style="color: var(--text-muted);">Loading operator config…</p>
          </div>
          <p style="color: var(--text-muted); font-size: 0.8em; margin-top: 8px;">
            Stored in <code>~/.chump/config.toml</code> [settings]. Env vars override.
            Secrets are managed separately (INFRA-989).
          </p>
        </div>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">PWA Preferences (INFRA-1280)</p>
          <p style="color: var(--text-muted); font-size: 0.85em; margin-bottom: 8px;">
            Theme + queue filters + (future) sidecar / cost thresholds / stream pause are persisted
            under the <code>chump.*</code> localStorage namespace. Schema:
            <code>docs/api/PWA_STATE_SCHEMA.md</code>.
          </p>
          <button type="button" id="chump-prefs-reset" class="chump-prefs-reset" aria-label="Reset all PWA preferences" style="padding:6px 12px;border:1px solid var(--accent-error,#cc3344);background:transparent;color:var(--accent-error,#cc3344);border-radius:6px;cursor:pointer;font-size:0.9em;">
            Reset all preferences
          </button>
          <p style="color: var(--text-muted); font-size: 0.75em; margin-top: 6px;">
            Wipes every <code>chump.*</code> key from localStorage and reloads.
          </p>
        </div>
      </section>
    `;
    this.#loadCascadeInfo();
    this.#loadOperatorConfig();
    this.#wireThemeToggle();
    this.#wireResetButton();
  }

  // INFRA-1280 Sub-gap 4: theme toggle (System/Light/Dark/High-contrast).
  // Reads stored pref, checks the right radio, persists changes, repaints.
  #wireThemeToggle() {
    const current = window.chumpPrefs.get('theme', 'system');
    const radios = this.querySelectorAll('input[name="chump-theme"]');
    radios.forEach(r => {
      if (r.value === current) r.checked = true;
      r.addEventListener('change', (e) => {
        const v = e.target.value;
        window.chumpPrefs.set('theme', v);
        const effective = (v === 'system')
          ? (window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
          : v;
        document.documentElement.setAttribute('data-theme', effective);
      });
    });
  }

  // INFRA-1280 Sub-gap 9: Reset-all wipes every chump.* localStorage key.
  // Confirms before nuking so accidental clicks don't surprise the operator.
  #wireResetButton() {
    const btn = this.querySelector('#chump-prefs-reset');
    btn?.addEventListener('click', () => {
      if (!confirm('Reset ALL PWA preferences (theme, queue filters, etc.)?\n\nThis will reload the page.')) return;
      const wiped = window.chumpPrefs.resetAll();
      btn.textContent = `Wiped ${wiped} keys — reloading…`;
      btn.disabled = true;
      setTimeout(() => location.reload(), 400);
    });
  }

  // INFRA-988: render non-secret config fields from /api/settings.
  // Each field shows value + source badge (env / config / default).
  #loadOperatorConfig() {
    const container = this.querySelector('#operator-config');
    fetch('/api/settings')
      .then(r => r.json())
      .then(data => {
        const fields = [
          { key: 'CHUMP_AUTH_MODE', label: 'Auth mode', options: ['auto', 'api-key', 'oauth'] },
          { key: 'CHUMP_MULTI_REPO_ENABLED', label: 'Multi-repo', options: ['0', '1'] },
          { key: 'FLEET_SIZE', label: 'Fleet size', type: 'number', min: 0, max: 64 },
          { key: 'FLEET_MODEL', label: 'Fleet model', options: ['haiku', 'sonnet', 'opus'] },
          { key: 'CHUMP_ROUND_PRIVACY', label: 'Round privacy', options: ['safe', 'dogfood'] },
          { key: 'CHUMP_REPO', label: 'Working repo path', type: 'text' },
        ];
        container.innerHTML = fields.map(f => {
          const entry = data[f.key] || { value: '', source: 'default' };
          const badge = `<span class="op-config-badge op-config-badge-${entry.source}">${entry.source}</span>`;
          const envLocked = entry.source === 'env';
          const lockedAttr = envLocked ? 'disabled title="Set via env var — unset env to edit via PWA"' : '';
          let input;
          if (f.options) {
            input = `<select data-key="${f.key}" ${lockedAttr}>${f.options.map(o => `<option value="${o}" ${o === entry.value ? 'selected' : ''}>${o}</option>`).join('')}</select>`;
          } else {
            const min = f.min != null ? `min="${f.min}"` : '';
            const max = f.max != null ? `max="${f.max}"` : '';
            input = `<input type="${f.type}" data-key="${f.key}" value="${entry.value}" ${min} ${max} ${lockedAttr}>`;
          }
          return `
            <div class="op-config-row" style="display:flex;align-items:center;gap:8px;margin-bottom:6px;">
              <label style="flex:1;">${f.label}</label>
              ${input}
              ${badge}
            </div>`;
        }).join('');
        container.querySelectorAll('[data-key]').forEach(el => {
          el.addEventListener('change', e => this.#onConfigChange(e));
        });
      })
      .catch(err => {
        container.innerHTML = `<p style="color:var(--error-color)">Error loading config: ${err.message}</p>`;
      });
  }

  #onConfigChange(e) {
    const el = e.target;
    const key = el.dataset.key;
    const value = el.value;
    el.disabled = true;
    fetch(`/api/settings/${encodeURIComponent(key)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'pwa' },
      body: JSON.stringify({ value }),
    })
      .then(r => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then(() => this.#loadOperatorConfig())
      .catch(err => {
        console.error(`settings POST ${key} failed:`, err);
        el.disabled = false;
      });
  }

  // PRODUCT-054: load real cascade slot data and render toggle switches.
  #loadCascadeInfo() {
    const container = this.querySelector('#cascade-slots');
    fetch('/api/cascade-status')
      .then(r => r.json())
      .then(data => {
        if (!data || !data.slots) {
          container.innerHTML = '<p class="cascade-empty">No cascade slots configured.</p>';
          return;
        }
        if (data.slots.length === 0) {
          container.innerHTML = '<p class="cascade-empty">Cascade disabled — no slots found.</p>';
          return;
        }
        container.innerHTML = data.slots.map(slot => {
          const disabled = !!slot.disabled_by_config;
          const circuit = slot.circuit_state || 'ok';
          const circuitBadge = circuit === 'open'
            ? '<span class="cascade-badge cascade-badge-err">circuit open</span>'
            : circuit === 'half_open'
              ? '<span class="cascade-badge cascade-badge-warn">half-open</span>'
              : '';
          const rpm = slot.rpm_limit > 0 ? `${slot.calls_this_minute}/${slot.rpm_limit} rpm` : '';
          const rpd = slot.rpd_limit > 0 ? `${slot.calls_today}/${slot.rpd_limit} rpd` : '';
          const stats = [rpm, rpd].filter(Boolean).join(' · ');
          return `
            <div class="cascade-slot-row ${disabled ? 'cascade-slot-disabled' : ''}">
              <div class="cascade-slot-info">
                <span class="cascade-slot-name">${slot.name}</span>
                ${circuitBadge}
                ${stats ? `<span class="cascade-slot-stats">${stats}</span>` : ''}
              </div>
              <label class="cascade-toggle" title="${disabled ? 'Enable slot' : 'Disable slot'}">
                <input type="checkbox" class="cascade-toggle-input"
                  data-slot="${slot.name}"
                  ${disabled ? '' : 'checked'}
                  ${circuit === 'open' ? 'disabled' : ''}>
                <span class="cascade-toggle-track"></span>
              </label>
            </div>`;
        }).join('');
        // Wire toggle events
        container.querySelectorAll('.cascade-toggle-input').forEach(cb => {
          cb.addEventListener('change', e => this.#onSlotToggle(e));
        });
      })
      .catch(err => {
        container.innerHTML = `<p style="color:var(--error-color)">Error: ${err.message}</p>`;
      });
  }

  #onSlotToggle(e) {
    const cb = e.target;
    const slot = cb.dataset.slot;
    const enabled = cb.checked;
    cb.disabled = true;
    fetch('/api/cascade-slot-toggle', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ slot, enabled }),
    })
      .then(r => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then(() => {
        // Refresh to reflect saved state
        this.#loadCascadeInfo();
      })
      .catch(err => {
        cb.checked = !enabled; // revert optimistic toggle
        cb.disabled = false;
        console.error('cascade-slot-toggle failed:', err);
      });
  }
}
customElements.define('chump-view-settings', ChumpViewSettings);

// ── <chump-view-agents> (PRODUCT-059) ────────────────────────────────────────
// Read-only live results board: one card per active .chump-locks/*.json session.
// Polls /api/fleet-status every 10 seconds. Works without GitHub access (PR fields
// are shown only when the gh CLI is available on the server).
class ChumpViewAgents extends HTMLElement {
  #timer = null;

  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Agents</h2>
        <p class="view-subtitle">Active fleet sessions — leases, PRs, and CI status</p>
      </section>
      <p class="agents-refresh-note" id="agents-refresh-note">Refreshes every 10 s</p>
      <section class="agents-list" id="agents-list">
        <p class="placeholder">Loading active sessions…</p>
      </section>
    `;
    this.#load();
    this.#timer = setInterval(() => this.#load(), 10_000);
  }

  disconnectedCallback() {
    clearInterval(this.#timer);
  }

  #load() {
    const list = this.querySelector('#agents-list');
    const note = this.querySelector('#agents-refresh-note');
    fetch('/api/fleet-status')
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then((d) => {
        const sessions = d.sessions ?? [];
        const ts = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
        if (note) note.textContent = `${sessions.length} active session${sessions.length !== 1 ? 's' : ''} · last updated ${ts}`;

        if (sessions.length === 0) {
          list.innerHTML = '<p class="placeholder">No active agent sessions. The fleet is idle.</p>';
          return;
        }

        list.innerHTML = sessions.map((s) => {
          const gapId = s.gap_id || '—';
          const title = s.gap_title || '(no title)';
          const priority = s.gap_priority ? `${s.gap_priority}/${s.gap_effort || '?'}` : '';
          const branch = s.branch || '';
          const worktree = s.worktree_path || '';

          // PR link
          const prNum = s.pr_number;
          const prState = (s.pr_state || '').toLowerCase();
          const prHtml = prNum
            ? `<a class="agent-pr-link" href="https://github.com/${this.#repoSlug()}/pull/${prNum}" target="_blank" rel="noopener">#${prNum} ${prState}</a>`
            : '';

          // CI badge
          const ci = s.ci_status;
          const ciClass = ci === 'success' ? 'ci-success'
                        : ci === 'failure' ? 'ci-failure'
                        : ci === 'pending' ? 'ci-pending' : '';
          const ciBadge = ci ? `<span class="agent-ci-badge ${ciClass}">CI: ${ci}</span>` : '';

          // Heartbeat age
          const heartbeatAge = s.heartbeat_at ? this.#age(s.heartbeat_at) : '';

          return `
            <article class="agent-card">
              <header class="agent-card-header">
                <span class="agent-gap-id">${gapId}</span>
                ${ciBadge}
                ${priority ? `<span class="gap-priority">${priority}</span>` : ''}
                ${prHtml}
              </header>
              <p class="agent-gap-title">${title}</p>
              <div class="agent-meta">
                ${branch ? `<span title="Branch">🌿 ${branch}</span>` : ''}
                ${s.taken_at ? `<span title="Started">🕐 ${this.#age(s.taken_at)} ago</span>` : ''}
                ${heartbeatAge ? `<span title="Last heartbeat">💓 ${heartbeatAge} ago</span>` : ''}
              </div>
              ${worktree ? `<p class="agent-worktree" title="Worktree path">📂 ${worktree}</p>` : ''}
            </article>
          `;
        }).join('');
      })
      .catch((err) => {
        if (list) list.innerHTML = `<p class="placeholder">Could not load fleet status: ${err.message}</p>`;
      });
  }

  #repoSlug() {
    // Best-effort: extract owner/repo from the page origin (works when hosted
    // behind a reverse proxy that sets X-Repo-Slug). Falls back to the GitHub
    // origin for the known Chump repo.
    return 'jeffadkins/Chump';
  }

  #age(isoString) {
    try {
      const ms = Date.now() - new Date(isoString).getTime();
      const secs = Math.floor(ms / 1000);
      if (secs < 60) return `${secs}s`;
      const mins = Math.floor(secs / 60);
      if (mins < 60) return `${mins}m`;
      const hrs = Math.floor(mins / 60);
      return `${hrs}h ${mins % 60}m`;
    } catch {
      return '?';
    }
  }
}
customElements.define('chump-view-agents', ChumpViewAgents);

// ── <chump-view-results> ──────────────────────────────────────────────────────
class ChumpViewResults extends HTMLElement {
  #unsubscribe = null;

  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Results</h2>
        <p class="view-subtitle">Live status and job results <span id="stream-pill" class="stream-pill" style="font-size:11px;margin-left:8px;padding:2px 8px;border-radius:10px;background:var(--bg-muted, #2a2a2a);color:var(--text-secondary, #aaa);">— stream: init</span></p>
      </section>
      <section class="results-list" id="results-container">
        <p class="placeholder">Loading results…</p>
      </section>
    `;
    // Initial fetch in parallel with SSE so the page isn't empty for 30s.
    this.#load();
    // PRODUCT-099: subscribe to the SSE bus instead of polling.
    if (window.chumpStream) {
      this.#unsubscribe = window.chumpStream.subscribe((msg) => {
        if (msg.type === 'dashboard') this.#renderFromStream(msg.data);
      });
      // Reflect connection status as a small live pill.
      document.addEventListener('chump:stream-status', this.#onStatus);
      // Late mount: paint pill from current bus status (don't wait for the
      // next status-change event, which may never come if we're already live).
      this.#onStatus({ detail: window.chumpStream.status() });
    }
  }

  disconnectedCallback() {
    if (this.#unsubscribe) { this.#unsubscribe(); this.#unsubscribe = null; }
    document.removeEventListener('chump:stream-status', this.#onStatus);
  }

  #onStatus = (e) => {
    const pill = this.querySelector('#stream-pill');
    if (!pill) return;
    const colors = {
      live: ['#1f4d2a', '#9be3a9', '● live'],
      connecting: ['#3a3a1a', '#e3d29b', '◌ connecting'],
      reconnecting: ['#4d3a1a', '#e3c19b', '↻ reconnecting'],
      paused: ['#1a2a3a', '#9bb8e3', '⏸ paused'],
      offline: ['#4d1f1f', '#e39b9b', '⚠ offline'],
      init: ['#2a2a2a', '#aaa', '— stream: init'],
    };
    const [bg, fg, label] = colors[e.detail] || colors.init;
    pill.style.background = bg;
    pill.style.color = fg;
    pill.textContent = label;
  };

  #renderFromStream(dashboard) {
    // Same render path as #load but called per SSE event; do NOT clobber the
    // jobs list (the stream doesn't carry jobs yet — that's a separate gap).
    if (!dashboard || !Object.keys(dashboard).length) return;
    const card = this.querySelector('#stream-dashboard-card');
    const html = `
      <article id="stream-dashboard-card" class="task-card">
        <header class="task-card-header">
          <span class="task-status ${dashboard.ship_running ? 'running' : 'done'}">
            ${dashboard.ship_running ? 'Active' : 'Idle'}
          </span>
        </header>
        <p class="task-desc"><strong>Fleet status:</strong> ${dashboard.fleet_status ?? '?'}</p>
        ${dashboard.last_heartbeat_iso ? `<p class="task-desc"><strong>Last heartbeat:</strong> ${dashboard.last_heartbeat_iso}</p>` : ''}
        ${Array.isArray(dashboard.active_tasks) && dashboard.active_tasks.length > 0
            ? `<p class="task-desc"><strong>Active tasks:</strong> ${dashboard.active_tasks.length}</p>` : ''}
      </article>
    `;
    const container = this.querySelector('#results-container');
    if (!container) return;
    if (card) {
      card.outerHTML = html;
    } else {
      container.insertAdjacentHTML('afterbegin', html);
    }
  }

  #load() {
    const container = this.querySelector('#results-container');
    Promise.all([
      fetch('/api/dashboard').then(r => r.json()).catch(() => ({})),
      fetch('/api/jobs').then(r => r.json()).catch(() => [])
    ]).then(([dashboard, jobs]) => {
      if (!dashboard && !jobs) {
        container.innerHTML = '<p class="placeholder">No results available (offline or server not running).</p>';
        return;
      }

      let html = '';

      if (dashboard && Object.keys(dashboard).length > 0) {
        html += `
          <article class="task-card">
            <header class="task-card-header">
              <span class="task-status ${dashboard.ship_running ? 'running' : 'done'}">
                ${dashboard.ship_running ? 'Active' : 'Idle'}
              </span>
            </header>
            <p class="task-desc"><strong>Agent Status:</strong> ${dashboard.ship_running ? 'Running' : 'Stopped'}</p>
            ${dashboard.ship_summary ? `<p class="task-desc"><strong>Current Round:</strong> ${JSON.stringify(dashboard.ship_summary).substring(0, 100)}…</p>` : ''}
          </article>
        `;
      }

      if (Array.isArray(jobs) && jobs.length > 0) {
        jobs.slice(0, 15).forEach(job => {
          html += `
            <article class="task-card">
              <header class="task-card-header">
                <span class="task-status ${job.status ?? 'unknown'}">${job.status ?? 'pending'}</span>
                <span class="task-id">${job.id ?? job.job_id ?? ''}</span>
              </header>
              <p class="task-desc">${job.description ?? job.title ?? '(no title)'}</p>
              ${job.result ? `<p class="task-desc" style="color: var(--text-secondary); font-size: 12px; margin-top: 4px;"><strong>Result:</strong> ${job.result}</p>` : ''}
            </article>
          `;
        });
      }

      if (!html) {
        container.innerHTML = '<p class="placeholder">No active jobs or results yet.</p>';
      } else {
        container.innerHTML = html;
      }
    }).catch(() => {
      container.innerHTML = '<p class="placeholder">Failed to load results.</p>';
    });
  }
}
customElements.define('chump-view-results', ChumpViewResults);

// ── <chump-view-chat> ─────────────────────────────────────────────────────────
class ChumpViewChat extends HTMLElement {
  connectedCallback() {
    this.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden;height:100%';
    this.innerHTML = '<chump-chat style="flex:1;min-height:0"></chump-chat>';
  }
}
customElements.define('chump-view-chat', ChumpViewChat);

// ── <chump-view-agent> ────────────────────────────────────────────────────────
class ChumpViewAgent extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Gap Queue</h2>
        <p class="view-subtitle">Fleet orchestrator — claim and work gaps autonomously</p>
      </section>
      <section class="gap-search-bar" id="gap-search-bar">
        <input type="search" id="gap-search-input" placeholder="Search gaps…" autocomplete="off" />
        <select id="gap-filter-status"><option value="">All statuses</option><option value="open">open</option><option value="done">done</option><option value="in_flight">in_flight</option></select>
        <select id="gap-filter-priority"><option value="">All priorities</option><option value="P0">P0</option><option value="P1">P1</option><option value="P2">P2</option></select>
        <select id="gap-filter-effort"><option value="">All efforts</option><option value="xs">xs</option><option value="s">s</option><option value="m">m</option><option value="l">l</option><option value="xl">xl</option></select>
        <label class="gap-filter-ac"><input type="checkbox" id="gap-filter-has-ac" /> Missing AC</label>
        <button id="gap-filter-clear" type="button" class="gap-filter-clear" aria-label="Clear all filters" title="Clear all filters">Clear</button>
      </section>
      <section class="gap-queue-stats" id="gap-stats">
        <div class="stat-item">
          <span class="stat-value">—</span>
          <span class="stat-label">Open</span>
        </div>
        <div class="stat-item">
          <span class="stat-value">—</span>
          <span class="stat-label">Claimable</span>
        </div>
      </section>
      <section class="gap-list" id="gap-list">
        <p class="placeholder">Loading gap queue…</p>
      </section>
    `;
    this.#wireSearch();
    this.#restoreFilters();
    this.#load();
    this.#poll = setInterval(() => this.#load(), 5000);
  }

  // INFRA-1280 Sub-gap 2: persist + restore queue filter state across reload.
  // Order of precedence on mount: URL query params > localStorage > defaults.
  // Any change writes back to localStorage. URL is updated via replaceState
  // (no history pollution per filter keystroke).
  #restoreFilters() {
    const url = new URLSearchParams(location.search);
    const stored = window.chumpPrefs.get('queue.filters', {});
    const get = (key) => url.get(key) ?? stored[key] ?? '';
    const qInput = this.querySelector('#gap-search-input');
    const statusSel = this.querySelector('#gap-filter-status');
    const prioritySel = this.querySelector('#gap-filter-priority');
    const effortSel = this.querySelector('#gap-filter-effort');
    const hasAcCb = this.querySelector('#gap-filter-has-ac');
    if (qInput) qInput.value = get('q');
    if (statusSel) statusSel.value = get('status');
    if (prioritySel) prioritySel.value = get('priority');
    if (effortSel) effortSel.value = get('effort');
    if (hasAcCb) {
      const stored_ac = stored.has_ac;
      const url_ac = url.get('has_ac');
      hasAcCb.checked = (url_ac === 'false') || stored_ac === true;
    }
    if (this.#searchActive()) {
      // Re-run with restored filters.
      this.#persistFilters();
      this.#search();
    }
  }

  #persistFilters() {
    const q = this.querySelector('#gap-search-input')?.value || '';
    const status = this.querySelector('#gap-filter-status')?.value || '';
    const priority = this.querySelector('#gap-filter-priority')?.value || '';
    const effort = this.querySelector('#gap-filter-effort')?.value || '';
    const has_ac = !!this.querySelector('#gap-filter-has-ac')?.checked;
    const filters = { q, status, priority, effort, has_ac };
    window.chumpPrefs.set('queue.filters', filters);
    // Reflect in URL (replaceState — don't bloat history).
    try {
      const url = new URL(location.href);
      for (const [k, v] of Object.entries({ q, status, priority, effort })) {
        if (v) url.searchParams.set(k, v); else url.searchParams.delete(k);
      }
      if (has_ac) url.searchParams.set('has_ac', 'false'); else url.searchParams.delete('has_ac');
      history.replaceState(null, '', url.toString());
    } catch {}
  }

  /** Clear all filters + storage + URL — wired to the "Clear" button. */
  #clearFilters() {
    const qInput = this.querySelector('#gap-search-input');
    if (qInput) qInput.value = '';
    ['#gap-filter-status', '#gap-filter-priority', '#gap-filter-effort']
      .forEach(sel => { const el = this.querySelector(sel); if (el) el.value = ''; });
    const hasAcCb = this.querySelector('#gap-filter-has-ac');
    if (hasAcCb) hasAcCb.checked = false;
    window.chumpPrefs.del('queue.filters');
    try {
      const url = new URL(location.href);
      ['q', 'status', 'priority', 'effort', 'has_ac'].forEach(k => url.searchParams.delete(k));
      history.replaceState(null, '', url.toString());
    } catch {}
    this.#load();
  }

  disconnectedCallback() {
    clearInterval(this.#poll);
    // INFRA-1196: stop observing for lazy-mount on view-switch + clear
    // the gap-list so embedded components run their own disconnectedCallback
    // (closes the EventSource in <chump-workflow-timeline>, stops the
    // /api/pr/{n} poll in <chump-pr-card>). No leaked SSE streams.
    if (this.#embedObserver) {
      try { this.#embedObserver.disconnect(); } catch {}
      this.#embedObserver = null;
    }
    const list = this.querySelector('#gap-list');
    if (list) list.innerHTML = '';
  }

  #wireSearch() {
    let debounce = null;
    const trigger = () => {
      // INFRA-1280: persist on every change. Search itself stays debounced.
      this.#persistFilters();
      clearTimeout(debounce);
      debounce = setTimeout(() => {
        if (this.#searchActive()) this.#search();
        else this.#load();   // empty filters → fall back to /api/gap-queue
      }, 300);
    };
    this.querySelector('#gap-search-input')?.addEventListener('input', trigger);
    this.querySelector('#gap-filter-status')?.addEventListener('change', trigger);
    this.querySelector('#gap-filter-priority')?.addEventListener('change', trigger);
    this.querySelector('#gap-filter-effort')?.addEventListener('change', trigger);
    this.querySelector('#gap-filter-has-ac')?.addEventListener('change', trigger);
    // INFRA-1280 Sub-gap 2: explicit Clear button for one-click reset.
    this.querySelector('#gap-filter-clear')?.addEventListener('click', () => this.#clearFilters());
  }

  #searchActive() {
    const q = this.querySelector('#gap-search-input')?.value || '';
    const status = this.querySelector('#gap-filter-status')?.value || '';
    const priority = this.querySelector('#gap-filter-priority')?.value || '';
    const effort = this.querySelector('#gap-filter-effort')?.value || '';
    const hasAc = this.querySelector('#gap-filter-has-ac')?.checked;
    return q || status || priority || effort || hasAc;
  }

  #search() {
    const list = this.querySelector('#gap-list');
    const q = this.querySelector('#gap-search-input')?.value || '';
    const status = this.querySelector('#gap-filter-status')?.value || '';
    const priority = this.querySelector('#gap-filter-priority')?.value || '';
    const effort = this.querySelector('#gap-filter-effort')?.value || '';
    const hasAc = this.querySelector('#gap-filter-has-ac')?.checked;
    const params = new URLSearchParams();
    if (q) params.set('q', q);
    if (status) params.set('status', status);
    if (priority) params.set('priority', priority);
    if (effort) params.set('effort', effort);
    if (hasAc) params.set('has_ac', 'false');
    fetch(`/api/gaps/search?${params}`)
      .then((r) => r.json())
      .then((d) => {
        const results = d.results ?? [];
        if (results.length === 0) {
          list.innerHTML = '<p class="placeholder">No gaps match your search.</p>';
          return;
        }
        list.innerHTML = results.map((g) => `
          <article class="gap-card">
            <header class="gap-card-header">
              <span class="gap-id">${g.id}</span>
              <span class="gap-badge">${g.status || '?'}</span>
              <span class="gap-priority">${g.priority || 'P?'}/${g.effort || '?'}</span>
            </header>
            <p class="gap-title">${g.title || '(no title)'}</p>
          </article>
        `).join('');
      })
      .catch((err) => {
        list.innerHTML = `<p class="placeholder">Search failed: ${err.message}</p>`;
      });
  }

  #load() {
    if (this.#searchActive()) return; // don't stomp search results with poll
    const list = this.querySelector('#gap-list');
    const stats = this.querySelector('#gap-stats');
    // INFRA-1197: response now carries 15 fields per gap (domain, status,
    // closed_pr, assigned_session, pillar, depends_on, …). This consumer
    // still uses only the legacy 6 — see INFRA-1196 to wire <chump-pr-card>
    // (per closed_pr) and <chump-workflow-timeline> (per active workflow)
    // into each row, plus pillar/domain badges + lease-holder indicator.
    fetch('/api/gap-queue')
      .then((r) => r.json())
      .then((d) => {
        const gaps = d.gaps ?? [];
        const claimable = d.claimable_count ?? 0;

        if (gaps.length === 0) {
          list.innerHTML = '<p class="placeholder">No gaps in queue.</p>';
          stats.innerHTML = `
            <div class="stat-item"><span class="stat-value">0</span><span class="stat-label">Open</span></div>
            <div class="stat-item"><span class="stat-value">0</span><span class="stat-label">Claimable</span></div>
          `;
          return;
        }

        stats.innerHTML = `
          <div class="stat-item"><span class="stat-value">${gaps.length}</span><span class="stat-label">Open</span></div>
          <div class="stat-item"><span class="stat-value">${claimable}</span><span class="stat-label">Claimable</span></div>
        `;

        list.innerHTML = gaps.map((g) => this.#renderRow(g)).join('');

        // Attach claim handlers
        list.querySelectorAll('.gap-claim-btn').forEach((btn) => {
          btn.addEventListener('click', (e) => this.#claim(e.target.dataset.gapId));
        });

        // Attach work handlers
        list.querySelectorAll('.gap-work-btn').forEach((btn) => {
          btn.addEventListener('click', (e) => this.#work(e.target.dataset.gapId));
        });

        // Attach status handlers
        list.querySelectorAll('.gap-status-btn').forEach((btn) => {
          btn.addEventListener('click', (e) => this.#status(e.target.dataset.gapId));
        });

        // INFRA-1196: lazy-mount per-row embeds (pr-card / workflow-timeline)
        // via IntersectionObserver so off-screen rows don't pay the SSE +
        // poll cost. Only rows that scroll into view get their components
        // instantiated. Cleanup happens automatically when innerHTML is
        // replaced on the next #load() — both components disconnect
        // their EventSource / poll timer in disconnectedCallback().
        this.#mountVisibleEmbeds(list);
      })
      .catch((err) => {
        list.innerHTML = `<p class="placeholder">Could not load gap queue: ${err.message}</p>`;
      });
  }

  #claim(gapId) {
    fetch(`/api/gap/claim/${gapId}`, { method: 'POST' })
      .then((r) => r.json())
      .then((d) => {
        if (d.error) {
          alert(`Claim failed: ${d.error}`);
        } else {
          alert(`Claimed ${gapId}. Worktree: ${d.worktree_path}`);
          this.#load();
        }
      })
      .catch((err) => {
        alert(`Claim error: ${err.message}`);
      });
  }

  #work(gapId) {
    fetch(`/api/gap/work/${gapId}`, { method: 'POST' })
      .then((r) => r.json())
      .then((d) => {
        if (d.error) {
          alert(`Work failed: ${d.error}`);
        } else {
          alert(`Workflow started for ${gapId}. Chump is working...`);
          this.#load();
        }
      })
      .catch((err) => {
        alert(`Work error: ${err.message}`);
      });
  }

  #status(gapId) {
    fetch(`/api/gap/status/${gapId}`)
      .then((r) => r.json())
      .then((d) => {
        if (d.error) {
          alert(`Status error: ${d.error}`);
        } else {
          const msg = `Gap: ${gapId}\nStatus: ${d.status}\nTitle: ${d.title}\nPriority: ${d.priority}/${d.effort}`;
          alert(msg);
        }
      })
      .catch((err) => {
        alert(`Status error: ${err.message}`);
      });
  }

  // INFRA-1196: render one queue row with the full INFRA-1197 fat shape:
  // pillar badge, domain chip, AC count, depends-on indicator, lease
  // holder, plus *placeholders* for the embedded components. The
  // components mount lazily via IntersectionObserver in #mountVisibleEmbeds.
  #renderRow(g) {
    const badgeClass = g.preflight_status === 'claimable' ? 'badge-success' :
                      g.preflight_status === 'blocked'   ? 'badge-warn'    :
                                                           'badge-error';
    const actions = g.preflight_status === 'claimable'
      ? `<button class="gap-claim-btn" data-gap-id="${g.id}">Claim</button>`
      : g.preflight_status === 'blocked'
      ? `<button class="gap-work-btn" data-gap-id="${g.id}">Work</button><button class="gap-status-btn" data-gap-id="${g.id}">Status</button>`
      : '';

    // Pillar pill — colored. Falls back to nothing when no tag.
    const pillarHtml = g.pillar
      ? `<span class="gap-pillar gap-pillar-${g.pillar}">${g.pillar}</span>`
      : '';
    const domainHtml = g.domain ? `<span class="gap-domain">${g.domain}</span>` : '';
    const acHtml = (g.acceptance_criteria_count != null && g.acceptance_criteria_count > 0)
      ? `<span class="gap-ac" title="${g.acceptance_criteria_count} acceptance criteria">AC ${g.acceptance_criteria_count}</span>`
      : '';
    const depsHtml = (Array.isArray(g.depends_on) && g.depends_on.length > 0)
      ? `<span class="gap-deps" title="depends on: ${g.depends_on.join(', ')}">↳ ${g.depends_on.length} deps</span>`
      : '';

    // Lease holder line — when the gap is claim-blocked by an active session.
    const leaseHtml = g.assigned_session
      ? `<p class="gap-lease" title="${g.assigned_session}">⚙ claimed by ${this.#shortSession(g.assigned_session)}</p>`
      : '';

    // Embedded slots — placeholders the IntersectionObserver fills.
    // pr-card slot: only when closed_pr is set (a shipped gap surfaced via
    // ?status=shipped or via search).
    const prCardSlot = g.closed_pr
      ? `<div class="gap-embed gap-embed-pr" data-pr-number="${g.closed_pr}" data-mounted="0"></div>`
      : '';
    // workflow-timeline slot: gap status indicates active work. We treat
    // "preflight blocked because someone claimed it" as the canonical
    // active-workflow signal — the alternative ambient-jsonl scan would
    // require a separate API call per gap. assigned_session being set
    // (which we surface above) is what makes blocked → active.
    const isActiveWorkflow = g.preflight_status === 'blocked' && !!g.assigned_session;
    const timelineSlot = isActiveWorkflow
      ? `<div class="gap-embed gap-embed-timeline" data-gap-id="${g.id}" data-mounted="0"></div>`
      : '';

    return `
      <article class="gap-card" data-gap-id="${g.id}">
        <header class="gap-card-header">
          <span class="gap-id">${g.id}</span>
          ${pillarHtml}
          ${domainHtml}
          <span class="gap-badge ${badgeClass}">${g.preflight_status || 'unknown'}</span>
          <span class="gap-priority">${g.priority || 'P?'}/${g.effort || '?'}</span>
          ${acHtml}
          ${depsHtml}
        </header>
        <p class="gap-title">${g.title || '(no title)'}</p>
        ${leaseHtml}
        ${g.preflight_error ? `<p class="gap-error">${g.preflight_error}</p>` : ''}
        ${actions ? `<div class="gap-actions">${actions}</div>` : ''}
        ${timelineSlot}
        ${prCardSlot}
      </article>
    `;
  }

  #shortSession(sid) {
    // claim-infra-1196-16242-1778775648 → infra-1196 (operator-readable).
    const m = String(sid).match(/^claim-([a-z]+-\d+)/i);
    return m ? m[1] : (String(sid).slice(0, 24) + '…');
  }

  // INFRA-1196: lazy-mount embedded <chump-pr-card> + <chump-workflow-timeline>
  // for slots that scroll into view. Reduces SSE/poll cost when the queue
  // is long. Uses one IntersectionObserver per #load() call — replaced on
  // each refresh.
  #mountVisibleEmbeds(list) {
    if (this.#embedObserver) {
      try { this.#embedObserver.disconnect(); } catch {}
    }
    if (typeof IntersectionObserver === 'undefined') {
      // Fallback: mount everything (small queues, old browsers).
      list.querySelectorAll('.gap-embed[data-mounted="0"]').forEach((el) => this.#mountEmbed(el));
      return;
    }
    this.#embedObserver = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting && entry.target.dataset.mounted === '0') {
          this.#mountEmbed(entry.target);
        }
      });
    }, { rootMargin: '200px 0px' /* pre-mount slightly before visible */ });
    list.querySelectorAll('.gap-embed[data-mounted="0"]').forEach((el) => {
      this.#embedObserver.observe(el);
    });
  }

  #mountEmbed(slot) {
    if (slot.dataset.mounted === '1') return;
    slot.dataset.mounted = '1';
    if (slot.classList.contains('gap-embed-pr')) {
      const pr = slot.dataset.prNumber;
      if (!pr) return;
      const card = document.createElement('chump-pr-card');
      card.setAttribute('pr-number', pr);
      slot.appendChild(card);
    } else if (slot.classList.contains('gap-embed-timeline')) {
      const gid = slot.dataset.gapId;
      if (!gid) return;
      const tl = document.createElement('chump-workflow-timeline');
      tl.setAttribute('gap-id', gid);
      slot.appendChild(tl);
    }
  }

  #poll;
  #embedObserver;
}
customElements.define('chump-view-agent', ChumpViewAgent);

// ── Router ────────────────────────────────────────────────────────────────────
// PRODUCT-091: ambient event viewer view factory.
function makeAmbientView() {
  const el = document.createElement('div');
  el.className = 'view-panel';
  el.innerHTML = `
    <h2 class="view-title">Ambient Events</h2>
    <p class="view-subtitle">Real-time tail of .chump-locks/ambient.jsonl — fleet activity stream</p>
    <chump-ambient-viewer></chump-ambient-viewer>`;
  return el;
}

const VIEWS = {
  chat:      () => document.createElement('chump-view-chat'),
  agents:    () => document.createElement('chump-view-agents'),
  results:   () => document.createElement('chump-view-results'),
  agent:     () => document.createElement('chump-view-agent'),
  tasks:     () => document.createElement('chump-view-tasks'),
  decisions: () => document.createElement('chump-view-decisions'),
  judgment:  () => document.createElement('chump-view-judgment'),
  ambient:   makeAmbientView,
  memory:    () => document.createElement('chump-view-memory'),
  models:    () => document.createElement('chump-view-models'),
  settings:  () => document.createElement('chump-view-settings'),
};

document.addEventListener('chump:navigate', (e) => {
  const main = document.getElementById('main-content');
  if (!main) return;
  const factory = VIEWS[e.detail] ?? VIEWS.tasks;
  main.innerHTML = '';
  main.appendChild(factory());
});

// ── Boot ──────────────────────────────────────────────────────────────────────
if ('serviceWorker' in navigator) {
  // INFRA-250: relative URL + relative scope so the SW registers correctly
  // in both axum-sidecar context (resolves to /v2/sw.js with /v2/ scope)
  // and Tauri context (where frontendDist = web/v2, so root-relative paths
  // would 404).
  navigator.serviceWorker.register('sw.js', { scope: './' }).catch(() => {});
}

// Initial view.
window.addEventListener('DOMContentLoaded', () => {
  const main = document.getElementById('main-content');
  if (main) main.appendChild(document.createElement('chump-view-chat'));
});
