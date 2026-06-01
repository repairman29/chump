// web/cockpit/fleet-wire-panel.js — META-175
//
// <chump-fleet-wire-health> web component.
//
// Polls /api/fleet-wire/health every 15s and renders per-role consumer lag
// (deliveredSeq - ackSeq) and delivery latency p50/p99 from
// kind=feedback_fanout_delivered ambient events.
//
// Response shape from /api/fleet-wire/health:
//   {
//     roles: [
//       { role: "ci-audit", lag: 0, p50_ms: 42, p99_ms: 120 },
//       ...
//     ],
//     updated_at: "2026-05-30T09:00:00Z",
//     nats_enabled: true
//   }
//
// When nats_enabled=false (feature flag not set), renders a "file-inbox mode"
// notice instead of role rows.

const POLL_INTERVAL_MS = 15_000;
const LAG_WARN = 10;   // amber
const LAG_CRIT = 50;   // red

class ChumpFleetWireHealth extends HTMLElement {
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
      const r = await fetch('/api/fleet-wire/health');
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const data = await r.json();
      this._render({ data });
    } catch (e) {
      this._render({ error: String(e) });
    }
  }

  _lagColor(lag) {
    if (lag >= LAG_CRIT) return '#ef4444';
    if (lag >= LAG_WARN) return '#f59e0b';
    return '#22c55e';
  }

  _latencyBar(ms) {
    if (ms == null || ms < 0) return '<span style="opacity:.4">n/a</span>';
    const col = ms > 500 ? '#ef4444' : ms > 100 ? '#f59e0b' : '#22c55e';
    return `<span style="color:${col}">${ms}ms</span>`;
  }

  _render({ loading, error, data }) {
    const base = `
      font-family: var(--font, monospace);
      font-size: 12px;
      color: var(--text, #e5e5ea);
      background: var(--bg-secondary, #1a1a1c);
      border: 1px solid var(--border, #2a2a2e);
      border-radius: 8px;
      padding: 10px 14px;
    `;

    if (loading) {
      this.innerHTML = `<div style="${base}"><span style="opacity:.5">loading fleet-wire health…</span></div>`;
      return;
    }
    if (error) {
      this.innerHTML = `<div style="${base}"><span style="color:#ef4444">fleet-wire unavailable: ${error}</span></div>`;
      return;
    }
    if (!data.nats_enabled) {
      this.innerHTML = `
        <div style="${base}">
          <div style="font-weight:600;margin-bottom:6px">Fleet Wire — file-inbox mode</div>
          <div style="opacity:.6">JetStream consumer inactive.<br>
          Set <code>CHUMP_FLEET_WIRE_V1=1</code> + <code>CHUMP_NATS_URL</code> to enable.</div>
          <div style="opacity:.4;margin-top:4px;font-size:10px">updated ${data.updated_at || '—'}</div>
        </div>`;
      return;
    }

    const rows = (data.roles || []).map(r => {
      const lagCol = this._lagColor(r.lag);
      return `
        <tr>
          <td style="padding:3px 10px 3px 0;font-weight:600">${r.role}</td>
          <td style="padding:3px 10px 3px 0;color:${lagCol}">${r.lag} msg</td>
          <td style="padding:3px 10px 3px 0">${this._latencyBar(r.p50_ms)} p50</td>
          <td style="padding:3px 0">${this._latencyBar(r.p99_ms)} p99</td>
        </tr>`;
    }).join('');

    const noRoles = (data.roles || []).length === 0
      ? '<tr><td colspan="4" style="opacity:.5;padding-top:4px">no active consumers</td></tr>'
      : '';

    this.innerHTML = `
      <div style="${base}">
        <div style="font-weight:600;margin-bottom:8px">Fleet Wire — JetStream consumers</div>
        <table style="border-collapse:collapse;width:100%">
          <thead>
            <tr style="opacity:.5;font-size:10px;text-transform:uppercase;letter-spacing:.04em">
              <th style="text-align:left;padding-bottom:4px">role</th>
              <th style="text-align:left;padding-bottom:4px">lag</th>
              <th style="text-align:left;padding-bottom:4px">p50</th>
              <th style="text-align:left;padding-bottom:4px">p99</th>
            </tr>
          </thead>
          <tbody>${rows}${noRoles}</tbody>
        </table>
        <div style="opacity:.4;margin-top:6px;font-size:10px">updated ${data.updated_at || '—'}</div>
      </div>`;
  }
}

customElements.define('chump-fleet-wire-health', ChumpFleetWireHealth);
