// wedge-watch.js — EFFECTIVE-027
//
// <chump-wedge-watch> — Live-tail panel for WEDGE-class ambient events.
//
// Surfaces fleet friction in real-time so the operator sees a wedge the
// moment it fires rather than discovering it minutes later via stuck PRs.
//
// Data source: /api/ambient/stream (SSE — same source as chump-ambient-viewer).
// The SSE stream multiplexes all ambient events; this component client-side
// filters to the WEDGE_KINDS set (no new backend surface required).
//
// Live event feed shows:
//   - timestamp (UTC time portion, e.g. 14:32:01)
//   - wedge class/kind (e.g. pr_stuck, W-007)
//   - short summary (note/title/pr_number)
//   - minutes_lost if present
//
// Summary bar (top-N by count × minutes_lost over recent window):
//   - mirrors the ambient-context-inject.sh "Top-3 wedge classes" view
//   - updates every time a new wedge event arrives
//
// Empty state: "No wedges detected — fleet flowing" (not blank/error).
//
// Buffer capped at MAX_BUFFER = 200 to keep DOM bounded under storm
// conditions. Auto-pins to bottom unless the operator scrolls up.
//
// W-001..W-013 taxonomy is embedded here (from scripts/coord/wizard-daemon.sh)
// so the panel can show human-readable class names without a backend call.
//
// Registered in cockpit.js right-zone alongside chump-daemon-set-panel (EFFECTIVE-026).

// ── Wedge-class taxonomy (W-001..W-013) ──────────────────────────────────────
// Source of truth: scripts/coord/wizard-daemon.sh CATALOG + wedge-state-machine.sh
const WEDGE_TAXONOMY = {
  'W-001': { label: 'gh API false-positive merge conflict', icon: '🔀' },
  'W-002': { label: 'Runner-side binary cache lag',         icon: '📦' },
  'W-003': { label: 'Config-warning stdout pollution',      icon: '⚙️' },
  'W-004': { label: 'SQLite lock contention',               icon: '🔒' },
  'W-005': { label: 'GIT_DIR env-leak into CI',             icon: '🔗' },
  'W-007': { label: 'Required-status-check absent',         icon: '🚦' },
  'W-008': { label: 'Auto-merge wedged on CLEAN',           icon: '⏸' },
  'W-009': { label: 'Cascade keystone blocked',             icon: '🧱' },
  'W-010': { label: 'Multi-layer branch protection',        icon: '🛡' },
  'W-011': { label: 'Installer-manifest drift',             icon: '📄' },
  'W-012': { label: 'Workflow-env overhead cascade',        icon: '🔄' },
  'W-013': { label: 'Ambient path mismatch',                icon: '📂' },
};

// ── Ambient event kinds that represent fleet friction / wedges ────────────────
// These are the kinds this panel listens for and displays.
const WEDGE_KINDS = new Set([
  'fleet_wedge',
  'pr_stuck',
  'pr_stuck_announced',
  'lease_overlap',
  'silent_agent',
  'edit_burst',
  'force_recover_wip_loss',
  'sccache_error',
  'wedge_class_detected',
  'wedge_remediated_real',
  'wedge_remediated',
  'cluster_detected',
  // ALERT wrapper events — these carry a wedge-class kind nested as .kind
  // We handle them in _isWedgeEvent by also checking the outer kind=ALERT
]);

// Human-friendly kind labels
const KIND_LABELS = {
  fleet_wedge:            'Fleet wedge',
  pr_stuck:               'PR stuck',
  pr_stuck_announced:     'PR stuck (announced)',
  lease_overlap:          'Lease overlap',
  silent_agent:           'Silent agent',
  edit_burst:             'Edit burst',
  force_recover_wip_loss: 'Force-recover WIP loss',
  sccache_error:          'sccache error',
  wedge_class_detected:   'Wedge detected',
  wedge_remediated_real:  'Wedge remediated',
  wedge_remediated:       'Wedge remediated',
  cluster_detected:       'Cluster detected',
  ALERT:                  'Alert',
};

// Severity colouring for event badges
const KIND_SEVERITY = {
  fleet_wedge:            'critical',
  pr_stuck:               'warn',
  pr_stuck_announced:     'warn',
  silent_agent:           'warn',
  lease_overlap:          'info',
  edit_burst:             'info',
  force_recover_wip_loss: 'critical',
  sccache_error:          'warn',
  wedge_class_detected:   'warn',
  wedge_remediated_real:  'ok',
  wedge_remediated:       'ok',
  cluster_detected:       'info',
  ALERT:                  'warn',
};

const CSS = `
  :host {
    display: block;
    font-family: inherit;
    color: var(--text, #e5e5ea);
    font-size: 13px;
    height: 100%;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }

  /* ── Summary bar ─────────────────────────────────────────────────── */
  .ww-summary {
    flex: 0 0 auto;
    padding: 8px 10px;
    background: var(--bg, #0d0d0f);
    border: 1px solid var(--border, #2a2a2e);
    border-radius: 7px;
    margin-bottom: 8px;
    font-size: 11px;
  }
  .ww-summary-label {
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-secondary, #8a8a8e);
    margin-bottom: 6px;
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .ww-summary-conn {
    font-size: 10px;
    font-weight: 500;
    letter-spacing: 0;
    text-transform: none;
  }
  .ww-summary-conn.live         { color: #30d158; }
  .ww-summary-conn.reconnecting { color: #ffd60a; }
  .ww-summary-conn.error        { color: #ff453a; }
  .ww-summary-conn.connecting   { color: #8a8a8e; }
  .ww-summary-empty {
    color: var(--text-secondary, #8a8a8e);
    font-style: italic;
  }
  .ww-top {
    display: flex;
    flex-direction: column;
    gap: 3px;
  }
  .ww-top-row {
    display: flex;
    gap: 8px;
    align-items: center;
    padding: 3px 0;
  }
  .ww-top-rank {
    color: var(--text-secondary, #8a8a8e);
    font-size: 10px;
    min-width: 14px;
  }
  .ww-top-class {
    font-weight: 600;
    color: var(--text, #e5e5ea);
    min-width: 60px;
  }
  .ww-top-desc {
    color: var(--text-secondary, #8a8a8e);
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .ww-top-stats {
    color: #ffd60a;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }

  /* ── Event list ──────────────────────────────────────────────────── */
  .ww-list-wrap {
    flex: 1 1 auto;
    min-height: 0;
    position: relative;
    overflow: hidden;
    border: 1px solid var(--border, #2a2a2e);
    border-radius: 7px;
  }
  .ww-list {
    list-style: none;
    margin: 0;
    padding: 0;
    height: 100%;
    overflow-y: auto;
  }
  .ww-empty {
    padding: 20px 16px;
    text-align: center;
    color: var(--text-secondary, #8a8a8e);
    font-size: 12px;
    border: 1px dashed var(--border, #2a2a2e);
    border-radius: 6px;
    margin: 12px 8px;
  }
  .ww-empty strong {
    display: block;
    color: #30d158;
    font-size: 13px;
    margin-bottom: 4px;
  }

  /* ── Per-event row ───────────────────────────────────────────────── */
  .ww-row {
    padding: 6px 10px;
    border-bottom: 1px solid var(--border, #2a2a2e);
    display: grid;
    grid-template-columns: 58px auto 1fr auto;
    gap: 0 8px;
    align-items: start;
    cursor: pointer;
    transition: background 0.1s;
  }
  .ww-row:last-child { border-bottom: none; }
  .ww-row:hover { background: var(--bg-tertiary, #25252a); }

  .ww-ts {
    font-size: 10px;
    color: var(--text-secondary, #8a8a8e);
    font-variant-numeric: tabular-nums;
    padding-top: 1px;
    white-space: nowrap;
  }
  .ww-badge {
    font-size: 10px;
    font-weight: 600;
    padding: 2px 6px;
    border-radius: 4px;
    white-space: nowrap;
    line-height: 1.4;
  }
  .ww-badge.critical { background: rgba(204,51,68,.22);  color: #ff8a99; }
  .ww-badge.warn     { background: rgba(255,159,10,.22); color: #ffcc5c; }
  .ww-badge.info     { background: rgba(10,132,255,.18); color: #6ab8ff; }
  .ww-badge.ok       { background: rgba(48,209,88,.20);  color: #6cd9a0; }

  .ww-body {
    min-width: 0;
  }
  .ww-summary-text {
    color: var(--text, #e5e5ea);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 12px;
  }
  .ww-class-tag {
    font-size: 10px;
    color: var(--accent, #0a84ff);
    margin-top: 1px;
  }
  .ww-minutes {
    font-size: 10px;
    color: #ffd60a;
    white-space: nowrap;
    text-align: right;
    padding-top: 1px;
  }

  /* Drill-in detail */
  .ww-detail {
    grid-column: 1 / -1;
    margin: 4px 0 2px;
    font-family: ui-monospace, 'Cascadia Code', monospace;
    font-size: 10px;
    color: var(--text-secondary, #8a8a8e);
    background: var(--bg, #0d0d0f);
    border: 1px solid var(--border, #2a2a2e);
    border-radius: 4px;
    padding: 6px 8px;
    white-space: pre-wrap;
    word-break: break-all;
  }

  /* ── "↓ N new" pill ──────────────────────────────────────────────── */
  .ww-pill {
    position: absolute;
    bottom: 8px;
    right: 12px;
    background: var(--accent, #0a84ff);
    color: white;
    font-size: 11px;
    font-weight: 600;
    padding: 3px 10px;
    border-radius: 12px;
    cursor: pointer;
    pointer-events: all;
    z-index: 10;
    box-shadow: 0 2px 6px rgba(0,0,0,.4);
  }
  .ww-pill:hover { filter: brightness(1.15); }
`;

class ChumpWedgeWatch extends HTMLElement {
  #shadow;
  #es = null;
  #buffer = [];
  #pinnedToBottom = true;
  #pendingNew = 0;
  #connState = 'connecting';
  #agg = {}; // wedge_class/kind -> { count, minutes_lost }

  static #MAX_BUFFER = 200;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#renderShell();
    this.#subscribe();
    // Also do a one-shot historical fetch from /api/ambient/recent to pre-populate
    // with any wedge events already in the recent window.
    this.#backfill();
  }

  disconnectedCallback() {
    if (this.#es) { this.#es.close(); this.#es = null; }
  }

  // ── SSE subscription ────────────────────────────────────────────────────────

  #subscribe() {
    if (this.#es) { this.#es.close(); this.#es = null; }
    this.#setConn('connecting');
    let url = '/api/ambient/stream';
    try {
      this.#es = new EventSource(url);
    } catch {
      this.#setConn('error');
      return;
    }
    this.#es.addEventListener('open', () => this.#setConn('live'));
    this.#es.addEventListener('ambient', (e) => {
      let payload;
      try { payload = JSON.parse(e.data); } catch { return; }
      if (this.#isWedgeEvent(payload)) {
        this.#onEvent(payload);
      }
    });
    this.#es.addEventListener('error', () => {
      this.#setConn('reconnecting');
      // Browser will auto-reconnect EventSource; update state indicator.
      // When it reconnects the 'open' event fires again.
    });
  }

  // ── Historical backfill ─────────────────────────────────────────────────────
  // Pull the last 200 events from /api/ambient/recent and filter client-side
  // so the panel isn't empty when first opened.

  async #backfill() {
    try {
      const r = await fetch('/api/ambient/recent?limit=200');
      if (!r.ok) return;
      const d = await r.json();
      const events = (d.events || []).filter((e) => this.#isWedgeEvent(e));
      // events come back newest-first from /api/ambient/recent; reverse to show oldest-first
      events.reverse().forEach((e) => this.#onEvent(e, /* fromBackfill */ true));
      if (events.length > 0) this.#jumpToBottom();
    } catch {
      // Graceful: no-op if endpoint unavailable
    }
  }

  // ── Wedge event detection ───────────────────────────────────────────────────

  #isWedgeEvent(payload) {
    const k = String(payload.kind || payload.event || '').toLowerCase();
    // Direct kind match
    if (WEDGE_KINDS.has(k) || WEDGE_KINDS.has(payload.kind)) return true;
    // Event has a wedge_class field (wizard-daemon style)
    if (payload.wedge_class) return true;
    // ALERT wrapper with a wedge-flavored inner kind
    if (k === 'alert' && payload.kind === 'ALERT') {
      const note = String(payload.note || '').toLowerCase();
      // ALERT events whose note contains wedge-signal keywords.
      // Covers: pr_stuck BLOCKED/DIRTY wrappers, silent_agent (last_event_age),
      // force_recover wip_loss, stall events, and wedge class mentions.
      if (note.includes('blocked') || note.includes('dirty') ||
          note.includes('pr_stuck') || note.includes('silent_agent') ||
          note.includes('wedge') || note.includes('stall') ||
          note.includes('last_event_age') || note.includes('wip_loss')) {
        return true;
      }
    }
    return false;
  }

  // ── Event ingestion ─────────────────────────────────────────────────────────

  #onEvent(payload, fromBackfill = false) {
    // Buffer management
    this.#buffer.push(payload);
    if (this.#buffer.length > ChumpWedgeWatch.#MAX_BUFFER) {
      // Drop oldest entries and remove from DOM too
      const toDrop = this.#buffer.length - ChumpWedgeWatch.#MAX_BUFFER;
      this.#buffer.splice(0, toDrop);
      const list = this.#shadow.querySelector('.ww-list');
      if (list) {
        for (let i = 0; i < toDrop; i++) {
          const first = list.querySelector('.ww-row');
          if (first) list.removeChild(first);
        }
      }
    }

    // Aggregate for summary bar
    this.#aggregate(payload);
    this.#refreshSummary();

    // Render the row
    this.#appendRow(payload);

    // Remove empty-state placeholder if present
    const empty = this.#shadow.querySelector('.ww-empty');
    if (empty) empty.remove();

    if (!fromBackfill) {
      if (this.#pinnedToBottom) {
        this.#jumpToBottom();
      } else {
        this.#pendingNew += 1;
        this.#refreshPill();
      }
    }
  }

  // Aggregate wedge class counts × minutes_lost for the summary bar.
  #aggregate(payload) {
    // Determine the wedge class key: prefer explicit wedge_class field,
    // fall back to kind.
    const cls = payload.wedge_class
      || (WEDGE_KINDS.has(payload.kind) ? payload.kind : null)
      || payload.kind
      || 'unknown';
    const ml = Number(payload.minutes_lost) || 0;
    if (!this.#agg[cls]) {
      this.#agg[cls] = { count: 0, minutes_lost: 0 };
    }
    this.#agg[cls].count += 1;
    this.#agg[cls].minutes_lost += ml;
  }

  // ── DOM rendering ───────────────────────────────────────────────────────────

  #renderShell() {
    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="ww-summary">
        <div class="ww-summary-label">
          Top wedge classes (count × min lost)
          <span class="ww-summary-conn ${this.#connState}" id="ww-conn">● connecting</span>
        </div>
        <div id="ww-top-content">
          <div class="ww-summary-empty">Connecting to ambient stream…</div>
        </div>
      </div>
      <div class="ww-list-wrap">
        <ol class="ww-list" tabindex="0" aria-label="Wedge event stream">
          <div class="ww-empty">
            <strong>No wedges detected — fleet flowing</strong>
            Watching for: fleet_wedge, pr_stuck, silent_agent, lease_overlap,
            edit_burst, sccache_error, and W-001..W-013 wedge-class events.
          </div>
        </ol>
        <div class="ww-pill" id="ww-pill" style="display:none">
          ↓ <span id="ww-pill-n">0</span> new
        </div>
      </div>
    `;

    // Scroll handler for pin/unpin
    const list = this.#shadow.querySelector('.ww-list');
    list?.addEventListener('scroll', () => this.#onScroll());

    // Pill click jumps to bottom
    const pill = this.#shadow.getElementById('ww-pill');
    pill?.addEventListener('click', () => this.#jumpToBottom());
  }

  #appendRow(payload) {
    const list = this.#shadow.querySelector('.ww-list');
    if (!list) return;

    const li = document.createElement('li');
    li.className = 'ww-row';
    li.dataset.payload = JSON.stringify(payload);

    const ts = String(payload.ts || '').slice(11, 19) || '--:--:--';
    const rawKind = String(payload.kind || payload.event || 'unknown');
    const severity = KIND_SEVERITY[rawKind] || 'info';
    const kindLabel = KIND_LABELS[rawKind] || rawKind;
    const summary = this.#summarize(payload);
    const wedgeClass = payload.wedge_class || '';
    const taxEntry = WEDGE_TAXONOMY[wedgeClass];
    const classTag = wedgeClass
      ? `${wedgeClass}${taxEntry ? `: ${taxEntry.label}` : ''}`
      : '';
    const minutes = payload.minutes_lost ? `${payload.minutes_lost}m lost` : '';

    li.innerHTML = `
      <span class="ww-ts">${this.#esc(ts)}</span>
      <span class="ww-badge ${severity}">${this.#esc(kindLabel)}</span>
      <div class="ww-body">
        <div class="ww-summary-text">${this.#esc(summary)}</div>
        ${classTag ? `<div class="ww-class-tag">${this.#esc(classTag)}</div>` : ''}
      </div>
      ${minutes ? `<span class="ww-minutes">${this.#esc(minutes)}</span>` : '<span></span>'}
      <pre class="ww-detail" hidden></pre>
    `;

    // Click to expand JSON detail
    li.addEventListener('click', () => {
      const detail = li.querySelector('.ww-detail');
      if (!detail) return;
      if (detail.hidden) {
        detail.textContent = JSON.stringify(payload, null, 2);
        detail.hidden = false;
      } else {
        detail.hidden = true;
      }
    });

    list.appendChild(li);
  }

  #refreshSummary() {
    const slot = this.#shadow.getElementById('ww-top-content');
    if (!slot) return;

    // Rank by count × minutes_lost (falls back to count if no minutes_lost)
    const entries = Object.entries(this.#agg)
      .map(([cls, stats]) => ({
        cls,
        count: stats.count,
        minutes_lost: stats.minutes_lost,
        score: stats.count * (stats.minutes_lost || 1),
      }))
      .sort((a, b) => b.score - a.score)
      .slice(0, 3);

    if (entries.length === 0) {
      slot.innerHTML = '<div class="ww-summary-empty">No wedge events in window</div>';
      return;
    }

    const rows = entries.map((e, i) => {
      const taxEntry = WEDGE_TAXONOMY[e.cls];
      const icon = taxEntry?.icon || '⚠️';
      const desc = taxEntry?.label || KIND_LABELS[e.cls] || e.cls;
      const statsText = e.minutes_lost > 0
        ? `${e.count}× · ${e.minutes_lost}m`
        : `${e.count}×`;
      return `
        <div class="ww-top-row">
          <span class="ww-top-rank">${i + 1}.</span>
          <span class="ww-top-class">${this.#esc(icon)} ${this.#esc(e.cls)}</span>
          <span class="ww-top-desc">${this.#esc(desc)}</span>
          <span class="ww-top-stats">${this.#esc(statsText)}</span>
        </div>`;
    }).join('');

    slot.innerHTML = `<div class="ww-top">${rows}</div>`;
  }

  // ── Connection state ────────────────────────────────────────────────────────

  #setConn(state) {
    this.#connState = state;
    const el = this.#shadow.getElementById('ww-conn');
    if (!el) return;
    el.className = `ww-summary-conn ${state}`;
    const labels = {
      live:         '● live',
      reconnecting: '◌ reconnecting',
      error:        '✕ error',
      connecting:   '○ connecting',
    };
    el.textContent = labels[state] || state;
  }

  // ── Scroll behaviour ────────────────────────────────────────────────────────

  #onScroll() {
    const list = this.#shadow.querySelector('.ww-list');
    if (!list) return;
    const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 8;
    if (atBottom && !this.#pinnedToBottom) {
      this.#pinnedToBottom = true;
      this.#pendingNew = 0;
      this.#refreshPill();
    } else if (!atBottom) {
      this.#pinnedToBottom = false;
    }
  }

  #jumpToBottom() {
    const list = this.#shadow.querySelector('.ww-list');
    if (list) list.scrollTop = list.scrollHeight;
    this.#pinnedToBottom = true;
    this.#pendingNew = 0;
    this.#refreshPill();
  }

  #refreshPill() {
    const pill = this.#shadow.getElementById('ww-pill');
    const pillN = this.#shadow.getElementById('ww-pill-n');
    if (!pill || !pillN) return;
    if (this.#pendingNew > 0) {
      pill.style.display = '';
      pillN.textContent = String(this.#pendingNew);
    } else {
      pill.style.display = 'none';
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  // Extract a one-line summary from a payload.
  #summarize(p) {
    // ALERT wrappers put useful text in note
    if (p.note) return String(p.note).slice(0, 100);
    // pr_stuck typically has pr_title or title
    if (p.pr_title) return `#${p.pr_number || '?'} — ${String(p.pr_title).slice(0, 80)}`;
    if (p.title) return String(p.title).slice(0, 100);
    if (p.subject) return String(p.subject).slice(0, 100);
    // wedge_class_detected has a class + pr_number
    if (p.pr_number) return `PR #${p.pr_number}${p.failing_checks ? ` · ${String(p.failing_checks).slice(0, 60)}` : ''}`;
    // silent_agent / lease_overlap have session
    if (p.session) return `session=${String(p.session).slice(0, 60)}`;
    // Fix shape if available
    if (p.fix_shape) return String(p.fix_shape).slice(0, 100);
    // Fallback
    const k = String(p.kind || p.event || '');
    return k || '(no summary)';
  }

  #esc(s) {
    return String(s || '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }
}

customElements.define('chump-wedge-watch', ChumpWedgeWatch);
