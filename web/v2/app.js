// Chump v2 — vanilla Web Components app shell.
// No build step, no CDN dependencies. Air-gap safe by construction.

// ── <chump-nav> ───────────────────────────────────────────────────────────────
class ChumpNav extends HTMLElement {
  static #ITEMS = [
    { id: 'chat',      label: 'Chat',      icon: '💬' },
    { id: 'results',   label: 'Results',   icon: '📊' },
    { id: 'tasks',     label: 'Tasks',     icon: '⚡' },
    { id: 'decisions', label: 'Decisions', icon: '🎯' },
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
          <p class="setting-label" style="margin-bottom: 12px;">Fleet Control</p>
          <chump-parallelism-governor></chump-parallelism-governor>
        </div>
      </section>
    `;
  }
}
customElements.define('chump-view-settings', ChumpViewSettings);

// ── <chump-view-results> ──────────────────────────────────────────────────────
class ChumpViewResults extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Results</h2>
        <p class="view-subtitle">Live status and job results</p>
      </section>
      <section class="results-list" id="results-container">
        <p class="placeholder">Loading results…</p>
      </section>
    `;
    this.#load();
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

// ── Router ────────────────────────────────────────────────────────────────────
const VIEWS = {
  chat:      () => document.createElement('chump-view-chat'),
  results:   () => document.createElement('chump-view-results'),
  tasks:     () => document.createElement('chump-view-tasks'),
  decisions: () => document.createElement('chump-view-decisions'),
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
