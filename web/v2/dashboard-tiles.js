// web/v2/dashboard-tiles.js — INFRA-2215 (token-aligned in PRODUCT-372)
//
// <chump-dashboard-tiles> — 3-tile PWA cockpit summary consuming GET /api/dashboard-summary.

const CSS = `
  :host { display: block; }
  .tiles {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 12px;
  }
  @media (max-width: 900px) {
    .tiles { grid-template-columns: 1fr; }
  }
  .tile {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 14px 16px;
    min-height: 98px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    box-shadow: var(--shadow-card);
  }
  .tile-label {
    font-family: var(--font-mono);
    font-size: 10.5px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-secondary);
  }
  .tile-value {
    font-family: var(--font-display);
    font-size: 28px;
    font-weight: 700;
    color: var(--text);
    font-variant-numeric: tabular-nums;
    line-height: 1.1;
  }
  .tile-value.tone-green { color: var(--success); }
  .tile-value.tone-amber { color: var(--warn); }
  .tile-value.tone-red   { color: var(--error); }
  .tile-value.tone-gray  { color: var(--text-secondary); }
  .tile-meta {
    font-size: 11.5px;
    color: var(--text-secondary);
  }
  .skeleton-bar {
    height: 28px;
    width: 65%;
    border-radius: 4px;
    background: var(--bg-elevated);
  }
  .tile-error {
    display: flex;
    flex-direction: column;
    gap: 8px;
    align-items: flex-start;
  }
  .tile-error-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 11px;
    color: var(--error);
    background: var(--tone-err-bg);
    border: 1px solid var(--tone-err-border);
    border-radius: 999px;
    padding: 3px 10px;
  }
  .tile-retry {
    background: var(--bg-elevated);
    border: 1px solid var(--border);
    color: var(--text);
    border-radius: var(--radius-sm);
    padding: 4px 10px;
    font-size: 11px;
    cursor: pointer;
  }
  .tile-retry:hover {
    background: var(--accent);
    color: var(--on-accent);
    border-color: var(--accent);
  }
  .lease-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
    overflow: auto;
    max-height: 160px;
  }
  .lease-row {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 8px;
    font-size: 12px;
  }
  .lease-gap {
    background: none;
    border: none;
    padding: 0;
    color: var(--accent);
    cursor: pointer;
    font-family: var(--font-mono);
    font-size: 11.5px;
    font-weight: 600;
    text-decoration: none;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .lease-gap:hover { text-decoration: underline; }
  .lease-countdown {
    flex: 0 0 auto;
    font-family: var(--font-mono);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
    color: var(--text-secondary);
    white-space: nowrap;
  }
  .lease-countdown.expired { color: var(--error); }
  .lease-empty {
    font-size: 12px;
    color: var(--text-secondary);
  }
`;

class ChumpDashboardTiles extends HTMLElement {
  #shadow;
  #timer;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#renderSkeleton();
    this.#load();
    this.#timer = setInterval(() => this.#load(), 60_000);
  }

  disconnectedCallback() {
    clearInterval(this.#timer);
  }

  async #load() {
    try {
      const r = await fetch('/api/dashboard-summary');
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const data = await r.json();
      this.#renderData(data);
    } catch {
      this.#renderError();
    }
  }

  #renderSkeleton() {
    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="tiles" aria-label="Dashboard summary" aria-busy="true">
        ${['Ships today', 'CI/QA score', 'Active leases'].map((label) => `
          <div class="tile">
            <div class="tile-label">${label}</div>
            <div class="skeleton-bar"></div>
          </div>
        `).join('')}
      </div>
    `;
  }

  #renderError() {
    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="tiles" aria-label="Dashboard summary">
        <div class="tile">
          <div class="tile-label">Dashboard</div>
          <div class="tile-error">
            <span class="tile-error-pill">Summary temporarily unavailable</span>
            <button type="button" class="tile-retry" id="retry-btn">Retry</button>
          </div>
        </div>
      </div>
    `;
    this.#shadow.getElementById('retry-btn')?.addEventListener('click', () => {
      this.#renderSkeleton();
      this.#load();
    });
  }

  #renderData(data) {
    const shipsToday = Number.isFinite(data.today_ships) ? data.today_ships : 0;
    const ci = data.ci_qa_score || null;
    const leases = Array.isArray(data.active_leases) ? data.active_leases.slice() : [];

    leases.sort((a, b) => {
      const ta = Date.parse(a.expires_at || '');
      const tb = Date.parse(b.expires_at || '');
      if (Number.isNaN(ta) && Number.isNaN(tb)) return 0;
      if (Number.isNaN(ta)) return 1;
      if (Number.isNaN(tb)) return -1;
      return ta - tb;
    });
    const top10 = leases.slice(0, 10);

    const wedgedPrs = Number.isFinite(data.landing_wedged_prs)
      ? data.landing_wedged_prs
      : (Number.isFinite(data.stuck_prs) ? data.stuck_prs : (ci?.stuck_prs ?? 0));
    const ciTone = ChumpDashboardTiles.#ciTone(ci, wedgedPrs);
    const ciLabel = ci ? `${ci.pct.toFixed(0)}%` : '—';
    const wedgedSuffix = wedgedPrs > 0 ? ` · ${wedgedPrs} wedged` : '';
    const ciMeta = ci
      ? `${ci.sample_size} run${ci.sample_size === 1 ? '' : 's'} · ${ci.status}${wedgedSuffix}`
      : 'awaiting CI telemetry';

    const leaseRows = top10.length
      ? top10.map((l) => `
          <li class="lease-row">
            <button type="button" class="lease-gap" data-gap="${ChumpDashboardTiles.#esc(l.gap)}">${ChumpDashboardTiles.#esc(l.gap)}</button>
            <span class="lease-countdown" data-expires="${ChumpDashboardTiles.#esc(l.expires_at)}"></span>
          </li>
        `).join('')
      : `<li class="lease-empty">No active leases</li>`;

    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="tiles" aria-label="Dashboard summary">
        <div class="tile" aria-label="Ships today">
          <div class="tile-label">Ships today</div>
          <div class="tile-value">${shipsToday}</div>
          <div class="tile-meta">last ${data.window_hours ?? 24}h window</div>
        </div>

        <div class="tile" aria-label="CI/QA score">
          <div class="tile-label">CI/QA score</div>
          <div class="tile-value tone-${ciTone}">${ciLabel}</div>
          <div class="tile-meta">${ciMeta}</div>
        </div>

        <div class="tile" aria-label="Active leases">
          <div class="tile-label">Active leases</div>
          <ul class="lease-list">${leaseRows}</ul>
        </div>
      </div>
    `;

    this.#shadow.querySelectorAll('.lease-gap').forEach((btn) => {
      btn.addEventListener('click', () => {
        const gap = btn.dataset.gap;
        if (!gap) return;
        document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'agent' }));
      });
    });

    this.#shadow.querySelectorAll('.lease-countdown').forEach((el) => {
      ChumpDashboardTiles.#renderCountdown(el);
    });
  }

  static #ciTone(ci, wedgedPrs = 0) {
    if (!ci || typeof ci.pct !== 'number') return 'gray';
    const st = String(ci.status ?? '').toLowerCase();
    if (st === 'red' || wedgedPrs >= 5 || ci.pct < 50) return 'red';
    if (st === 'amber' || wedgedPrs > 0 || ci.pct < 80) return 'amber';
    if (st === 'unknown') return 'gray';
    return 'green';
  }

  static #renderCountdown(el) {
    const expiresAt = el.dataset.expires;
    const t = Date.parse(expiresAt || '');
    if (Number.isNaN(t)) {
      el.textContent = '—';
      return;
    }
    const deltaMs = t - Date.now();
    if (deltaMs <= 0) {
      el.textContent = 'expired';
      el.classList.add('expired');
      return;
    }
    const mins = Math.round(deltaMs / 60_000);
    el.textContent = mins < 60
      ? `${mins}m`
      : `${Math.round(mins / 60)}h ${mins % 60}m`;
  }

  static #esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }
}
customElements.define('chump-dashboard-tiles', ChumpDashboardTiles);
