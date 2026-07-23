// web/cockpit/operator-page-panel.js — INFRA-1774
//
// <chump-operator-page-panel> web component.
//
// Polls /api/operator-page/pending every 10s and renders pending structured
// human-in-the-loop interrupts (scripts/dispatch/operator-page.sh), tiered
// info | action | block. Clicking "Ack" POSTs /api/operator-page/ack.
//
// Response shape from /api/operator-page/pending:
//   {
//     pages: [
//       { corr_id, severity, title, message, gap_id, cost_usd_at_page,
//         timeout_secs, ts },
//       ...
//     ],
//     updated_at: "2026-07-23T05:00:00Z"
//   }

const POLL_INTERVAL_MS = 10_000;

class ChumpOperatorPagePanel extends HTMLElement {
  connectedCallback() {
    this._render({ loading: true });
    this._poll();
    this._timer = setInterval(() => this._poll(), POLL_INTERVAL_MS);
  }

  disconnectedCallback() {
    clearInterval(this._timer);
  }

  async _poll() {
    try {
      const r = await fetch('/api/operator-page/pending');
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const data = await r.json();
      this._render({ data });
    } catch (e) {
      this._render({ error: String(e) });
    }
  }

  async _ack(corrId) {
    try {
      await fetch('/api/operator-page/ack', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ corr_id: corrId, ack_by: 'pwa-cockpit' }),
      });
    } finally {
      this._poll();
    }
  }

  _severityStyle(sev) {
    if (sev === 'block') return { color: 'var(--error)', label: 'BLOCK' };
    if (sev === 'action') return { color: 'var(--warn)', label: 'ACTION' };
    return { color: 'var(--success)', label: 'INFO' };
  }

  _render({ loading, error, data }) {
    const base = `
      font-family: var(--font, monospace);
      font-size: 12px;
      color: var(--text);
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 10px 14px;
    `;

    if (loading) {
      this.innerHTML = `<div style="${base}"><span style="opacity:.5">loading operator pages…</span></div>`;
      return;
    }
    if (error) {
      this.innerHTML = `<div style="${base}"><span style="color:var(--error)">operator-page unavailable: ${error}</span></div>`;
      return;
    }

    const pages = data.pages || [];
    if (pages.length === 0) {
      this.innerHTML = `
        <div style="${base}">
          <div style="font-weight:600;margin-bottom:4px">Operator Pages</div>
          <div style="opacity:.5">no pending interrupts</div>
        </div>`;
      return;
    }

    const rows = pages.map((p) => {
      const s = this._severityStyle(p.severity);
      const gap = p.gap_id ? `<span style="opacity:.5">[${p.gap_id}]</span> ` : '';
      const cost = p.cost_usd_at_page && p.cost_usd_at_page !== 'unknown'
        ? `<span style="opacity:.5">$${p.cost_usd_at_page} at page</span>`
        : '';
      return `
        <div style="padding:6px 0;border-top:1px solid var(--border)">
          <div>
            <span style="color:${s.color};font-weight:700">${s.label}</span>
            ${gap}<strong>${p.title || ''}</strong>
          </div>
          <div style="opacity:.7;margin:2px 0">${p.message || ''}</div>
          <div style="display:flex;justify-content:space-between;align-items:center">
            ${cost}
            <button data-corr="${p.corr_id}" style="
              background:${s.color};color:var(--bg);border:none;border-radius:var(--radius-sm);
              padding:2px 8px;font-size:11px;cursor:pointer;">Ack</button>
          </div>
        </div>`;
    }).join('');

    this.innerHTML = `
      <div style="${base}">
        <div style="font-weight:600;margin-bottom:4px">Operator Pages (${pages.length})</div>
        ${rows}
        <div style="opacity:.4;margin-top:6px;font-size:10px">updated ${data.updated_at || '—'}</div>
      </div>`;

    this.querySelectorAll('button[data-corr]').forEach((btn) => {
      btn.addEventListener('click', () => this._ack(btn.dataset.corr));
    });
  }
}

customElements.define('chump-operator-page-panel', ChumpOperatorPagePanel);
