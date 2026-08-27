// content-bots.js — INFRA-1699 slice 3/4 (META-066 phase 6c)
// <chump-view-content-bots> — 4 toggle switches for the content-bots suite
// (pmm, docubot, evangelist, copybot — see docs/agents/content-bots/bots.yaml).
//
// Each toggle PUTs {enabled: bool} to /api/content-bots/<bot_id>. On success
// the local state is updated from the response; on failure the toggle reverts
// and an error toast is shown via ChumpViewSettings.showToast (app.js).

const BOTS = [
  { bot_id: 'pmm', label: 'PMM', tier: 'marketing' },
  { bot_id: 'docubot', label: 'DocuBot', tier: 'docs' },
  { bot_id: 'evangelist', label: 'Evangelist', tier: 'community' },
  { bot_id: 'copybot', label: 'CopyBot', tier: 'conversion' },
];

class ContentBotsView extends HTMLElement {
  #bots = BOTS.map((b) => ({ ...b, enabled: false }));
  #loading = false;

  connectedCallback() {
    this.#render();
    this.#load();
  }

  async #load() {
    this.#loading = true;
    this.#render();
    try {
      const r = await fetch('/api/content-bots');
      if (r.ok) {
        const body = await r.json();
        const byId = new Map((body.bots || []).map((b) => [b.bot_id, b]));
        this.#bots = this.#bots.map((b) => ({
          ...b,
          enabled: byId.has(b.bot_id) ? !!byId.get(b.bot_id).enabled : b.enabled,
        }));
      }
    } catch (_e) {
      // Best-effort — leave defaults (all disabled) if the endpoint isn't reachable.
    } finally {
      this.#loading = false;
      this.#render();
    }
  }

  _handleToggle(botId, checked) {
    const bot = this.#bots.find((b) => b.bot_id === botId);
    if (!bot) return;
    const previous = bot.enabled;
    bot.enabled = checked;
    this.#render();

    fetch('/api/content-bots/' + botId, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled: checked }),
    })
      .then((r) => {
        if (!r.ok) throw r;
        return r.json();
      })
      .then((body) => {
        bot.enabled = typeof body.enabled === 'boolean' ? body.enabled : checked;
        this.#render();
      })
      .catch(() => {
        bot.enabled = previous;
        this.#render();
        if (window.ChumpViewSettings && typeof window.ChumpViewSettings.showToast === 'function') {
          window.ChumpViewSettings.showToast('error', 'Failed to update bot');
        }
      });
  }

  #render() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Content Bots</h2>
        <p class="view-subtitle">Marketing/docs/community pipeline — per-bot enable toggles (INFRA-1699)</p>
      </section>
      <section class="content-bots-grid">
        ${this.#bots
          .map(
            (b) => `
          <label class="content-bot-row" data-bot-id="${b.bot_id}">
            <span class="content-bot-label">${b.label}<span class="content-bot-tier">${b.tier}</span></span>
            <input type="checkbox" class="content-bot-toggle" data-bot-id="${b.bot_id}" ${b.enabled ? 'checked' : ''} ${this.#loading ? 'disabled' : ''} />
          </label>`
          )
          .join('')}
      </section>
    `;
    this.querySelectorAll('.content-bot-toggle').forEach((input) => {
      input.addEventListener('change', (e) => {
        this._handleToggle(e.target.dataset.botId, e.target.checked);
      });
    });
  }
}

customElements.define('chump-view-content-bots', ContentBotsView);
