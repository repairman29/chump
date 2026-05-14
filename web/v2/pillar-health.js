// PRODUCT-090: 4-pillar health dashboard web component.
// Polls /api/health/pillars every 60s and renders grade tiles.
class ChumpPillarHealth extends HTMLElement {
  connectedCallback() {
    this._render({ loading: true });
    this._poll();
    this._timer = setInterval(() => this._poll(), 60_000);
  }

  disconnectedCallback() {
    clearInterval(this._timer);
  }

  async _poll() {
    try {
      const r = await fetch('/api/health/pillars');
      if (!r.ok) throw new Error(r.status);
      const data = await r.json();
      this._render({ data });
    } catch (e) {
      this._render({ error: true });
    }
  }

  _render({ loading, error, data }) {
    const grade_color = { A: '#22c55e', B: '#84cc16', C: '#f59e0b', F: '#ef4444' };
    if (loading) { this.innerHTML = '<span style="opacity:.5">loading pillars…</span>'; return; }
    if (error)   { this.innerHTML = '<span style="color:#ef4444">pillar data unavailable</span>'; return; }

    const tiles = (data.pillars || []).map(p => {
      const col = grade_color[p.grade] || '#6b7280';
      const breach = p.slo_breach ? ' ⚠' : '';
      return `<div style="display:inline-block;margin:4px;padding:6px 10px;border-radius:6px;
                          background:${col}22;border:1px solid ${col};font-size:12px;line-height:1.4">
        <div style="font-weight:700;color:${col};font-size:16px">${p.grade}${breach}</div>
        <div style="font-weight:600">${p.pillar}</div>
        <div style="opacity:.7">${p.pickable_count} pickable · ${p.p0_count} P0</div>
      </div>`;
    }).join('');

    const fleetCol = grade_color[data.fleet_grade] || '#6b7280';
    this.innerHTML = `
      <div style="font-size:11px;opacity:.6;margin-bottom:4px">
        Fleet <strong style="color:${fleetCol}">${data.fleet_grade}</strong>
        · ${data.fleet_slo_breaches} SLO breach${data.fleet_slo_breaches !== 1 ? 'es' : ''}
      </div>
      <div>${tiles}</div>`;
  }
}
customElements.define('chump-pillar-health', ChumpPillarHealth);
