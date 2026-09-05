const STYLE = `
  .cost-meter {
    display: inline-grid;
    grid-template-columns: repeat(4, minmax(0, auto));
    gap: 0 12px;
    align-items: baseline;
    padding-bottom: 9px;
    font-size: 11px;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
  }
  .cost-meter.loading { opacity: 0.5; }
  .cost-meter.warn .cost-meter-value { color: var(--accent-warn, #cc8800); }
  .cost-meter.red .cost-meter-value { color: var(--accent-error, #cc3344); }
  .cost-meter-row { display: flex; gap: 4px; align-items: baseline; }
  .cost-meter-label {
    color: var(--text-tertiary, var(--text-secondary));
    text-transform: uppercase;
    font-size: 9px;
    letter-spacing: 0.04em;
  }
  .cost-meter-value { color: var(--text-primary); font-weight: 500; }
  .cost-meter-warn {
    grid-column: 1 / -1;
    font-size: 10px;
    color: var(--accent-warn, #cc8800);
    padding-top: 2px;
  }
`;

/**
 * <chump-cost-meter> — INFRA-1012 operator-visible fleet spend.
 *
 * Polls GET /api/telemetry/cost every 30s and renders four figures:
 *   1. session_cost_usd  (Anthropic accumulated this process-lifetime)
 *   2. github calls      (count from ambient.jsonl github_api_call events)
 *   3. remaining_core    (REST headroom, surfaces rate-limit pressure)
 *   4. remaining_graphql (GraphQL headroom — the bucket most likely to hit zero)
 *
 * Plus the cost_tracker budget_warning banner when CHUMP_DAILY_COST_BUDGET
 * is set and we're > 80% of it (warn) or > 100% (red).
 *
 * Vanilla Web Component, no build, no CDN — matches the rest of web/v2/.
 * Air-gap safe by construction.
 *
 * INFRA-1587/INFRA-4663: styles live in a shadow root so this component's
 * CSS travels with the .js file instead of web/v2/index.html.
 */
class ChumpCostMeter extends HTMLElement {
  #timer = null;
  #lastPayload = null;
  #root = null;

  connectedCallback() {
    this.#root = this.shadowRoot || this.attachShadow({ mode: 'open' });
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
      this.#root.innerHTML = `<style>${STYLE}</style><div class="cost-meter loading">${label}</div>`;
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

    this.#root.innerHTML = `
      <style>${STYLE}</style>
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
