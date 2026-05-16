// impact.js — PRODUCT-081
// PWA Outcome Dashboard: 'your impact today' surface.
// Web component <chump-view-impact> — Shadow DOM, no framework.

const EFFORT_LABELS = { xs: '½h', s: '1h', m: '4h', l: '12h', xl: '40h' };
const PILLAR_COLORS = {
  EFFECTIVE: '#4a90d9',
  CREDIBLE:  '#27ae60',
  RESILIENT: '#e67e22',
  'ZERO-WASTE': '#8e44ad',
  MISSION:   '#c0392b',
  unknown:   '#bdc3c7',
};
const WINDOWS = [
  { id: 'today', label: 'Today'     },
  { id: 'week',  label: 'This week' },
  { id: 'all',   label: 'All time'  },
];

class ChumpViewImpact extends HTMLElement {
  constructor() {
    super();
    this._shadow  = this.attachShadow({ mode: 'open' });
    this._window  = 'today';
    this._data    = null;
    this._loading = false;
  }

  connectedCallback() {
    this._renderShell();
    this._load();
  }

  _renderShell() {
    this._shadow.innerHTML = `
      <style>
        :host { display: block; font-family: system-ui, sans-serif; padding: .5rem; }
        h2 { font-size: 1.1rem; margin: 0 0 .75rem; color: #334; }
        .window-tabs { display: flex; gap: .5rem; margin-bottom: 1rem; }
        .window-tab { padding: .3rem .75rem; border: 1px solid #ccc; border-radius: 4px;
                      cursor: pointer; font-size: .85rem; background: #f8f8f8; }
        .window-tab.active { background: #357; color: #fff; border-color: #357; }
        .metrics { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
                   gap: .75rem; margin-bottom: 1.25rem; }
        .metric { background: #f5f7fa; border-radius: 6px; padding: .6rem .85rem;
                  border-left: 3px solid #357; }
        .metric .val { font-size: 1.5rem; font-weight: 700; color: #334; }
        .metric .lbl { font-size: .75rem; color: #667; margin-top: .1rem; }
        .section { margin-bottom: 1.25rem; }
        .section h3 { font-size: .95rem; margin: 0 0 .5rem; color: #445; }
        .pillar-bar { display: flex; height: 18px; border-radius: 4px; overflow: hidden;
                      margin-bottom: .4rem; }
        .pillar-seg { height: 100%; transition: width .3s; }
        .pillar-legend { display: flex; flex-wrap: wrap; gap: .4rem .8rem; font-size: .78rem; }
        .pillar-dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block;
                      margin-right: 3px; vertical-align: middle; }
        .starved { color: #c00; font-size: .8rem; margin-top: .3rem; }
        .pr-list { list-style: none; padding: 0; margin: 0; }
        .pr-item { display: flex; align-items: baseline; gap: .5rem; padding: .3rem 0;
                   border-bottom: 1px solid #eee; font-size: .875rem; }
        .pr-item:last-child { border-bottom: none; }
        .pr-effort { font-size: .75rem; color: #888; flex-shrink: 0; }
        .pr-title { flex: 1; color: #334; }
        .pr-link { color: #357; font-size: .75rem; text-decoration: none; }
        .pr-link:hover { text-decoration: underline; }
        .loading { color: #888; font-size: .9rem; }
        .error   { color: #c00; font-size: .9rem; }
        .empty   { color: #aaa; font-style: italic; font-size: .85rem; }
        .meta    { font-size: .75rem; color: #aaa; margin-top: 1rem; }
      </style>
      <h2>📊 Outcome Dashboard</h2>
      <div class="window-tabs" id="window-tabs">
        ${WINDOWS.map(w => `<button class="window-tab${w.id === this._window ? ' active' : ''}" data-w="${w.id}">${w.label}</button>`).join('')}
      </div>
      <div id="body"><p class="loading">Loading…</p></div>`;

    this._shadow.querySelectorAll('.window-tab').forEach(btn => {
      btn.addEventListener('click', () => {
        this._window = btn.dataset.w;
        this._shadow.querySelectorAll('.window-tab').forEach(b => b.classList.toggle('active', b.dataset.w === this._window));
        this._load();
      });
    });
  }

  async _load() {
    if (this._loading) return;
    this._loading = true;
    const body = this._shadow.getElementById('body');
    if (body) body.innerHTML = '<p class="loading">Loading…</p>';
    try {
      const res = await fetch(`/api/impact?window=${this._window}`, {
        headers: { Authorization: `Bearer ${window.CHUMP_TOKEN || ''}` },
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      this._data = await res.json();
      this._renderData();
    } catch (e) {
      if (body) body.innerHTML = `<p class="error">Failed: ${e.message}</p>`;
    } finally {
      this._loading = false;
    }
  }

  _renderData() {
    const d    = this._data;
    const body = this._shadow.getElementById('body');
    if (!d || !body) return;

    const m = d.metrics || {};
    const mix = d.pillar_mix_pct || {};
    const pillars = Object.keys(PILLAR_COLORS).filter(p => p !== 'unknown');

    // ── Metrics ──────────────────────────────────────────────────────────────
    const metrics = [
      { val: m.prs_merged    ?? 0,  lbl: 'PRs merged'           },
      { val: m.gaps_closed   ?? 0,  lbl: 'Gaps closed'          },
      { val: (m.fleet_activity_hours ?? 0).toFixed(1) + 'h', lbl: 'Fleet activity' },
      { val: (m.operator_hours_saved ?? 0).toFixed(1) + 'h', lbl: 'Operator-hours saved' },
    ];

    // ── Pillar bar ────────────────────────────────────────────────────────────
    const barSegs = pillars.map(p => {
      const pct = mix[p] || 0;
      return pct > 0
        ? `<div class="pillar-seg" style="width:${pct}%;background:${PILLAR_COLORS[p]}" title="${p} ${pct.toFixed(0)}%"></div>`
        : '';
    }).join('');

    const legend = pillars.map(p => {
      const cnt = (d.pillar_mix || {})[p] || 0;
      if (!cnt) return '';
      const pct = (mix[p] || 0).toFixed(0);
      return `<span><span class="pillar-dot" style="background:${PILLAR_COLORS[p]}"></span>${p} ${cnt} (${pct}%)</span>`;
    }).filter(Boolean).join('');

    const starved = (d.starved_pillars || []);
    const starvedHtml = starved.length
      ? `<div class="starved">⚠️ Starved: ${starved.join(', ')} (&lt;15% share)</div>`
      : '';

    // ── Top PRs ───────────────────────────────────────────────────────────────
    const topPRs = (d.top_prs || []).slice(0, 5);
    const prHtml = topPRs.length === 0
      ? '<li class="empty">No shipped gaps in this window yet.</li>'
      : topPRs.map(pr => {
          const effortLabel = EFFORT_LABELS[pr.effort] || pr.effort || '?';
          const prUrl = pr.closed_pr ? `https://github.com/repairman29/chump/pull/${pr.closed_pr}` : null;
          const link  = prUrl ? `<a class="pr-link" href="${prUrl}" target="_blank" rel="noopener">#${pr.closed_pr}</a>` : '';
          return `<li class="pr-item">
            <span class="pr-effort">${effortLabel}</span>
            <span class="pr-title">${this._esc(pr.title || pr.gap_id || '?')}</span>
            ${link}
          </li>`;
        }).join('');

    body.innerHTML = `
      <div class="metrics">
        ${metrics.map(m2 => `<div class="metric"><div class="val">${m2.val}</div><div class="lbl">${m2.lbl}</div></div>`).join('')}
      </div>

      <div class="section">
        <h3>Pillar mix</h3>
        <div class="pillar-bar">${barSegs || '<div class="pillar-seg" style="width:100%;background:#eee"></div>'}</div>
        <div class="pillar-legend">${legend || '<span class="empty">No data yet.</span>'}</div>
        ${starvedHtml}
      </div>

      <div class="section">
        <h3>Top ships (by estimated value)</h3>
        <ul class="pr-list">${prHtml}</ul>
      </div>

      <p class="meta">Window: ${d.window} · Generated ${d.generated_at ? new Date(d.generated_at).toLocaleTimeString() : '?'} · Data spans ${d.data_days ?? '?'}d</p>`;
  }

  _esc(str) {
    return String(str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
}

customElements.define('chump-view-impact', ChumpViewImpact);
