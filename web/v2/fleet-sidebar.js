// fleet-sidebar.js — INFRA-1010 (token-aligned in PRODUCT-372)
//
// Live fleet activity board combining /api/fleet-status with /api/ambient/stream.

const KINDS_WHITELIST = [
  'lease_acquired',
  'lease_released',
  'gap_shipped',
  'scratch_commit_blocked',
  'fleet_auth_fallback',
  'pr_stuck',
  'fleet_wedge',
];

const KIND_PREFIXES = ['phase_', 'ship_'];
const MAX_ROWS = 8;

class ChumpFleetSidebar extends HTMLElement {
  constructor() {
    super();
    this._sessions = new Map();
    this._lastEvents = new Map();
    this._sse = null;
    this._pollTimer = null;
    this._error = null;
    this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this._render();
    this._loadSnapshot();
    this._connectSse();
    this._pollTimer = setInterval(() => this._loadSnapshot(), 30_000);
  }

  disconnectedCallback() {
    if (this._sse) {
      try { this._sse.close(); } catch {}
      this._sse = null;
    }
    if (this._pollTimer) {
      clearInterval(this._pollTimer);
      this._pollTimer = null;
    }
  }

  _authHeaders() {
    try {
      const t = window.chumpPrefs && window.chumpPrefs.get
        ? window.chumpPrefs.get('webToken')
        : null;
      if (t) return { 'X-Chump-Auth': t, Authorization: `Bearer ${t}` };
    } catch {}
    return {};
  }

  _loadSnapshot() {
    const headers = this._authHeaders();
    const opts = { credentials: 'same-origin', headers };
    const f = window.apiFetch ? window.apiFetch('/api/fleet-status', opts) : fetch('/api/fleet-status', opts);
    f.then((r) => {
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return r.json();
    }).then((d) => {
      this._error = null;
      const sessions = Array.isArray(d.sessions) ? d.sessions : [];
      this._sessions = new Map();
      for (const s of sessions) {
        if (s && s.gap_id) this._sessions.set(s.gap_id, s);
      }
      this._renderRows();
    }).catch((err) => {
      this._error = `Could not load fleet status: ${err.message}`;
      this._renderRows();
    });
  }

  _connectSse() {
    const url = new URL('/api/ambient/stream', window.location.origin);
    url.searchParams.set('kinds', KINDS_WHITELIST.join(','));
    url.searchParams.set('prefixes', KIND_PREFIXES.join(','));
    try {
      this._sse = new EventSource(url.toString(), { withCredentials: true });
      this._sse.addEventListener('ambient', (e) => this._onEvent(e));
      this._sse.onerror = () => {};
    } catch {
      this._sse = null;
    }
  }

  _onEvent(e) {
    let v;
    try { v = JSON.parse(e.data); } catch { return; }
    const kind = v.kind || v.event || '';
    const ts = v.ts || new Date().toISOString();
    const gapId = v.gap_id || v.gap || (v.detail && v.detail.gap_id) || null;

    if (gapId) {
      this._lastEvents.set(gapId, { kind, ts });
      if (kind === 'lease_acquired' && !this._sessions.has(gapId)) {
        this._sessions.set(gapId, {
          gap_id: gapId,
          gap_title: v.gap_title || '',
          gap_priority: v.priority || '',
          gap_effort: v.effort || '',
          session_id: v.session_id || '',
          branch: v.branch || `chump/${String(gapId).toLowerCase()}-claim`,
          taken_at: ts,
          heartbeat_at: ts,
        });
      }
      if (kind === 'lease_released' || kind === 'gap_shipped') {
        this._sessions.delete(gapId);
        this._lastEvents.delete(gapId);
      }
    }
    this._renderRows();
  }

  _esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
  }

  _age(iso) {
    try {
      const ms = Date.now() - new Date(iso).getTime();
      if (Number.isNaN(ms) || ms < 0) return '?';
      const s = Math.floor(ms / 1000);
      if (s < 60) return `${s}s`;
      const m = Math.floor(s / 60);
      if (m < 60) return `${m}m`;
      const h = Math.floor(m / 60);
      return `${h}h${m % 60 ? `${m % 60}m` : ''}`;
    } catch { return '?'; }
  }

  _onRowClick(gapId) {
    this.dispatchEvent(new CustomEvent('chump:open-timeline', {
      bubbles: true, composed: true,
      detail: { gap_id: gapId },
    }));
  }

  _render() {
    this.shadowRoot.innerHTML = `
      <style>
        :host { display: block; font-family: var(--font-sans); font-size: 12.5px; color: var(--text); }
        .meta { font-size: 11px; color: var(--text-secondary); margin-bottom: 6px; font-family: var(--font-mono); }
        .empty {
          padding: 12px 14px;
          color: var(--text-secondary);
          background: var(--bg);
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          font-size: 12px;
        }
        .err {
          padding: 8px 10px;
          background: var(--tone-err-bg);
          color: var(--error);
          border: 1px solid var(--tone-err-border);
          border-radius: var(--radius-sm);
          margin-bottom: 8px;
          font-size: 12px;
        }
        .row {
          display: grid;
          grid-template-columns: auto 1fr auto;
          gap: 10px;
          align-items: center;
          padding: 8px 10px;
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          background: var(--bg-surface);
          margin-bottom: 5px;
          cursor: pointer;
          transition: background 0.12s, border-color 0.12s;
        }
        .row:hover { background: var(--bg-elevated); border-color: var(--border-strong); }
        .gap { font-weight: 600; color: var(--accent); font-family: var(--font-mono); font-size: 11.5px; }
        .title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text); font-size: 12px; }
        .meta-line { font-size: 10.5px; color: var(--text-secondary); margin-top: 2px; display: flex; align-items: center; gap: 6px; }
        .phase {
          font-family: var(--font-mono);
          font-size: 9.5px;
          font-weight: 600;
          padding: 1px 6px;
          border-radius: 999px;
          background: var(--accent-dim);
          color: var(--accent);
        }
        .phase-ship  { background: var(--tone-ok-bg); color: var(--success); }
        .phase-stuck { background: var(--tone-warn-bg); color: var(--warn); }
        .phase-wedge { background: var(--tone-err-bg); color: var(--error); }
        .age { font-family: var(--font-mono); font-size: 11px; color: var(--text-secondary); font-variant-numeric: tabular-nums; }
      </style>
      <div class="meta" id="meta"></div>
      <div id="err-host"></div>
      <div id="rows"></div>
    `;
  }

  _renderRows() {
    if (!this.shadowRoot) return;
    const rowsEl = this.shadowRoot.getElementById('rows');
    const metaEl = this.shadowRoot.getElementById('meta');
    const errHost = this.shadowRoot.getElementById('err-host');
    if (!rowsEl || !metaEl || !errHost) return;

    errHost.innerHTML = this._error
      ? `<div class="err">${this._esc(this._error)}</div>` : '';

    const all = Array.from(this._sessions.values());
    all.sort((a, b) => String(a.taken_at || '').localeCompare(String(b.taken_at || '')));
    const visible = all.slice(0, MAX_ROWS);

    metaEl.textContent = all.length === 0
      ? ''
      : `${all.length} active session${all.length !== 1 ? 's' : ''}${all.length > MAX_ROWS ? ` (showing ${MAX_ROWS})` : ''}`;

    if (visible.length === 0) {
      rowsEl.innerHTML = '<div class="empty">No active worker leases. Claim or dispatch a gap from the center queue to start a session.</div>';
      return;
    }

    rowsEl.innerHTML = visible.map((s) => {
      const gapId = s.gap_id || '—';
      const title = s.gap_title || 'Active session lease';
      const taken = s.taken_at || '';
      const last = this._lastEvents.get(gapId);
      const lastKind = last ? last.kind : '';
      let phaseClass = '';
      if (lastKind === 'pr_stuck') phaseClass = 'phase-stuck';
      else if (lastKind === 'fleet_wedge') phaseClass = 'phase-wedge';
      else if (lastKind.startsWith('ship_') || lastKind === 'gap_shipped') phaseClass = 'phase-ship';
      const phaseLabel = lastKind || (s.gap_priority ? `${s.gap_priority}/${s.gap_effort || '?'}` : 'leased');

      return `
        <div class="row" data-gap="${this._esc(gapId)}" role="button"
             tabindex="0" aria-label="Open timeline for ${this._esc(gapId)}">
          <span class="gap">${this._esc(gapId)}</span>
          <div style="min-width:0">
            <div class="title" title="${this._esc(title)}">${this._esc(title)}</div>
            <div class="meta-line">
              <span class="phase ${phaseClass}">${this._esc(phaseLabel)}</span>
              ${taken ? `<span>started ${this._esc(this._age(taken))} ago</span>` : ''}
            </div>
          </div>
          <span class="age">${this._esc(this._age(taken))}</span>
        </div>
      `;
    }).join('');

    this.shadowRoot.querySelectorAll('.row').forEach((el) => {
      el.addEventListener('click', () => this._onRowClick(el.dataset.gap));
      el.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          this._onRowClick(el.dataset.gap);
        }
      });
    });
  }
}

customElements.define('chump-fleet-sidebar', ChumpFleetSidebar);
