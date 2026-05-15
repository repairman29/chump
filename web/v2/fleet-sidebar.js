// fleet-sidebar.js — INFRA-1010
//
// Live fleet activity board. Combines:
//   - GET /api/fleet-status  (initial snapshot + 30s safety-net poll)
//   - GET /api/ambient/stream?kinds=…&prefixes=…  (real-time event push, <2s)
//
// Rows are one-per-active-worker, sorted by taken_at ascending (oldest first,
// to surface stalls). Each row shows {gap_id, phase, started_at, last_event}.
// Click a row to dispatch chump:open-timeline (INFRA-1007 router).
//
// AC #1: SSE filtered server-side via new kinds=csv / prefixes=csv params
// AC #2: visible on main UI as <chump-fleet-sidebar>; up to 8 active workers
// AC #3: sorted by taken_at ascending
// AC #4: click → chump:open-timeline custom event
// AC #5: empty state when fleet idle
// AC #6: lease_acquired + phase_start within 2s → row reflects update
//
// PRODUCT-106 cadence: Ambient → Fleet sub-tab (existing chump-view-agents
// now embeds this for SSE; the polling-only legacy logic remains as a 30s
// safety net inside this component).

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
    /** @type {Map<string, object>} gap_id → session */
    this._sessions = new Map();
    /** @type {Map<string, {kind:string, ts:string}>} gap_id → last interesting event */
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
      try { this._sse.close(); } catch (_e) {}
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
    } catch (_e) {}
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
      // Rebuild the map preserving last-event entries.
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
      this._sse.onerror = () => {
        // Browser auto-reconnects; swallow noisy errors.
      };
    } catch (_e) {
      this._sse = null;
    }
  }

  _onEvent(e) {
    let v;
    try { v = JSON.parse(e.data); } catch (_e) { return; }
    const kind = v.kind || v.event || '';
    const ts = v.ts || new Date().toISOString();

    // Resolve the gap_id from common locations on the event.
    const gapId = v.gap_id
      || v.gap
      || (v.detail && v.detail.gap_id)
      || null;

    if (gapId) {
      this._lastEvents.set(gapId, { kind, ts });

      // Insert a placeholder row immediately on lease_acquired so the user
      // sees the new worker before the next /api/fleet-status snapshot lands.
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

      // Remove on terminal events.
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
      .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
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
    // AC #4: clicking a row opens that gap's timeline (INFRA-1007).
    this.dispatchEvent(new CustomEvent('chump:open-timeline', {
      bubbles: true, composed: true,
      detail: { gap_id: gapId },
    }));
  }

  _render() {
    this.shadowRoot.innerHTML = `
      <style>
        :host { display:block; font:13px -apple-system,BlinkMacSystemFont,system-ui,sans-serif; color:#f0f0f0; }
        h2 { font-size:14px; margin:0 0 8px; opacity:0.7; text-transform:uppercase; letter-spacing:1px; }
        .meta { font-size:11px; opacity:0.55; margin-bottom:8px; }
        .empty { padding:18px; text-align:center; opacity:0.55; border:1px dashed rgba(255,255,255,0.1); border-radius:6px; }
        .err { padding:8px; background:rgba(255,69,58,0.1); color:#ff453a; border:1px solid rgba(255,69,58,0.3); border-radius:4px; margin-bottom:8px; font-size:12px; }
        .row { display:grid; grid-template-columns: 90px 1fr auto; gap:8px; align-items:center; padding:8px 10px; border-bottom:1px solid rgba(255,255,255,0.06); cursor:pointer; }
        .row:hover { background:rgba(255,255,255,0.04); }
        .gap { font-weight:600; color:#0a84ff; font-family:ui-monospace,Menlo,monospace; font-size:12px; }
        .title { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; opacity:0.9; }
        .meta-line { font-size:11px; opacity:0.6; margin-top:2px; }
        .phase { font-size:10px; padding:1px 6px; border-radius:10px; background:rgba(10,132,255,0.2); color:#0a84ff; letter-spacing:0.5px; }
        .phase-ship { background:rgba(48,209,88,0.2); color:#30d158; }
        .phase-stuck { background:rgba(255,159,10,0.2); color:#ff9f0a; }
        .phase-wedge { background:rgba(255,69,58,0.2); color:#ff453a; }
        .age { font-size:11px; opacity:0.55; font-variant-numeric: tabular-nums; }
      </style>
      <h2>Fleet · Live</h2>
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
    // AC #3: sort by taken_at ascending (oldest first → highlight stalls).
    all.sort((a, b) => String(a.taken_at || '').localeCompare(String(b.taken_at || '')));
    // AC #2: up to 8 rows.
    const visible = all.slice(0, MAX_ROWS);

    metaEl.textContent = all.length === 0
      ? ''
      : `${all.length} active worker${all.length !== 1 ? 's' : ''}${all.length > MAX_ROWS ? ` (showing ${MAX_ROWS})` : ''}`;

    if (visible.length === 0) {
      // AC #5: empty state.
      rowsEl.innerHTML = '<div class="empty">No workers active — dispatch a gap to start.</div>';
      return;
    }

    rowsEl.innerHTML = visible.map((s) => {
      const gapId = s.gap_id || '—';
      const title = s.gap_title || '(no title)';
      const taken = s.taken_at || '';
      const last = this._lastEvents.get(gapId);
      const lastKind = last ? last.kind : '';
      let phaseClass = '';
      if (lastKind === 'pr_stuck') phaseClass = 'phase-stuck';
      else if (lastKind === 'fleet_wedge') phaseClass = 'phase-wedge';
      else if (lastKind.startsWith('ship_') || lastKind === 'gap_shipped') phaseClass = 'phase-ship';
      const phaseLabel = lastKind || (s.gap_priority ? `${s.gap_priority}/${s.gap_effort || '?'}` : 'running');

      return `
        <div class="row" data-gap="${this._esc(gapId)}" role="button"
             tabindex="0" aria-label="Open timeline for ${this._esc(gapId)}">
          <span class="gap">${this._esc(gapId)}</span>
          <div>
            <div class="title" title="${this._esc(title)}">${this._esc(title)}</div>
            <div class="meta-line">
              <span class="phase ${phaseClass}">${this._esc(phaseLabel)}</span>
              ${taken ? `<span style="margin-left:6px">started ${this._esc(this._age(taken))} ago</span>` : ''}
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
