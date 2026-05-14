// Chump v2 — verb-shaped quick-actions panel (PRODUCT-083).
//
// Renders 6 verb buttons above the noun nav so first-time users see
// actions (Start task / Review ships / See stuck / Configure / Brief me / Help)
// rather than feature names. Each button fires chump:navigate with the
// appropriate view; Help re-triggers the PRODUCT-082 welcome flow.
//
// Keyboard shortcuts (T R S C B ?) work from any view.

const ACTIONS = [
  { key: 'T', label: 'Start task',    icon: '▶',  view: 'agents',   action: 'new-task'   },
  { key: 'R', label: 'Review ships',  icon: '🚀', view: 'results',  action: 'merged-today' },
  { key: 'S', label: 'See stuck',     icon: '⚠',  view: 'judgment', action: 'stuck'      },
  { key: 'C', label: 'Configure',     icon: '⚙',  view: 'settings', action: null         },
  { key: 'B', label: 'Brief me',      icon: '📋', view: 'tasks',    action: 'brief'      },
  { key: '?', label: 'Help',          icon: '?',  view: 'welcome',  action: 'force'      },
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
    padding: 6px 12px;
    background: var(--bg-secondary, #2a2a3e);
    border-bottom: 1px solid var(--border-color, #3a3a5c);
    flex-wrap: wrap;
  }
  .qa-label {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: var(--text-secondary, #888);
    margin-right: 4px;
    white-space: nowrap;
  }
  .qa-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 5px 10px;
    border: 1px solid var(--border-color, #3a3a5c);
    border-radius: 5px;
    background: var(--bg-primary, #1e1e2e);
    color: var(--text-primary, #e0e0f0);
    font-size: 12px;
    cursor: pointer;
    white-space: nowrap;
    transition: border-color 0.15s, background 0.15s;
  }
  .qa-btn:hover { border-color: var(--accent, #7c83fd); background: var(--bg-hover, #2e2e4e); }
  .qa-btn .qa-icon { font-size: 13px; }
  .qa-btn .qa-key {
    font-size: 9px;
    padding: 1px 4px;
    border-radius: 3px;
    background: var(--bg-secondary, #2a2a3e);
    border: 1px solid var(--border-color, #3a3a5c);
    color: var(--text-secondary, #999);
    font-family: monospace;
  }
  /* Mobile: hamburger collapse */
  .qa-hamburger {
    display: none;
    background: none;
    border: 1px solid var(--border-color, #3a3a5c);
    border-radius: 5px;
    padding: 5px 10px;
    cursor: pointer;
    color: var(--text-primary, #e0e0f0);
    font-size: 18px;
    line-height: 1;
  }
  .qa-overlay {
    display: none;
    position: fixed;
    inset: 0;
    z-index: 8000;
    background: rgba(0,0,0,.5);
    align-items: flex-start;
    justify-content: center;
    padding-top: 60px;
  }
  .qa-overlay.open { display: flex; }
  .qa-overlay-panel {
    background: var(--bg-primary, #1e1e2e);
    border: 1px solid var(--border-color, #3a3a5c);
    border-radius: 8px;
    padding: 12px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    min-width: 200px;
  }
  .qa-overlay-btn {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 14px;
    border: 1px solid var(--border-color, #3a3a5c);
    border-radius: 6px;
    background: var(--bg-secondary, #2a2a3e);
    color: var(--text-primary, #e0e0f0);
    font-size: 13px;
    cursor: pointer;
    text-align: left;
  }
  .qa-overlay-btn:hover { border-color: var(--accent, #7c83fd); }
  .qa-overlay-btn .qa-key {
    font-size: 10px;
    padding: 1px 5px;
    border-radius: 3px;
    background: var(--bg-primary, #1e1e2e);
    border: 1px solid var(--border-color, #3a3a5c);
    color: var(--text-secondary, #999);
    font-family: monospace;
    margin-left: auto;
  }
  @media (max-width: 600px) {
    .qa-bar { flex-wrap: nowrap; overflow-x: auto; }
    .qa-btn .qa-label { display: none; }
    .qa-btn .qa-key  { display: none; }
  }
  @media (max-width: 420px) {
    .qa-hamburger { display: inline-flex; }
    .qa-btn { display: none; }
    .qa-label { display: none; }
  }
</style>
<div class="qa-bar" id="qa-bar">
  <span class="qa-label">Quick actions:</span>
  ${ACTIONS.map((a) => `
    <button class="qa-btn" data-view="${a.view}" data-action="${a.action ?? ''}"
            title="${a.label} (${a.key})" aria-label="${a.label}">
      <span class="qa-icon">${a.icon}</span>
      <span class="qa-label">${a.label}</span>
      <kbd class="qa-key">${a.key}</kbd>
    </button>
  `).join('')}
  <button class="qa-hamburger" id="qa-hamburger" aria-label="Quick actions menu" aria-expanded="false">☰</button>
</div>
<div class="qa-overlay" id="qa-overlay" role="dialog" aria-modal="true" aria-label="Quick actions">
  <div class="qa-overlay-panel">
    ${ACTIONS.map((a) => `
      <button class="qa-overlay-btn" data-view="${a.view}" data-action="${a.action ?? ''}"
              aria-label="${a.label}">
        <span>${a.icon}</span>
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
      // Re-trigger PRODUCT-082 welcome flow.
      const url = new URL(location.href);
      url.searchParams.set('welcome', 'force');
      location.href = url.toString();
      return;
    }
    document.dispatchEvent(
      new CustomEvent('chump:navigate', { detail: view })
    );
    if (action) {
      // Secondary event carries the filter/action hint for the view to consume.
      document.dispatchEvent(
        new CustomEvent('chump:navigate-action', { detail: { view, action } })
      );
    }
  }

  #bindKeys() {
    const keyMap = Object.fromEntries(ACTIONS.map((a) => [a.key.toLowerCase(), a]));
    this.#keyListener = (e) => {
      // Ignore when focus is inside an input/textarea/select.
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
