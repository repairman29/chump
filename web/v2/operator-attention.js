// operator-attention.js — PRODUCT-117
//
// Operator-attention queue: surfaces ambient events that need human eyes
// (orphan PRs, roadmap-update proposal PRs, dedup-bypass attempts, etc.)
// in a single grouped list. Each row has a primary action link (open the
// PR/gap in a new tab) + Defer (hide 4 h) + Dismiss (hide permanently).
//
// Read-only against /api/approve (which is for tool-call approval, not
// operator queues). Action surface is OPEN-detail-link + local hide.
// Future: per-kind actions wired to specific endpoints (close orphan PR,
// run gap-doctor, etc.) as those endpoints become available.

const TRACKED_KINDS = [
  // INFRA-994 / INFRA-1139 — sweepers flagged candidates
  { kind: 'orphan_pr_candidate',          icon: '🪦', label: 'Orphan PR (gap done, PR open)' },
  // INFRA-1147 — weekly roadmap-update LLM-proposed PR
  { kind: 'roadmap_update_proposal_opened', icon: '🗺️', label: 'Roadmap-update PR for review' },
  // INFRA-1152 — pillar over-weighting blocked a reserve
  { kind: 'pillar_balance_block',         icon: '⚖️', label: 'Pillar balance: reserve blocked' },
  // INFRA-1219 — dedup gate refused a bypass without justification
  { kind: 'pr_dedup_bypass_rejected',     icon: '🚫', label: 'Duplicate-PR bypass rejected' },
  // INFRA-781 — PR closed unmerged with no equivalent ship
  { kind: 'pr_bounced_unfinished',        icon: '⚰️', label: 'Bounced PR — work may be lost' },
  // ambient watchdog
  { kind: 'gap_drift_orphan',             icon: '🧭', label: 'Gap drift detected' },
  // INFRA-1186 — gh shim worktree-clobber attempt
  { kind: 'gh_shim_worktree_install_blocked', icon: '🔧', label: 'gh shim install blocked' },
  // INFRA-779 — gitdir back-ref repair fired
  { kind: 'worktree_gitdir_repair_fired', icon: '🩹', label: 'Worktree gitdir repaired' },
];

const DEFER_TTL_S = 4 * 60 * 60; // 4 hours
const STATE_KEY = 'operatorAttentionState';

class ChumpOperatorAttention extends HTMLElement {
  constructor() {
    super();
    this._items = [];
    this._refreshTimer = null;
    this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.render();
    this.refresh();
    this._refreshTimer = setInterval(() => this.refresh(), 30_000);
  }

  disconnectedCallback() {
    if (this._refreshTimer) clearInterval(this._refreshTimer);
  }

  // localStorage state shape: { defers: {fingerprint: deferUntilEpoch}, dismissals: {fingerprint: true} }
  _readState() {
    try {
      const raw = window.chumpPrefs && window.chumpPrefs.get
        ? window.chumpPrefs.get(STATE_KEY)
        : null;
      if (!raw) return { defers: {}, dismissals: {} };
      const s = typeof raw === 'string' ? JSON.parse(raw) : raw;
      return { defers: s.defers || {}, dismissals: s.dismissals || {} };
    } catch (_e) {
      return { defers: {}, dismissals: {} };
    }
  }

  _writeState(state) {
    try {
      if (window.chumpPrefs && window.chumpPrefs.set) {
        window.chumpPrefs.set(STATE_KEY, JSON.stringify(state));
      } else {
        localStorage.setItem('chump.' + STATE_KEY, JSON.stringify(state));
      }
    } catch (_e) {}
  }

  // Stable fingerprint for an event so Defer/Dismiss survives a re-read.
  // (Same kind + same PR/gap/branch → same fingerprint.)
  _fingerprint(evt) {
    const key = evt.kind + '|' + (evt.pr || evt.gap || evt.branch || evt.id || evt.ts || '?');
    return key;
  }

  _authHeaders() {
    try {
      const t = window.chumpPrefs && window.chumpPrefs.get
        ? window.chumpPrefs.get('webToken')
        : null;
      if (t) return { 'X-Chump-Auth': t };
    } catch (_e) {}
    return {};
  }

  async refresh() {
    const out = [];
    // Fetch per kind. Each kind is cheap; total is O(8) HTTP calls every
    // 30s. Could be one combined endpoint if traffic warrants, but per-kind
    // is server-cache-friendly today.
    const fetches = TRACKED_KINDS.map(async ({ kind, icon, label }) => {
      try {
        const r = await fetch(`/api/ambient/recent?kind=${encodeURIComponent(kind)}&n=20`, {
          headers: this._authHeaders(),
          credentials: 'same-origin',
        });
        if (!r.ok) return [];
        const body = await r.json();
        const events = Array.isArray(body) ? body : (body.events || []);
        return events.map((e) => ({ ...e, _icon: icon, _label: label, _kind: kind }));
      } catch (_e) {
        return [];
      }
    });
    const results = await Promise.all(fetches);
    results.forEach((arr) => out.push(...arr));

    // Drop deferred / dismissed.
    const state = this._readState();
    const now = Math.floor(Date.now() / 1000);
    const filtered = out.filter((e) => {
      const fp = this._fingerprint(e);
      if (state.dismissals[fp]) return false;
      const deferUntil = state.defers[fp];
      if (deferUntil && deferUntil > now) return false;
      return true;
    });

    // Sort newest first.
    filtered.sort((a, b) => (b.ts || '').localeCompare(a.ts || ''));

    this._items = filtered;
    this.render();
  }

  _defer(fp) {
    const state = this._readState();
    state.defers[fp] = Math.floor(Date.now() / 1000) + DEFER_TTL_S;
    this._writeState(state);
    this.refresh();
  }

  _dismiss(fp) {
    const state = this._readState();
    state.dismissals[fp] = true;
    this._writeState(state);
    this.refresh();
  }

  // Primary "detail" link per event kind.
  _detailHref(evt) {
    if (evt.pr) return `https://github.com/repairman29/chump/pull/${evt.pr}`;
    if (evt.url) return evt.url;
    if (evt.gap) return `#/library/gap/${evt.gap}`;
    return null;
  }

  render() {
    const items = this._items || [];
    const grouped = {};
    items.forEach((e) => {
      grouped[e._kind] = grouped[e._kind] || [];
      grouped[e._kind].push(e);
    });

    const sectionsHtml = TRACKED_KINDS
      .filter(({ kind }) => grouped[kind] && grouped[kind].length > 0)
      .map(({ kind, icon, label }) => {
        const rows = grouped[kind].slice(0, 5).map((evt) => {
          const fp = this._fingerprint(evt);
          const href = this._detailHref(evt);
          const target = evt.pr ? `PR #${evt.pr}` : (evt.gap ? evt.gap : (evt.branch || ''));
          const note = evt.note || evt.message || '';
          const ts = (evt.ts || '').replace('T', ' ').replace('Z', '');
          return `
            <li class="row" data-fp="${fp}">
              <div class="row-main">
                <div class="row-target">
                  ${href ? `<a href="${href}" target="_blank" rel="noopener">${target}</a>` : `<span>${target}</span>`}
                  <span class="row-ts">${ts}</span>
                </div>
                ${note ? `<div class="row-note">${this._esc(note).slice(0, 200)}</div>` : ''}
              </div>
              <div class="row-actions">
                <button class="defer" data-fp="${fp}" title="Hide for 4 hours">Defer</button>
                <button class="dismiss" data-fp="${fp}" title="Hide permanently">Dismiss</button>
              </div>
            </li>
          `;
        }).join('');
        const more = grouped[kind].length > 5 ? `<li class="more">+ ${grouped[kind].length - 5} more</li>` : '';
        return `
          <section class="kind-group">
            <h3>${icon} ${label} <span class="count">${grouped[kind].length}</span></h3>
            <ul class="rows">${rows}${more}</ul>
          </section>
        `;
      }).join('');

    const empty = items.length === 0
      ? `<div class="empty">
           <div class="empty-icon">☕</div>
           <div class="empty-msg">Nothing to approve — go drink coffee</div>
         </div>`
      : '';

    this.shadowRoot.innerHTML = `
      <style>
        :host {
          display: block;
          font: 13px -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          color: #f0f0f0;
        }
        h2 { font-size: 14px; margin: 0 0 12px; opacity: 0.7; text-transform: uppercase; letter-spacing: 1px; }
        .kind-group { margin: 0 0 16px; }
        .kind-group h3 {
          font-size: 13px; font-weight: 600; margin: 0 0 6px;
          padding-bottom: 4px; border-bottom: 1px solid rgba(255,255,255,0.08);
          display: flex; align-items: center; gap: 6px;
        }
        .count {
          font-size: 11px; padding: 1px 6px; border-radius: 10px;
          background: rgba(255,255,255,0.1); margin-left: 4px;
        }
        ul.rows { list-style: none; margin: 0; padding: 0; }
        .row {
          display: flex; align-items: center; justify-content: space-between;
          padding: 8px 6px; gap: 8px;
          border-bottom: 1px solid rgba(255,255,255,0.04);
        }
        .row:last-child { border-bottom: 0; }
        .row-main { flex: 1; min-width: 0; }
        .row-target a { color: #0a84ff; text-decoration: none; font-weight: 600; }
        .row-target a:hover { text-decoration: underline; }
        .row-ts { font-size: 11px; opacity: 0.5; margin-left: 8px; }
        .row-note { font-size: 12px; opacity: 0.7; margin-top: 2px; word-break: break-word; }
        .row-actions { display: flex; gap: 4px; flex-shrink: 0; }
        .row-actions button {
          font: 11px inherit; padding: 3px 8px; border-radius: 4px; cursor: pointer;
          border: 1px solid rgba(255,255,255,0.15);
          background: rgba(255,255,255,0.04); color: #f0f0f0;
        }
        .row-actions button:hover { background: rgba(255,255,255,0.08); }
        .row-actions .dismiss { color: #ff453a; border-color: rgba(255,69,58,0.3); }
        .more { padding: 4px 6px; font-size: 11px; opacity: 0.5; }
        .empty {
          padding: 32px 12px; text-align: center; opacity: 0.6;
        }
        .empty-icon { font-size: 32px; margin-bottom: 8px; }
        .empty-msg { font-size: 13px; }
      </style>
      <h2>Operator Attention</h2>
      ${empty}${sectionsHtml}
    `;

    this.shadowRoot.querySelectorAll('button.defer').forEach((b) => {
      b.addEventListener('click', () => this._defer(b.dataset.fp));
    });
    this.shadowRoot.querySelectorAll('button.dismiss').forEach((b) => {
      b.addEventListener('click', () => this._dismiss(b.dataset.fp));
    });
  }

  _esc(s) {
    return String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
  }
}

customElements.define('chump-operator-attention', ChumpOperatorAttention);
