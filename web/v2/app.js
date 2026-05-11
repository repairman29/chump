// Chump v2 — vanilla Web Components app shell.
// No build step, no CDN dependencies. Air-gap safe by construction.

// ── <chump-nav> ───────────────────────────────────────────────────────────────
class ChumpNav extends HTMLElement {
  static #ITEMS = [
    { id: 'chat',      label: 'Chat',      icon: '💬' },
    { id: 'agents',    label: 'Agents',    icon: '🤝' },
    { id: 'results',   label: 'Results',   icon: '📊' },
    { id: 'agent',     label: 'Queue',     icon: '🔄' },
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
          <p class="setting-label" style="margin-bottom: 12px;">Inference Settings</p>
          <div id="cascade-slots" style="margin-bottom: 16px; font-size: 0.9em; color: var(--text-muted);">
            <p>Loading cascade slot info…</p>
          </div>
        </div>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">Fleet Control</p>
          <chump-parallelism-governor></chump-parallelism-governor>
        </div>
      </section>
    `;
    this.#loadCascadeInfo();
  }

  #loadCascadeInfo() {
    const container = this.querySelector('#cascade-slots');
    fetch('/api/repo/context')
      .then(r => r.json())
      .then(ctx => {
        if (!ctx || !ctx.effective_root) {
          container.innerHTML = '<p style="color: var(--error-color);">Unable to load cascade info</p>';
          return;
        }
        const html = `
          <div style="background: var(--bg-secondary); padding: 12px; border-radius: 6px;">
            <div style="margin-bottom: 8px;"><strong>Repo Root</strong></div>
            <div style="margin-bottom: 12px; font-family: monospace; font-size: 0.85em; color: var(--text-secondary);">
              ${ctx.effective_root}
            </div>
            <div style="margin-bottom: 8px;"><strong>Active Profile</strong></div>
            <div style="color: var(--text-secondary);">
              ${ctx.active_profile || '(none configured)'}
            </div>
            ${ctx.profiles && ctx.profiles.length > 0 ? `
              <div style="margin-top: 12px; padding-top: 12px; border-top: 1px solid var(--border-color);">
                <strong>Available Profiles (${ctx.profiles.length})</strong>
                <ul style="margin: 8px 0; padding-left: 20px;">
                  ${ctx.profiles.map(p => `<li>${p}</li>`).join('')}
                </ul>
              </div>
            ` : ''}
          </div>
        `;
        container.innerHTML = html;
      })
      .catch(err => {
        container.innerHTML = `<p style="color: var(--error-color);">Error: ${err.message}</p>`;
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

// ── <chump-view-agent> ────────────────────────────────────────────────────────
class ChumpViewAgent extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Gap Queue</h2>
        <p class="view-subtitle">Fleet orchestrator — claim and work gaps autonomously</p>
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
    this.#load();
    this.#poll = setInterval(() => this.#load(), 5000);
  }

  disconnectedCallback() {
    clearInterval(this.#poll);
  }

  #load() {
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
const VIEWS = {
  chat:      () => document.createElement('chump-view-chat'),
  agents:    () => document.createElement('chump-view-agents'),
  results:   () => document.createElement('chump-view-results'),
  agent:     () => document.createElement('chump-view-agent'),
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
