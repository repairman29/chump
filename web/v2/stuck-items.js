// web/v2/stuck-items.js — PRODUCT-080
//
// <chump-stuck-items> — PWA component that surfaces stuck fleet items
// (stuck PRs, expired leases, fleet wedges, fat worktrees, disk pressure)
// with one-click rescue actions.
//
// Fetches /api/stuck every 5 seconds. On rescue button click:
//   1. Emits ambient kind=operator_rescue_invoked via POST /api/stuck/rescue/{id}
//   2. Disables the button (prevents double-click)
//   3. Shows inline success/error state
//   4. Backend emits kind=rescue_result on completion

const POLL_MS = 5_000;

const SEVERITY_STYLE = {
  HIGH: 'background:#3a1a1a; border-color:#c0392b; color:#e74c3c;',
  MED:  'background:#2a2510; border-color:#c09a00; color:#f0c030;',
  LOW:  'background:#1a1a2a; border-color:#3a3a5a; color:#8a8aae;',
};

const KIND_ICON = {
  fleet_wedge:          '🔒',
  disk_critical:        '💾',
  pr_stuck:             '⛔',
  silent_agent:         '🔇',
  lease_expired_server: '🔑',
  fat_worktree:         '🗂️',
  reaper_silent:        '👻',
};

const CSS = `
  :host {
    display: block;
    font-family: inherit;
  }
  .si-wrap {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .si-header {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--text-secondary, #8a8a8e);
    margin-bottom: 4px;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .si-count-badge {
    font-size: 10px;
    background: var(--accent, #0a84ff);
    color: #fff;
    border-radius: 10px;
    padding: 1px 6px;
    font-weight: 700;
  }
  .si-empty {
    font-size: 12px;
    color: var(--text-secondary, #8a8a8e);
    padding: 8px 4px;
    font-style: italic;
  }
  .si-item {
    border: 1px solid var(--border, #2a2a2e);
    border-radius: 8px;
    padding: 8px 10px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    transition: opacity 0.2s;
  }
  .si-item.rescuing { opacity: 0.6; }
  .si-row {
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .si-icon { font-size: 14px; flex-shrink: 0; }
  .si-kind {
    font-size: 12px;
    font-weight: 600;
    color: var(--text, #e5e5ea);
    flex: 1;
    min-width: 0;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .si-severity {
    font-size: 10px;
    font-weight: 700;
    padding: 1px 5px;
    border-radius: 4px;
    border: 1px solid;
    flex-shrink: 0;
  }
  .si-age {
    font-size: 11px;
    color: var(--text-secondary, #8a8a8e);
  }
  .si-action {
    font-size: 11px;
    color: var(--text-secondary, #8a8a8e);
    font-style: italic;
  }
  .si-pr {
    font-size: 11px;
    color: var(--accent, #0a84ff);
  }
  .si-rescue-btn {
    align-self: flex-end;
    font-size: 11px;
    padding: 3px 10px;
    border-radius: 6px;
    border: 1px solid var(--accent, #0a84ff);
    background: transparent;
    color: var(--accent, #0a84ff);
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
    white-space: nowrap;
  }
  .si-rescue-btn:hover:not(:disabled) {
    background: var(--accent, #0a84ff);
    color: #fff;
  }
  .si-rescue-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
    border-color: var(--border, #2a2a2e);
    color: var(--text-secondary, #8a8a8e);
  }
  .si-result {
    font-size: 11px;
    padding: 2px 6px;
    border-radius: 4px;
    margin-top: 2px;
  }
  .si-result.ok  { background: #0d2a1a; color: #4cd964; border: 1px solid #1a5a2a; }
  .si-result.err { background: #2a0d0d; color: #e74c3c; border: 1px solid #5a1a1a; }
  .si-loading {
    font-size: 11px;
    color: var(--text-secondary, #8a8a8e);
    padding: 4px;
  }
  .si-error {
    font-size: 11px;
    color: #e74c3c;
    padding: 4px;
  }
`;

function fmtAge(ageSecs) {
  if (ageSecs < 60) return `${ageSecs}s ago`;
  if (ageSecs < 3600) return `${Math.round(ageSecs / 60)}m ago`;
  return `${Math.round(ageSecs / 3600)}h ago`;
}

function getCsrfToken() {
  // Same pattern used by other PWA components — check meta tag or cookie.
  const meta = document.querySelector('meta[name="csrf-token"]');
  if (meta) return meta.content;
  // Fallback: header value that the backend just checks for presence.
  return 'pwa-csrf';
}

class ChumpStuckItems extends HTMLElement {
  #shadow;
  #items = [];
  #emptyState = null;
  #loading = true;
  #error = null;
  #timer = null;
  #rescueState = {}; // id → { busy, result }

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#render();
    this.#poll();
    this.#timer = setInterval(() => this.#poll(), POLL_MS);
  }

  disconnectedCallback() {
    if (this.#timer) {
      clearInterval(this.#timer);
      this.#timer = null;
    }
  }

  async #poll() {
    try {
      const token = getCsrfToken();
      const headers = { 'x-csrf-token': token };
      const authToken = window.chumpPrefs?.get('auth-token') ||
        sessionStorage.getItem('chump-auth-token');
      if (authToken) headers['Authorization'] = `Bearer ${authToken}`;

      const res = await fetch('/api/stuck', { headers });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      this.#items = data.items || [];
      this.#emptyState = data.empty_state || null;
      this.#loading = false;
      this.#error = null;
    } catch (e) {
      this.#error = e.message;
      this.#loading = false;
    }
    this.#render();
  }

  async #rescue(item) {
    const id = item.id;
    this.#rescueState[id] = { busy: true, result: null };
    this.#render();

    try {
      const token = getCsrfToken();
      const headers = {
        'Content-Type': 'application/json',
        'x-csrf-token': token,
      };
      const authToken = window.chumpPrefs?.get('auth-token') ||
        sessionStorage.getItem('chump-auth-token');
      if (authToken) headers['Authorization'] = `Bearer ${authToken}`;

      const body = { kind: item.kind };
      if (item.pr) body.pr = String(item.pr);

      const res = await fetch(`/api/stuck/rescue/${encodeURIComponent(id)}`, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
      });
      const data = await res.json();
      this.#rescueState[id] = {
        busy: false,
        result: { ok: data.ok, message: data.message || (data.ok ? 'Done.' : 'Failed.') },
      };
    } catch (e) {
      this.#rescueState[id] = { busy: false, result: { ok: false, message: e.message } };
    }
    this.#render();
  }

  #render() {
    const shadow = this.#shadow;

    // Build HTML string.
    let inner = '';

    if (this.#loading) {
      inner = `<div class="si-loading">Loading stuck items…</div>`;
    } else if (this.#error) {
      inner = `<div class="si-error">Error: ${this.#esc(this.#error)}</div>`;
    } else if (this.#items.length === 0) {
      inner = `<div class="si-empty">${this.#esc(this.#emptyState || 'Nothing stuck.')}</div>`;
    } else {
      const countBadge = `<span class="si-count-badge">${this.#items.length}</span>`;
      const itemsHtml = this.#items.map(item => this.#renderItem(item)).join('');
      inner = `
        <div class="si-header">
          <span>Stuck Items</span>${countBadge}
        </div>
        ${itemsHtml}
      `;
    }

    shadow.innerHTML = `<style>${CSS}</style><div class="si-wrap">${inner}</div>`;

    // Wire rescue buttons (can't do inline onclick in shadow DOM easily).
    shadow.querySelectorAll('.si-rescue-btn').forEach(btn => {
      const itemId = btn.dataset.itemId;
      btn.addEventListener('click', () => {
        const item = this.#items.find(i => i.id === itemId);
        if (item) this.#rescue(item);
      });
    });
  }

  #renderItem(item) {
    const id = item.id;
    const sev = item.severity || 'LOW';
    const sevStyle = SEVERITY_STYLE[sev] || SEVERITY_STYLE.LOW;
    const icon = KIND_ICON[item.kind] || '⚠️';
    const rs = this.#rescueState[id] || { busy: false, result: null };

    const prLine = item.pr ? `<div class="si-pr">PR #${this.#esc(String(item.pr))}</div>` : '';
    const ageLine = `<div class="si-age">${fmtAge(item.age_secs || 0)}</div>`;
    const actionLine = `<div class="si-action">${this.#esc(item.rescue_action || '')}</div>`;

    const btnDisabled = rs.busy ? 'disabled' : '';
    const btnText = rs.busy ? 'Rescuing…' : 'Rescue';
    const itemClass = rs.busy ? 'si-item rescuing' : 'si-item';

    let resultHtml = '';
    if (rs.result) {
      const cls = rs.result.ok ? 'ok' : 'err';
      const prefix = rs.result.ok ? '✓' : '✗';
      resultHtml = `<div class="si-result ${cls}">${prefix} ${this.#esc(rs.result.message)}</div>`;
    }

    return `
      <div class="${itemClass}" style="${sevStyle}">
        <div class="si-row">
          <span class="si-icon">${icon}</span>
          <span class="si-kind">${this.#esc(item.kind)}</span>
          <span class="si-severity" style="${sevStyle}">${sev}</span>
        </div>
        ${prLine}
        ${ageLine}
        ${actionLine}
        ${resultHtml}
        <button class="si-rescue-btn" data-item-id="${this.#esc(id)}" ${btnDisabled}>${btnText}</button>
      </div>
    `;
  }

  #esc(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }
}

customElements.define('chump-stuck-items', ChumpStuckItems);
