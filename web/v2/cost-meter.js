// <chump-cost-meter> — INFRA-1012 operator-visible fleet spend.
//
// Polls GET /api/telemetry/cost every 30s and renders four figures:
//   1. session_cost_usd  (Anthropic accumulated this process-lifetime)
//   2. github calls      (count from ambient.jsonl github_api_call events)
//   3. remaining_core    (REST headroom, surfaces rate-limit pressure)
//   4. remaining_graphql (GraphQL headroom — the bucket most likely to hit zero)
//
// Plus the cost_tracker budget_warning banner when CHUMP_DAILY_COST_BUDGET
// is set and we're > 80% of it (warn) or > 100% (red).
//
// Vanilla Web Component, no build, no CDN — matches the rest of web/v2/.
// Air-gap safe by construction.

class ChumpCostMeter extends HTMLElement {
  #timer = null;
  #lastPayload = null;

  connectedCallback() {
    this.#render('loading…');
    this.#poll();
    this.#timer = setInterval(() => this.#poll(), 30_000);
  }

  disconnectedCallback() {
    if (this.#timer) clearInterval(this.#timer);
  }

  #poll() {
    fetch('/api/telemetry/cost')
      .then((r) => {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then((d) => {
        this.#lastPayload = d;
        this.#render(null, d);
      })
      .catch((e) => {
        this.#render('offline (' + String(e).slice(0, 40) + ')');
      });
  }

  #render(label, data) {
    if (label) {
      this.innerHTML = `<div class="cost-meter loading">${label}</div>`;
      return;
    }
    const fmt$ = (v) => '$' + (v ?? 0).toFixed(3);
    const fmtN = (v) => (v == null ? '—' : Number(v).toLocaleString());
    const cost = fmt$(data.session_cost_usd);
    const gh = fmtN(data?.github?.calls);
    const rc = fmtN(data?.github?.remaining_core);
    const rg = fmtN(data?.github?.remaining_graphql);
    const warn = data?.budget?.warning;
    const ceil = data?.budget?.ceiling_usd ?? 0;
    const warnLevel = ceil > 0 && data.session_cost_usd > ceil ? 'red'
                    : warn ? 'warn'
                    : 'ok';

    this.innerHTML = `
      <div class="cost-meter ${warnLevel}">
        <div class="cost-meter-row">
          <span class="cost-meter-label">session</span>
          <span class="cost-meter-value">${cost}</span>
        </div>
        <div class="cost-meter-row">
          <span class="cost-meter-label">gh calls</span>
          <span class="cost-meter-value">${gh}</span>
        </div>
        <div class="cost-meter-row" title="GitHub REST bucket — secondary rate limit (5000/h)">
          <span class="cost-meter-label">REST left</span>
          <span class="cost-meter-value">${rc}</span>
        </div>
        <div class="cost-meter-row" title="GitHub GraphQL bucket — fleet's most-pressured limit">
          <span class="cost-meter-label">GraphQL left</span>
          <span class="cost-meter-value">${rg}</span>
        </div>
        ${warn ? `<div class="cost-meter-warn">${warn}</div>` : ''}
      </div>
    `;
  }
}
customElements.define('chump-cost-meter', ChumpCostMeter);
