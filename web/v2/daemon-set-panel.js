// daemon-set-panel.js — EFFECTIVE-026
//
// <chump-daemon-set-panel> — Fleet-autopilot daemon health panel.
//
// Polls /api/autopilot/daemon-status every 10s and renders each daemon layer
// as a colored status pill:
//   green  = plist present AND loaded (healthy)
//   amber  = plist present but NOT loaded (degraded)
//   red    = plist absent (missing)
//
// Click a daemon row to see the last 20 lines from its autopilot log file.
// Renders in the PWA cockpit alongside <chump-autopilot-toggle> (PRODUCT-115).
//
// Endpoint: GET /api/autopilot/daemon-status
//   → { daemons: [{label, plist, loaded}, ...], layers, loaded, ... }
//
// Log tail: GET /api/autopilot/daemon-log?name=<label>
//   Falls through gracefully if the endpoint isn't available yet.

class ChumpDaemonSetPanel extends HTMLElement {
  #shadow;
  #data = null;
  #expandedLabel = null;
  #logCache = {}; // label → last fetched log lines
  #pollTimer = null;
  #logTimer = null;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#render();
    this.#poll();
    this.#pollTimer = setInterval(() => this.#poll(), 10_000);
  }

  disconnectedCallback() {
    if (this.#pollTimer) clearInterval(this.#pollTimer);
    if (this.#logTimer) clearInterval(this.#logTimer);
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
    // Refresh expanded log on each poll cycle if a row is open.
    if (this.#expandedLabel) {
      this.#fetchLog(this.#expandedLabel);
    }
  }

  async #fetchLog(label) {
    try {
      const headers = this.#authHeaders();
      // Primary: dedicated log endpoint (may not exist yet — degrade to empty).
      const r = await fetch(
        `/api/autopilot/daemon-log?name=${encodeURIComponent(label)}`,
        { headers, credentials: 'same-origin' },
      );
      if (r.ok) {
        const body = await r.json();
        this.#logCache[label] = (body.lines || []).join('\n');
      } else if (r.status === 404) {
        // Endpoint not yet implemented — show helpful stub.
        this.#logCache[label] = `(log endpoint not yet wired — see .chump-locks/autopilot-logs/)`;
      } else {
        this.#logCache[label] = `(fetch error: HTTP ${r.status})`;
      }
    } catch (_e) {
      this.#logCache[label] = `(network error fetching log)`;
    }
    this.#renderLogPane();
  }

  #authHeaders() {
    try {
      const t = window.chumpPrefs && window.chumpPrefs.get
        ? window.chumpPrefs.get('webToken')
        : null;
      if (t) return { 'X-Chump-Auth': t };
    } catch (_e) {}
    return {};
  }

  #statusForDaemon(d) {
    // plist and loaded are "yes" | "no" strings from fleet-autopilot.sh status json.
    if (d.plist === 'yes' && d.loaded === 'yes') return 'loaded';
    if (d.plist === 'yes' && d.loaded !== 'yes') return 'plist-only';
    return 'absent';
  }

  #colorForStatus(status) {
    switch (status) {
      case 'loaded':    return '#30d158'; // green
      case 'plist-only': return '#ff9f0a'; // amber
      case 'absent':    return '#ff453a'; // red
      default:          return '#6c6c70';
    }
  }

  #labelForStatus(status) {
    switch (status) {
      case 'loaded':     return 'loaded';
      case 'plist-only': return 'plist only';
      case 'absent':     return 'absent';
      default:           return '—';
    }
  }

  // Short display name: strip the vendor prefix (com.chump. / dev.chump.)
  #shortName(label) {
    return label.replace(/^(?:com|dev)\.chump\./, '');
  }

  #renderLogPane() {
    const pane = this.#shadow.getElementById('log-pane');
    if (!pane) return;
    const label = this.#expandedLabel;
    if (!label) {
      pane.hidden = true;
      return;
    }
    const lines = this.#logCache[label] || '(loading…)';
    pane.hidden = false;
    const pre = pane.querySelector('pre');
    if (pre) pre.textContent = lines;
    const title = pane.querySelector('.log-title');
    if (title) title.textContent = label;
  }

  #render() {
    const data = this.#data;

    const CSS = `
      :host {
        display: block;
        font: 12px -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        color: var(--text, #e5e5ea);
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
        letter-spacing: 0.04em;
        color: var(--text-secondary, #8a8a8e);
      }
      .panel-counts {
        font-size: 10px;
        color: var(--text-secondary, #8a8a8e);
        font-variant-numeric: tabular-nums;
      }
      .daemon-list {
        list-style: none;
        padding: 0; margin: 0;
        display: flex;
        flex-direction: column;
        gap: 3px;
      }
      .daemon-row {
        display: grid;
        grid-template-columns: 1fr auto;
        align-items: center;
        gap: 8px;
        padding: 6px 8px;
        border-radius: 6px;
        cursor: pointer;
        border: 1px solid transparent;
        transition: background 0.1s, border-color 0.1s;
        background: var(--bg-elevated, #1a1a1c);
      }
      .daemon-row:hover {
        background: var(--bg-tertiary, #25252a);
        border-color: var(--border, #2a2a2e);
      }
      .daemon-row.expanded {
        border-color: var(--accent, #0a84ff);
        background: rgba(10,132,255,0.06);
      }
      .daemon-name {
        font-family: ui-monospace, "SF Mono", monospace;
        font-size: 11px;
        color: var(--text, #e5e5ea);
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .daemon-pill {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        padding: 2px 7px;
        border-radius: 4px;
        font-size: 9px;
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        white-space: nowrap;
        flex-shrink: 0;
      }
      .pill-dot {
        width: 6px; height: 6px;
        border-radius: 50%;
        flex-shrink: 0;
      }
      .log-pane {
        margin-top: 8px;
        padding: 10px 12px;
        background: var(--bg, #0d0d0f);
        border: 1px solid var(--border, #2a2a2e);
        border-radius: 6px;
      }
      .log-pane[hidden] { display: none; }
      .log-title {
        font-family: ui-monospace, "SF Mono", monospace;
        font-size: 10px;
        color: var(--text-secondary, #8a8a8e);
        margin-bottom: 6px;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .log-pre {
        margin: 0;
        font-family: ui-monospace, "SF Mono", monospace;
        font-size: 10px;
        line-height: 1.5;
        color: var(--text-secondary, #8a8a8e);
        white-space: pre-wrap;
        word-break: break-all;
        max-height: 200px;
        overflow-y: auto;
      }
      .log-close {
        float: right;
        background: none;
        border: none;
        color: var(--text-secondary, #8a8a8e);
        cursor: pointer;
        font-size: 11px;
        padding: 0 0 4px 8px;
        line-height: 1;
      }
      .log-close:hover { color: var(--text, #e5e5ea); }
      .error-msg {
        font-size: 11px;
        color: var(--error, #ff453a);
        padding: 8px 0;
      }
      .loading-msg {
        font-size: 11px;
        color: var(--text-secondary, #8a8a8e);
        padding: 8px 0;
        font-style: italic;
      }
    `;

    // Build daemon rows HTML.
    let bodyHtml = '';
    if (!data) {
      bodyHtml = `<p class="loading-msg">Loading daemon status…</p>`;
    } else if (data.error) {
      bodyHtml = `<p class="error-msg">Error: ${this.#esc(data.error)}</p>`;
    } else {
      const daemons = data.daemons || [];
      if (daemons.length === 0) {
        bodyHtml = `<p class="loading-msg">No daemon data returned.</p>`;
      } else {
        const loaded = daemons.filter(d => d.plist === 'yes' && d.loaded === 'yes').length;
        const total = daemons.length;
        const countHtml = `<span class="panel-counts">${loaded}/${total} loaded</span>`;

        const rows = daemons.map(d => {
          const status = this.#statusForDaemon(d);
          const color = this.#colorForStatus(status);
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
              <span class="daemon-pill" style="background:${color}22;color:${color};border:1px solid ${color}55;">
                <span class="pill-dot" style="background:${color};"></span>
                ${this.#esc(pillLabel)}
              </span>
            </li>`;
        }).join('');

        bodyHtml = `
          <div class="panel-header">
            <span class="panel-title">Daemon set</span>
            ${countHtml}
          </div>
          <ul class="daemon-list">${rows}</ul>`;
      }
    }

    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      ${bodyHtml}
      <div class="log-pane" id="log-pane" hidden>
        <button class="log-close" id="log-close" aria-label="Close log">close</button>
        <div class="log-title" id="log-title"></div>
        <pre class="log-pre" id="log-pre"></pre>
      </div>
    `;

    // Wire click handlers on daemon rows.
    this.#shadow.querySelectorAll('.daemon-row').forEach(row => {
      const handler = (e) => {
        if (e.type === 'keydown' && e.key !== 'Enter' && e.key !== ' ') return;
        e.preventDefault();
        const label = row.dataset.label;
        if (this.#expandedLabel === label) {
          // Collapse.
          this.#expandedLabel = null;
          this.#renderLogPane();
          row.classList.remove('expanded');
          row.setAttribute('aria-expanded', 'false');
        } else {
          // Expand — collapse previous.
          this.#shadow.querySelectorAll('.daemon-row.expanded').forEach(r => {
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

    // Wire log-close button.
    const closeBtn = this.#shadow.getElementById('log-close');
    if (closeBtn) {
      closeBtn.addEventListener('click', () => {
        this.#expandedLabel = null;
        this.#shadow.querySelectorAll('.daemon-row.expanded').forEach(r => {
          r.classList.remove('expanded');
          r.setAttribute('aria-expanded', 'false');
        });
        const pane = this.#shadow.getElementById('log-pane');
        if (pane) pane.hidden = true;
      });
    }

    // Re-render log pane with cached content.
    this.#renderLogPane();
  }

  // Re-render log pane contents without a full shadow DOM rebuild.
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

  #esc(str) {
    return String(str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
}

customElements.define('chump-daemon-set-panel', ChumpDaemonSetPanel);
