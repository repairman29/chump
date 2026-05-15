// web/v2/cockpit.js — PRODUCT-122
//
// <chump-view-cockpit> — Phase 1 Cockpit-MVP landing shell.
//
// Composition-only: arranges existing web components into a 5-zone CSS
// grid. No new components defined. Operator reacts to the layout in 5
// seconds rather than reviewing PWA_ROADMAP.md prose.
//
// Layout (1440x900 first; collapses on narrow):
//
//   ┌──────────────────────────────────────────────────────────────────┐
//   │                       (top bar — global header)                   │
//   ├────────────────┬─────────────────────────────┬───────────────────┤
//   │  Attention     │  Daily brief / center       │  Fleet roster     │
//   │  queue         │  (placeholder until         │                   │
//   │                │   PRODUCT-078 lands)        │                   │
//   │                │                             │  Ambient tail     │
//   │  Inbox         │                             │  (collapsible)    │
//   │  preview       │                             │                   │
//   ├────────────────┴─────────────────────────────┴───────────────────┤
//   │                  (footer — quick-actions verb nav)               │
//   └──────────────────────────────────────────────────────────────────┘
//
// Reach this from URL: /v2/?view=cockpit
// (Routing into chump-nav cadence happens in a follow-up to avoid colliding
// with 5 live leases editing app.js + index.html — PRODUCT-112/113/INFRA-
// 1203/1204/1207.)
//
// Reaction-target for PRODUCT-121 sign-off. If the operator opens this and
// says "wrong shape", we re-cut Phase 1 before sinking effort into atomic
// component gaps PRODUCT-117/078/083/080.

const CSS = `
  :host {
    display: block;
    height: 100%;
    background: var(--bg, #0d0d0f);
    color: var(--text, #e5e5ea);
    font-family: inherit;
  }
  .cockpit {
    display: grid;
    grid-template-columns: 320px 1fr 360px;
    grid-template-rows: auto 1fr auto;
    grid-template-areas:
      "title  title   title"
      "left   center  right"
      "footer footer  footer";
    gap: 12px;
    padding: 12px;
    height: 100%;
    min-height: 600px;
  }
  .cockpit-title {
    grid-area: title;
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    padding: 4px 8px;
  }
  .cockpit-title h1 {
    font-size: 18px;
    font-weight: 600;
    margin: 0;
    color: var(--text, #e5e5ea);
  }
  .cockpit-title .subtitle {
    font-size: 12px;
    color: var(--text-secondary, #8a8a8e);
  }
  .zone {
    background: var(--bg-secondary, #1a1a1c);
    border: 1px solid var(--border, #2a2a2e);
    border-radius: 10px;
    padding: 12px;
    overflow: auto;
    min-height: 0;
  }
  .zone-header {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--text-secondary, #8a8a8e);
    margin-bottom: 8px;
    padding-bottom: 6px;
    border-bottom: 1px solid var(--border, #2a2a2e);
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .zone-header .question {
    color: var(--accent, #0a84ff);
    font-weight: 500;
    text-transform: none;
    letter-spacing: 0;
  }
  .zone-left   { grid-area: left;   }
  .zone-center { grid-area: center; }
  .zone-right  { grid-area: right;  display: flex; flex-direction: column; gap: 12px; }
  .zone-footer {
    grid-area: footer;
    background: transparent;
    border: none;
    padding: 0;
    overflow: visible;
  }
  .center-placeholder {
    padding: 24px;
    text-align: center;
    color: var(--text-secondary, #8a8a8e);
    font-size: 13px;
    border: 1px dashed var(--border, #2a2a2e);
    border-radius: 8px;
  }
  .center-placeholder strong { color: var(--text, #e5e5ea); display: block; margin-bottom: 8px; }
  .center-placeholder code   {
    background: var(--bg, #0d0d0f); padding: 1px 5px; border-radius: 3px;
    font-size: 12px;
  }
  .ambient-collapsed {
    flex: 0 0 auto; max-height: 38px; overflow: hidden;
    transition: max-height 0.2s;
  }
  .ambient-expanded { flex: 1 1 auto; max-height: none; overflow: auto; }
  .ambient-toggle {
    width: 100%; background: var(--bg, #0d0d0f);
    border: 1px solid var(--border, #2a2a2e); border-radius: 6px;
    color: var(--text-secondary, #8a8a8e); padding: 6px 10px;
    cursor: pointer; font-size: 12px; text-align: left;
  }
  .ambient-toggle:hover { background: var(--bg-tertiary, #25252a); }
  .inbox-preview-wrap {
    margin-top: 12px;
    border-top: 1px solid var(--border, #2a2a2e);
    padding-top: 12px;
  }
  /* Narrow viewport: stack columns. */
  @media (max-width: 1000px) {
    .cockpit {
      grid-template-columns: 1fr;
      grid-template-areas:
        "title"
        "left"
        "center"
        "right"
        "footer";
    }
  }
`;

class ChumpViewCockpit extends HTMLElement {
  #shadow;
  #ambientExpanded = false;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#render();
  }

  #render() {
    // Shadow DOM can't host custom-element instances that need the document
    // to find them (slot-projection works, but cleaner to use light-DOM
    // children of the view via slotted construction). We render the grid
    // into shadow DOM, but mount the live components into the shadow as
    // direct children — the components themselves attach their own shadow
    // roots so they remain encapsulated. This works for every chump-* we
    // use here (verified: each uses attachShadow internally).
    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="cockpit" role="region" aria-label="Cockpit">
        <div class="cockpit-title">
          <h1>Cockpit</h1>
          <span class="subtitle">PRODUCT-121 Phase 1 — Cockpit-MVP shell (PRODUCT-122)</span>
        </div>

        <div class="zone zone-left" aria-label="Attention queue">
          <div class="zone-header">
            <span>Attention</span>
            <span class="question">What needs me?</span>
          </div>
          <div id="slot-attention"></div>
          <div class="inbox-preview-wrap">
            <div class="zone-header">
              <span>Inbox</span>
              <span class="question">What did they send?</span>
            </div>
            <div id="slot-inbox"></div>
          </div>
        </div>

        <div class="zone zone-center" aria-label="Daily brief">
          <div class="zone-header">
            <span>Since you were away</span>
            <span class="question">What did the fleet do?</span>
          </div>
          <div id="slot-brief">
            <div class="center-placeholder">
              <strong>Daily brief — lands here in Phase 1.2</strong>
              See <code>PRODUCT-078</code>. For now, this slot is reserved so
              you can react to the layout, not the content.
              <br><br>
              <em>If you'd rather see PR list / outcome / something else in
              this slot, that's the kind of feedback this shell exists to
              capture.</em>
            </div>
          </div>
        </div>

        <div class="zone zone-right" aria-label="Fleet + ambient">
          <div>
            <div class="zone-header">
              <span>Fleet</span>
              <span class="question">What's running?</span>
            </div>
            <div id="slot-fleet"></div>
          </div>
          <div class="ambient-collapsed" id="ambient-wrap">
            <button class="ambient-toggle" id="ambient-toggle" type="button"
                    aria-expanded="false">
              ▶ Ambient stream (click to expand)
            </button>
            <div id="slot-ambient" style="display:none;"></div>
          </div>
        </div>

        <div class="zone zone-footer" aria-label="Quick actions">
          <div id="slot-quick"></div>
        </div>
      </div>
    `;

    // Mount live components into slot containers. We use createElement so
    // each component runs its own connectedCallback lifecycle inside the
    // shadow tree.
    this.#mount('slot-attention', 'chump-operator-attention');
    this.#mount('slot-inbox', 'chump-inbox');
    this.#mount('slot-fleet', 'chump-fleet-sidebar');
    this.#mount('slot-ambient', 'chump-ambient-viewer');
    this.#mount('slot-quick', 'chump-quick-actions');

    // Wire ambient toggle.
    const toggle = this.#shadow.getElementById('ambient-toggle');
    const ambientSlot = this.#shadow.getElementById('slot-ambient');
    const wrap = this.#shadow.getElementById('ambient-wrap');
    toggle?.addEventListener('click', () => {
      this.#ambientExpanded = !this.#ambientExpanded;
      ambientSlot.style.display = this.#ambientExpanded ? '' : 'none';
      wrap.classList.toggle('ambient-expanded', this.#ambientExpanded);
      wrap.classList.toggle('ambient-collapsed', !this.#ambientExpanded);
      toggle.setAttribute('aria-expanded', String(this.#ambientExpanded));
      toggle.textContent = this.#ambientExpanded
        ? '▼ Ambient stream (click to collapse)'
        : '▶ Ambient stream (click to expand)';
    });
  }

  #mount(slotId, tagName) {
    const slot = this.#shadow.getElementById(slotId);
    if (!slot) return;
    try {
      slot.appendChild(document.createElement(tagName));
    } catch (e) {
      slot.innerHTML = `<div class="center-placeholder">
        <strong>${tagName}</strong>missing — script not loaded?
      </div>`;
    }
  }
}

customElements.define('chump-view-cockpit', ChumpViewCockpit);
