// Chump v2 — vanilla Web Components app shell.
// No build step, no CDN dependencies. Air-gap safe by construction.

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
      </section>
    `;
    this.#loadCascadeInfo();
    this.#loadOperatorConfig();
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
    this.#load();
    this.#poll = setInterval(() => this.#load(), 5000);
  }

  disconnectedCallback() {
    clearInterval(this.#poll);
  }

  #wireSearch() {
    let debounce = null;
    const trigger = () => {
      clearTimeout(debounce);
      debounce = setTimeout(() => this.#search(), 300);
    };
    this.querySelector('#gap-search-input')?.addEventListener('input', trigger);
    this.querySelector('#gap-filter-status')?.addEventListener('change', trigger);
    this.querySelector('#gap-filter-priority')?.addEventListener('change', trigger);
    this.querySelector('#gap-filter-effort')?.addEventListener('change', trigger);
    this.querySelector('#gap-filter-has-ac')?.addEventListener('change', trigger);
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

        list.innerHTML = gaps.map((g) => {
          const badgeClass = g.preflight_status === 'claimable' ? 'badge-success' :
                            g.preflight_status === 'blocked' ? 'badge-warn' : 'badge-error';
          const actions = g.preflight_status === 'claimable'
            ? `<button class="gap-claim-btn" data-gap-id="${g.id}">Claim</button>`
            : g.preflight_status === 'blocked'
            ? `<button class="gap-work-btn" data-gap-id="${g.id}">Work</button><button class="gap-status-btn" data-gap-id="${g.id}">Status</button>`
            : '';
          return `
            <article class="gap-card">
              <header class="gap-card-header">
                <span class="gap-id">${g.id}</span>
                <span class="gap-badge ${badgeClass}">${g.preflight_status || 'unknown'}</span>
                <span class="gap-priority">${g.priority || 'P?'}/${g.effort || '?'}</span>
              </header>
              <p class="gap-title">${g.title || '(no title)'}</p>
              ${g.preflight_error ? `<p class="gap-error">${g.preflight_error}</p>` : ''}
              ${actions ? `<div class="gap-actions">${actions}</div>` : ''}
            </article>
          `;
        }).join('');

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

  #poll;
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
