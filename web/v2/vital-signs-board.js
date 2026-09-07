// web/v2/vital-signs-board.js — EFFECTIVE-1462
//
// <chump-vital-signs-board> — renders the 8 VITAL SIGNS
// (scripts/ops/vital-signs.sh, ~/.chump/vital-signs.json) in the PWA cockpit
// pane. Each sign shows its current value plus a color-coded status pill
// (green/amber/red/unknown) computed server-side from the threshold config
// in vital-signs.sh — this component only renders, never re-derives status.

const CSS = `
  :host { display: block; }
  .board {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .sign-row {
    display: grid;
    grid-template-columns: auto 1fr auto;
    gap: 8px;
    align-items: center;
    padding: 6px 8px;
    border: 1px solid var(--border, #2a2a2e);
    border-radius: 6px;
    background: var(--bg, #0d0d0f);
    font-size: 12px;
  }
  .sign-dot {
    width: 9px; height: 9px; border-radius: 50%;
    flex: 0 0 auto;
  }
  .sign-dot.status-green { background: var(--success, #30d158); }
  .sign-dot.status-amber { background: var(--warn, #ff9f0a); }
  .sign-dot.status-red   { background: var(--error, #ff453a); }
  .sign-dot.status-unknown { background: var(--text-secondary, #8a8a8e); }
  .sign-name {
    color: var(--text, #e5e5ea);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .sign-value {
    font-variant-numeric: tabular-nums;
    font-weight: 600;
    color: var(--text, #e5e5ea);
    white-space: nowrap;
  }
  .sign-value.status-green { color: var(--success, #30d158); }
  .sign-value.status-amber { color: var(--warn, #ff9f0a); }
  .sign-value.status-red   { color: var(--error, #ff453a); }
  .sign-value.status-unknown { color: var(--text-secondary, #8a8a8e); }
  .board-empty, .board-error {
    padding: 12px; text-align: center; font-size: 12px;
    color: var(--text-secondary, #8a8a8e);
    border: 1px dashed var(--border, #2a2a2e); border-radius: 6px;
  }
`;

const STATUS_CLASSES = new Set(['green', 'amber', 'red', 'unknown']);

class ChumpVitalSignsBoard extends HTMLElement {
  #shadow;
  #timer;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#renderLoading();
    this.#load();
    this.#timer = setInterval(() => this.#load(), 60_000);
  }

  disconnectedCallback() {
    clearInterval(this.#timer);
  }

  async #load() {
    try {
      const r = await fetch('/api/vital-signs');
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const data = await r.json();
      this.#renderData(data);
    } catch (e) {
      this.#renderError();
    }
  }

  #renderLoading() {
    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="board" aria-label="Vital signs" aria-busy="true">
        <div class="board-empty">loading vital signs…</div>
      </div>
    `;
  }

  #renderError() {
    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="board" aria-label="Vital signs">
        <div class="board-error">⚠ couldn't load vital signs</div>
      </div>
    `;
  }

  #renderData(data) {
    const signs = Array.isArray(data?.signs) ? data.signs : [];
    if (!signs.length) {
      this.#shadow.innerHTML = `
        <style>${CSS}</style>
        <div class="board" aria-label="Vital signs">
          <div class="board-empty">no vital-signs data yet</div>
        </div>
      `;
      return;
    }

    const rows = signs.map((sign) => {
      const status = STATUS_CLASSES.has(sign.status) ? sign.status : 'unknown';
      const name = ChumpVitalSignsBoard.#esc(sign.name || sign.key || 'unknown');
      const value = ChumpVitalSignsBoard.#fmtValue(sign.value, sign.unit);
      return `
        <div class="sign-row" title="${ChumpVitalSignsBoard.#esc(sign.basis || '')}">
          <span class="sign-dot status-${status}" aria-hidden="true"></span>
          <span class="sign-name">${name}</span>
          <span class="sign-value status-${status}">${ChumpVitalSignsBoard.#esc(value)}</span>
        </div>
      `;
    }).join('');

    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="board" aria-label="Vital signs">${rows}</div>
    `;
  }

  static #fmtValue(value, unit) {
    if (value === null || value === undefined || Number.isNaN(value)) return '—';
    const num = typeof value === 'number' ? value : Number(value);
    if (Number.isNaN(num)) return String(value);
    const rounded = Number.isInteger(num) ? num : Math.round(num * 100) / 100;
    if (unit === 'percent' || unit === 'percent-organs-active') return `${rounded}%`;
    return String(rounded);
  }

  static #esc(s) {
    const d = document.createElement('div');
    d.textContent = s ?? '';
    return d.innerHTML;
  }
}

customElements.define('chump-vital-signs-board', ChumpVitalSignsBoard);
