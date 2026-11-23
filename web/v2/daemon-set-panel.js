// daemon-set-panel.js — EFFECTIVE-026 (fixed + token-aligned in PRODUCT-372)
//
// <chump-daemon-set-panel> — Fleet-autopilot daemon health panel.
//
// Polls /api/autopilot/daemon-status every 15s and renders each daemon layer
// as a semantic status pill:
//   loaded     = plist present AND loaded (healthy)
//   plist-only = plist present but NOT loaded (parked/degraded)
//   absent     = plist absent (not installed)
//
// Click a daemon row to inspect recent log lines from /api/autopilot/daemon-log.

class ChumpDaemonSetPanel extends HTMLElement {
  #shadow;
  #data = null;
  #expandedLabel = null;
  #logCache = {};
  #pollTimer = null;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#render();
    this.#poll();
    this.#pollTimer = setInterval(() => this.#poll(), 15_000);
  }

  disconnectedCallback() {
    if (this.#pollTimer) clearInterval(this.#pollTimer);
  }

  async #poll() {
    try {
      const headers = this.#authHeaders();
      const r = await fetch('/api/autopilot/daemon-status', { headers, credentials: 'same-origin' });
      if (r.ok) {
        this.#data = await r.json();
      } else {
        this.#data = { error: `HTTP ${r.status}` };
      }
    } catch (e) {
      this.#data = { error: e.message || 'network error' };
    }
    this.#render();
    if (this.#expandedLabel) {
      this.#fetchLog(this.#expandedLabel);
    }
  }

  async #fetchLog(label) {
    try {
      const headers = this.#authHeaders();
      const r = await fetch(
        `/api/autopilot/daemon-log?name=${encodeURIComponent(label)}`,
        { headers, credentials: 'same-origin' },
      );
      if (r.ok) {
        const body = await r.json();
        this.#logCache[label] = (body.lines || []).join('\n') || '(log file empty)';
      } else if (r.status === 404) {
        this.#logCache[label] = '(log endpoint not wired — check .chump-locks/autopilot-logs/)';
      } else {
        this.#logCache[label] = `(fetch error: HTTP ${r.status})`;
      }
    } catch {
      this.#logCache[label] = '(network error fetching log)';
    }
    this.#renderLogPane();
  }

  #authHeaders() {
    try {
      const t = window.chumpPrefs && window.chumpPrefs.get
        ? window.chumpPrefs.get('webToken')
        : null;
      if (t) return { 'X-Chump-Auth': t };
    } catch {}
    return {};
  }

  #statusForDaemon(d) {
    if (d.plist === 'yes' && d.loaded === 'yes') return 'loaded';
    if (d.plist === 'yes' && d.loaded !== 'yes') return 'plist-only';
    return 'absent';
  }

  #labelForStatus(status) {
    switch (status) {
      case 'loaded':     return 'loaded';
      case 'plist-only': return 'parked';
      case 'absent':     return 'not installed';
      default:           return '—';
    }
  }

  #shortName(label) {
    return String(label || '').replace(/^(?:com|dev)\.chump\./, '');
  }

  #renderLogPane() {
    const pane = this.#shadow.getElementById('log-pane');
    if (!pane) return;
    const label = this.#expandedLabel;
    if (!label) {
      pane.hidden = true;
      return;
    }
    pane.hidden = false;
    const title = this.#shadow.getElementById('log-title');
    const pre = this.#shadow.getElementById('log-pre');
    if (title) title.textContent = label;
    if (pre) pre.textContent = this.#logCache[label] || '(loading…)';
  }

  #render() {
    const data = this.#data;

    const CSS = `
      :host {
        display: block;
        font-family: var(--font-sans);
        font-size: 12px;
        color: var(--text);
      }
      .panel-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        margin-bottom: 8px;
      }
      .panel-title {
        font-size: 11px;
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        color: var(--text-secondary);
      }
      .panel-counts {
        font-size: 11px;
        color: var(--text-secondary);
        font-family: var(--font-mono);
        font-variant-numeric: tabular-nums;
      }
      .daemon-list {
        list-style: none;
        padding: 0;
        margin: 0;
        display: flex;
        flex-direction: column;
        gap: 4px;
      }
      .daemon-row {
        display: grid;
        grid-template-columns: 1fr auto;
        align-items: center;
        gap: 8px;
        padding: 7px 10px;
        border-radius: var(--radius-sm);
        cursor: pointer;
        border: 1px solid var(--border);
        background: var(--bg-surface);
        transition: background 0.12s, border-color 0.12s;
      }
      .daemon-row:hover {
        background: var(--bg-elevated);
      }
      .daemon-row.expanded {
        border-color: var(--accent);
        background: var(--accent-dim);
      }
      .daemon-name {
        font-family: var(--font-mono);
        font-size: 11px;
        color: var(--text);
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .daemon-pill {
        display: inline-flex;
        align-items: center;
        gap: 5px;
        padding: 2px 8px;
        border-radius: 999px;
        font-size: 10px;
        font-weight: 600;
        letter-spacing: 0.03em;
        white-space: nowrap;
        border: 1px solid var(--border);
        background: var(--bg-elevated);
        color: var(--text-secondary);
      }
      .daemon-pill.status-loaded {
        color: var(--success);
        background: var(--tone-ok-bg);
        border-color: var(--tone-ok-border);
      }
      .daemon-pill.status-plist-only {
        color: var(--warn);
        background: var(--tone-warn-bg);
        border-color: var(--tone-warn-border);
      }
      .daemon-pill.status-absent {
        color: var(--text-secondary);
        background: var(--bg-elevated);
        border-color: var(--border);
      }
      .pill-dot {
        width: 6px;
        height: 6px;
        border-radius: 50%;
        background: currentColor;
        flex-shrink: 0;
      }
      .log-pane {
        margin-top: 8px;
        padding: 10px 12px;
        background: var(--bg-elevated);
        border: 1px solid var(--border);
        border-radius: var(--radius-sm);
      }
      .log-pane[hidden] { display: none; }
      .log-title {
        font-family: var(--font-mono);
        font-size: 10px;
        color: var(--text-secondary);
        margin-bottom: 6px;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .log-pre {
        margin: 0;
        font-family: var(--font-mono);
        font-size: 10px;
        line-height: 1.5;
        color: var(--text);
        white-space: pre-wrap;
        word-break: break-all;
        max-height: 180px;
        overflow-y: auto;
      }
      .log-close {
        float: right;
        background: none;
        border: none;
        color: var(--text-secondary);
        cursor: pointer;
        font-size: 11px;
        padding: 0 0 4px 8px;
        line-height: 1;
      }
      .log-close:hover { color: var(--text); }
      .error-msg {
        font-size: 12px;
        color: var(--text-secondary);
        padding: 8px 10px;
        background: var(--bg-elevated);
        border: 1px solid var(--border);
        border-radius: var(--radius-sm);
        margin: 0;
      }
      .loading-msg {
        font-size: 12px;
        color: var(--text-secondary);
        padding: 8px 0;
        margin: 0;
      }
    `;

    let bodyHtml = '';
    if (!data) {
      bodyHtml = `<p class="loading-msg">Checking supervisor daemons…</p>`;
    } else if (data.error) {
      bodyHtml = `<p class="error-msg">Supervisor status unavailable (${this.#esc(data.error)}). Run <code>chump service status</code> in terminal.</p>`;
    } else {
      const daemons = data.daemons || [];
      if (daemons.length === 0) {
        bodyHtml = `<p class="error-msg">No supervisor units registered yet. Run <code>chump service install</code> when ready for background dispatch.</p>`;
      } else {
        const loaded = daemons.filter((d) => d.plist === 'yes' && d.loaded === 'yes').length;
        const total = daemons.length;
        const countHtml = `<span class="panel-counts">${loaded}/${total} loaded</span>`;

        const rows = daemons.map((d) => {
          const status = this.#statusForDaemon(d);
          const pillLabel = this.#labelForStatus(status);
          const name = this.#shortName(d.label || '');
          const expanded = this.#expandedLabel === d.label;
          return `
            <li class="daemon-row${expanded ? ' expanded' : ''}"
                data-label="${this.#esc(d.label)}"
                role="button"
                tabindex="0"
                aria-expanded="${expanded}"
                title="${this.#esc(d.label)} — ${pillLabel}">
              <span class="daemon-name">${this.#esc(name)}</span>
              <span class="daemon-pill status-${status}">
                <span class="pill-dot"></span>
                ${this.#esc(pillLabel)}
              </span>
            </li>`;
        }).join('');

        bodyHtml = `
          <div class="panel-header">
            <span class="panel-title">Supervisor Units</span>
            ${countHtml}
          </div>
          <ul class="daemon-list">${rows}</ul>`;
      }
    }

    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      ${bodyHtml}
      <div class="log-pane" id="log-pane" hidden>
        <button class="log-close" id="log-close" aria-label="Close log">Close</button>
        <div class="log-title" id="log-title"></div>
        <pre class="log-pre" id="log-pre"></pre>
      </div>
    `;

    this.#shadow.querySelectorAll('.daemon-row').forEach((row) => {
      const handler = (e) => {
        if (e.type === 'keydown' && e.key !== 'Enter' && e.key !== ' ') return;
        e.preventDefault();
        const label = row.dataset.label;
        if (this.#expandedLabel === label) {
          this.#expandedLabel = null;
          this.#renderLogPane();
          row.classList.remove('expanded');
          row.setAttribute('aria-expanded', 'false');
        } else {
          this.#shadow.querySelectorAll('.daemon-row.expanded').forEach((r) => {
            r.classList.remove('expanded');
            r.setAttribute('aria-expanded', 'false');
          });
          this.#expandedLabel = label;
          row.classList.add('expanded');
          row.setAttribute('aria-expanded', 'true');
          this.#fetchLog(label);
          this.#renderLogPane();
        }
      };
      row.addEventListener('click', handler);
      row.addEventListener('keydown', handler);
    });

    const closeBtn = this.#shadow.getElementById('log-close');
    if (closeBtn) {
      closeBtn.addEventListener('click', () => {
        this.#expandedLabel = null;
        this.#shadow.querySelectorAll('.daemon-row.expanded').forEach((r) => {
          r.classList.remove('expanded');
          r.setAttribute('aria-expanded', 'false');
        });
        const pane = this.#shadow.getElementById('log-pane');
        if (pane) pane.hidden = true;
      });
    }

    this.#renderLogPane();
  }

  #esc(str) {
    return String(str || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
}

customElements.define('chump-daemon-set-panel', ChumpDaemonSetPanel);
