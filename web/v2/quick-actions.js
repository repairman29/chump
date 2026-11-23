// Chump v2 — verb-shaped quick-actions panel (PRODUCT-083, token-aligned PRODUCT-372).
//
// Renders 6 verb shortcuts with clean typographic kbd badges. Keyboard shortcuts
// (T R S C B ?) remain active across every view.

const ACTIONS = [
  { key: 'T', label: 'Start task',   view: 'agents',   action: 'new-task' },
  { key: 'R', label: 'Review ships', view: 'results',  action: 'merged-today' },
  { key: 'S', label: 'See stuck',    view: 'judgment', action: 'stuck' },
  { key: 'C', label: 'Configure',    view: 'settings', action: null },
  { key: 'B', label: 'Brief me',     view: 'brief',    action: 'brief' },
  { key: '?', label: 'Setup check',  view: 'welcome',  action: 'force' },
];

class ChumpQuickActions extends HTMLElement {
  #keyListener = null;
  #menuOpen = false;

  connectedCallback() {
    this.setAttribute('role', 'navigation');
    this.setAttribute('aria-label', 'Quick actions');
    this.#render();
    this.#bindKeys();
  }

  disconnectedCallback() {
    if (this.#keyListener) document.removeEventListener('keydown', this.#keyListener);
  }

  #render() {
    this.innerHTML = `
<style>
  :host, chump-quick-actions {
    display: block;
  }
  .qa-bar {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 5px 20px;
    background: var(--bg);
    border-bottom: 1px solid var(--border);
    flex-wrap: wrap;
  }
  .qa-label {
    font-family: var(--font-mono);
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-secondary);
    margin-right: 4px;
    white-space: nowrap;
  }
  .qa-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 9px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--bg-surface);
    color: var(--text);
    font-size: 11.5px;
    font-weight: 500;
    cursor: pointer;
    white-space: nowrap;
    transition: border-color 0.14s, background 0.14s, color 0.14s;
  }
  .qa-btn:hover {
    border-color: var(--accent);
    background: var(--accent-dim);
    color: var(--accent);
  }
  .qa-btn .qa-key {
    font-size: 9.5px;
    padding: 0 4px;
    border-radius: 3px;
    background: var(--bg-elevated);
    border: 1px solid var(--border);
    color: var(--text-secondary);
    font-family: var(--font-mono);
  }
  .qa-hamburger {
    display: none;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    padding: 4px 10px;
    cursor: pointer;
    color: var(--text);
    font-size: 15px;
    line-height: 1;
  }
  .qa-overlay {
    display: none;
    position: fixed;
    inset: 0;
    z-index: 8000;
    background: var(--overlay-scrim);
    align-items: flex-start;
    justify-content: center;
    padding-top: 64px;
  }
  .qa-overlay.open { display: flex; }
  .qa-overlay-panel {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    box-shadow: var(--shadow-elevated);
    padding: 12px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    min-width: 220px;
  }
  .qa-overlay-btn {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 12px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--bg);
    color: var(--text);
    font-size: 12.5px;
    cursor: pointer;
    text-align: left;
  }
  .qa-overlay-btn:hover { border-color: var(--accent); color: var(--accent); }
  .qa-overlay-btn .qa-key {
    font-size: 10px;
    padding: 1px 5px;
    border-radius: 3px;
    background: var(--bg-elevated);
    border: 1px solid var(--border);
    color: var(--text-secondary);
    font-family: var(--font-mono);
    margin-left: auto;
  }
  @media (max-width: 600px) {
    .qa-bar { flex-wrap: nowrap; overflow-x: auto; padding: 5px 12px; }
    .qa-btn .qa-key { display: none; }
  }
  @media (max-width: 420px) {
    .qa-hamburger { display: inline-flex; }
    .qa-btn { display: none; }
    .qa-label { display: none; }
  }
</style>
<div class="qa-bar" id="qa-bar">
  <span class="qa-label">Shortcuts</span>
  ${ACTIONS.map((a) => `
    <button class="qa-btn" data-view="${a.view}" data-action="${a.action ?? ''}"
            title="${a.label} (${a.key})" aria-label="${a.label}">
      <span class="qa-text">${a.label}</span>
      <kbd class="qa-key">${a.key}</kbd>
    </button>
  `).join('')}
  <button class="qa-hamburger" id="qa-hamburger" aria-label="Quick actions menu" aria-expanded="false">≡</button>
</div>
<div class="qa-overlay" id="qa-overlay" role="dialog" aria-modal="true" aria-label="Quick actions">
  <div class="qa-overlay-panel">
    ${ACTIONS.map((a) => `
      <button class="qa-overlay-btn" data-view="${a.view}" data-action="${a.action ?? ''}"
              aria-label="${a.label}">
        <span>${a.label}</span>
        <kbd class="qa-key">${a.key}</kbd>
      </button>
    `).join('')}
  </div>
</div>`;

    this.querySelectorAll('[data-view]').forEach((btn) => {
      btn.addEventListener('click', () => this.#dispatch(btn.dataset.view, btn.dataset.action));
    });

    const hamburger = this.querySelector('#qa-hamburger');
    const overlay = this.querySelector('#qa-overlay');
    hamburger?.addEventListener('click', () => {
      this.#menuOpen = !this.#menuOpen;
      overlay.classList.toggle('open', this.#menuOpen);
      hamburger.setAttribute('aria-expanded', String(this.#menuOpen));
    });
    overlay?.addEventListener('click', (e) => {
      if (e.target === overlay) this.#closeMenu();
    });
  }

  #closeMenu() {
    this.#menuOpen = false;
    this.querySelector('#qa-overlay')?.classList.remove('open');
    this.querySelector('#qa-hamburger')?.setAttribute('aria-expanded', 'false');
  }

  #dispatch(view, action) {
    this.#closeMenu();
    if (view === 'welcome') {
      const url = new URL(location.href);
      url.searchParams.set('welcome', 'force');
      location.href = url.toString();
      return;
    }
    document.dispatchEvent(
      new CustomEvent('chump:navigate', { detail: view })
    );
    if (action) {
      document.dispatchEvent(
        new CustomEvent('chump:navigate-action', { detail: { view, action } })
      );
    }
  }

  #bindKeys() {
    const keyMap = Object.fromEntries(ACTIONS.map((a) => [a.key.toLowerCase(), a]));
    this.#keyListener = (e) => {
      const tag = document.activeElement?.tagName ?? '';
      if (['INPUT', 'TEXTAREA', 'SELECT'].includes(tag)) return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      const action = keyMap[e.key.toLowerCase()] ?? (e.key === '?' ? keyMap['?'] : null);
      if (action) {
        e.preventDefault();
        this.#dispatch(action.view, action.action);
      }
    };
    document.addEventListener('keydown', this.#keyListener);
  }
}

customElements.define('chump-quick-actions', ChumpQuickActions);
