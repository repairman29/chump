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
  .cockpit-center-stack {
    display: flex; flex-direction: column; gap: 16px;
    height: 100%;
  }
  .center-half {
    flex: 1 1 0; min-height: 0;
    display: flex; flex-direction: column;
  }
  .center-half .zone-header { flex: 0 0 auto; }
  .brief-list {
    flex: 1 1 auto; overflow: auto;
    display: flex; flex-direction: column; gap: 8px;
  }
  .brief-loading, .brief-empty {
    padding: 16px; text-align: center;
    color: var(--text-secondary, #8a8a8e); font-size: 12px;
    border: 1px dashed var(--border, #2a2a2e); border-radius: 6px;
  }
  .brief-item {
    padding: 10px 12px; border: 1px solid var(--border, #2a2a2e);
    border-radius: 6px; background: var(--bg, #0d0d0f);
    display: flex; gap: 10px; align-items: flex-start;
    font-size: 13px;
  }
  .brief-item:hover { background: var(--bg-tertiary, #25252a); }
  .brief-pill {
    flex: 0 0 auto; font-size: 10px; font-weight: 600;
    padding: 2px 6px; border-radius: 4px;
    background: var(--bg-tertiary, #25252a); color: var(--text-secondary, #8a8a8e);
    white-space: nowrap;
  }
  .brief-pill.priority-P0 { background: rgba(204,51,68,.22); color: #ff8a99; }
  .brief-pill.priority-P1 { background: rgba(10,132,255,.22); color: #6ab8ff; }
  .brief-pill.priority-P2 { background: rgba(120,140,180,.18); color: #aab5cc; }
  .brief-pill.ship-pr     { background: rgba(48,209,88,.20);  color: #6cd9a0; }
  .brief-pill.ship-gap    { background: rgba(204,136,0,.22);  color: #ffc56a; }
  .brief-body { flex: 1 1 auto; min-width: 0; }
  .brief-title {
    color: var(--text, #e5e5ea); margin-bottom: 2px;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .brief-meta {
    font-size: 11px; color: var(--text-secondary, #8a8a8e);
  }
  .brief-meta a {
    color: var(--accent, #0a84ff); text-decoration: none;
  }
  .brief-meta a:hover { text-decoration: underline; }
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
  /* PRODUCT-133: right-zone action overlay */
  .right-actions {
    padding: 10px 12px;
    background: linear-gradient(135deg, rgba(10,132,255,.10), rgba(10,132,255,.03));
    border: 1px solid rgba(10,132,255,.25);
    border-radius: 7px;
    display: flex; gap: 10px; align-items: center; justify-content: space-between;
    flex-wrap: wrap;
  }
  .right-actions[hidden] { display: none; }
  .right-actions-text {
    font-size: 12px; color: var(--text, #e5e5ea); flex: 1 1 auto;
  }
  .right-actions-text strong { color: var(--accent, #0a84ff); font-weight: 600; }
  .right-actions-btn {
    background: var(--accent, #0a84ff); color: white;
    border: none; border-radius: 5px; padding: 5px 12px;
    font-size: 12px; font-weight: 500; cursor: pointer; white-space: nowrap;
  }
  .right-actions-btn:hover { filter: brightness(1.15); }
  .right-actions-btn:disabled { opacity: 0.6; cursor: default; }
  .inbox-preview-wrap {
    margin-top: 12px;
    border-top: 1px solid var(--border, #2a2a2e);
    padding-top: 12px;
  }
  /* ── Intelligence layer: Read → Signal → Noise ─────────────────────── */
  .intel-stack {
    display: flex; flex-direction: column; gap: 14px;
    height: 100%;
  }
  /* The Read — one sentence, highest visual weight */
  .intel-read {
    padding: 14px 16px;
    border-radius: 8px;
    background: linear-gradient(135deg, rgba(10,132,255,.08), rgba(10,132,255,.02));
    border: 1px solid rgba(10,132,255,.25);
  }
  .intel-read-label {
    font-size: 10px; font-weight: 600; letter-spacing: 0.08em;
    color: var(--accent, #0a84ff); text-transform: uppercase;
    margin-bottom: 6px;
  }
  .intel-read-text {
    font-size: 15px; line-height: 1.45;
    color: var(--text, #e5e5ea);
  }
  .intel-read-meta {
    margin-top: 8px; font-size: 11px;
    color: var(--text-secondary, #8a8a8e);
    display: flex; gap: 12px; align-items: center;
  }
  .intel-confidence {
    display: inline-flex; align-items: center; gap: 4px;
  }
  .intel-confidence-dot {
    display: inline-block; width: 8px; height: 8px; border-radius: 50%;
  }
  .intel-confidence-dot.high   { background: #30d158; }
  .intel-confidence-dot.medium { background: #ffd60a; }
  .intel-confidence-dot.low    { background: #ff453a; }
  .intel-read-evidence {
    background: none; border: none; padding: 0;
    color: var(--accent, #0a84ff); cursor: pointer;
    font-size: 11px; text-decoration: underline;
  }

  /* Signal — narrative cards */
  .intel-signal {
    flex: 1 1 auto; min-height: 0; overflow: auto;
    display: flex; flex-direction: column; gap: 10px;
  }
  .intel-signal-label {
    font-size: 10px; font-weight: 600; letter-spacing: 0.08em;
    color: var(--text-secondary, #8a8a8e); text-transform: uppercase;
    padding-bottom: 6px;
    border-bottom: 1px solid var(--border, #2a2a2e);
  }
  .intel-card {
    padding: 11px 13px;
    border: 1px solid var(--border, #2a2a2e);
    border-radius: 7px;
    background: var(--bg, #0d0d0f);
    display: grid;
    grid-template-columns: auto 1fr auto;
    gap: 10px 12px;
    align-items: start;
  }
  .intel-card.counter {
    border-color: rgba(255,159,10,.35);
    background: linear-gradient(135deg, rgba(255,159,10,.05), transparent);
  }
  .intel-card-icon {
    grid-row: 1 / span 2;
    font-size: 18px; line-height: 1; padding-top: 1px;
  }
  .intel-card-title {
    font-size: 13px; font-weight: 600;
    color: var(--text, #e5e5ea);
  }
  .intel-card-detail {
    font-size: 12px;
    color: var(--text-secondary, #8a8a8e);
    grid-column: 2 / span 2;
  }
  .intel-card-actions {
    grid-row: 1; grid-column: 3;
    display: flex; gap: 6px; align-items: center;
  }
  .intel-card-btn {
    background: var(--bg-tertiary, #25252a);
    border: 1px solid var(--border, #2a2a2e);
    color: var(--text, #e5e5ea);
    padding: 3px 8px; border-radius: 4px;
    font-size: 11px; cursor: pointer; text-decoration: none;
    white-space: nowrap;
  }
  .intel-card-btn:hover { background: var(--accent, #0a84ff); color: white; border-color: transparent; }
  .intel-card-btn.wrong {
    color: var(--text-secondary, #8a8a8e);
    padding: 3px 6px;
  }
  .intel-card-btn.wrong:hover { background: #ff453a; color: white; }
  .intel-card-btn.primary {
    background: var(--accent, #0a84ff); color: white; border-color: transparent;
  }

  /* Noise — collapsed by default */
  .intel-noise {
    flex: 0 0 auto;
    border-top: 1px solid var(--border, #2a2a2e);
    padding-top: 10px;
  }
  .intel-noise-toggle {
    background: none; border: none;
    color: var(--text-secondary, #8a8a8e);
    font-size: 11px; cursor: pointer;
    padding: 0; text-align: left;
    width: 100%;
  }
  .intel-noise-toggle:hover { color: var(--accent, #0a84ff); }
  .intel-noise-body {
    margin-top: 10px;
    max-height: 200px; overflow: auto;
    font-family: ui-monospace, monospace; font-size: 11px;
    color: var(--text-secondary, #8a8a8e);
    display: none;
  }
  .intel-noise-body.open { display: block; }
  .intel-noise-event {
    padding: 4px 0;
    border-bottom: 1px solid var(--border, #2a2a2e);
  }
  .intel-noise-event:last-child { border: none; }

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

        <div class="zone zone-center" aria-label="Intelligence">
          <div class="intel-stack">
            <!-- THE READ: one synthesized sentence with confidence -->
            <section class="intel-read" id="intel-read" aria-label="The read">
              <div class="intel-read-label">The read</div>
              <div class="intel-read-text" id="intel-read-text">
                Synthesizing…
              </div>
              <div class="intel-read-meta" id="intel-read-meta"></div>
            </section>

            <!-- SIGNAL: 3-4 narrative cards -->
            <section class="intel-signal" aria-label="Signal">
              <div class="intel-signal-label">Signal</div>
              <div id="intel-cards">
                <div class="brief-loading">Pattern-extracting…</div>
              </div>
            </section>

            <!-- NOISE: collapsed raw event stream -->
            <section class="intel-noise" aria-label="Noise">
              <button type="button" class="intel-noise-toggle"
                      id="intel-noise-toggle" aria-expanded="false">
                ▶ <span id="intel-noise-count">…</span> raw events fed this synthesis
              </button>
              <div class="intel-noise-body" id="intel-noise-body"></div>
            </section>
          </div>
        </div>

        <div class="zone zone-right" aria-label="Fleet + ambient">
          <!-- PRODUCT-133: right-zone action overlay. Reuses center-zone
               synthesis inputs to propose the right action for the right
               zone's actual state (no workers → Wake, idle picker →
               Stop+restart, sparse stream → Tail). Action-model Rule 2:
               every empty state IS the action button. -->
          <div class="right-actions" id="right-actions" hidden></div>
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
    // Center: synthesize Read/Signal/Noise from ambient + gap-queue.
    this.#synthesize();
    // Noise toggle.
    const noiseToggle = this.#shadow.getElementById('intel-noise-toggle');
    const noiseBody = this.#shadow.getElementById('intel-noise-body');
    noiseToggle?.addEventListener('click', () => {
      const open = noiseBody.classList.toggle('open');
      noiseToggle.setAttribute('aria-expanded', String(open));
      noiseToggle.firstChild.textContent = open ? '▼ ' : '▶ ';
    });

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

  // ── Synthesis pipeline: ambient + gap-queue → Read / Signal / Noise ──────
  //
  // ALGORITHM (also documented in docs/product/COCKPIT_SYNTHESIS.md):
  //
  //   inputs  = /api/ambient/recent?limit=200 + /api/gap-queue
  //   ships   = events where kind in {pr_merged, gap_shipped, gap_done,
  //                                    pr_closed_merged}
  //   feedback= events where kind in {feedback_emitted, operator_feedback,
  //                                    ambient_feedback}
  //   queue   = gaps where status='open', sorted by priority then effort
  //
  //   THE READ = pick highest-signal narrative:
  //     (a) if recent (<10min) feedback exists referencing an open gap by
  //         subject substring  → "active reshape" read
  //     (b) elif ships in last 24h > 0
  //         → "{N} PR shipped, {top_domain} dominant" read
  //     (c) else "fleet idle for {since_last_ship}" read
  //   confidence = high if data window ≥ 12h AND ≥ 3 events; medium if
  //                ≥ 1 event in window; low otherwise
  //
  //   SIGNAL cards (in this fixed order — NOT ranked):
  //     1. Today's arc      — count ships in 24h, list top 2 PRs
  //     2. Active reshape   — most recent feedback event with open-gap ref
  //     3. Counter-evidence — hard-coded anti-pattern: phase ships but no
  //                           external dogfooders (PRODUCT-119 status)
  //     4. Next decision    — highest-priority unclaimed open gap w/ AC
  //
  //   NOISE = total raw event count + ALL events fed the synthesis (drillable)
  //
  // BIAS MITIGATIONS:
  //   - synthesis is templated, not LLM/opinion
  //   - every card has 🚩 wrong button → emits FEEDBACK kind=preference
  //     vote=-1 subject=cockpit_card_<id> for tomorrow's re-rank
  //   - counter-evidence card is REQUIRED — never hidden, even if good news
  //   - confidence indicator on the Read (high/medium/low dot)
  //   - all evidence (raw events) one click away under Noise
  async #synthesize() {
    const inputs = await this.#fetchInputs();
    const synth = this.#computeSynthesis(inputs);
    this.#renderRead(synth.read, synth.confidence, synth.evidenceCount);
    this.#renderSignal(synth.cards);
    this.#renderNoise(inputs.events);
    this.#renderRightZoneAction(inputs);
  }

  // PRODUCT-133: right-zone action overlay. The center zone proposes
  // intelligence; the right zone's evidence panels also surface a primary
  // action when their underlying state is degraded. Action-model Rule 2:
  // empty state IS the action button.
  //
  // Decision ladder (first match wins):
  //   1. autopilot off + queue has dispatchable → [Wake fleet]
  //   2. autopilot on + 0 ships in 24h + sparse ambient → [Restart autopilot]
  //   3. ambient stream sparse (<5 events) → [Copy tail command]
  //   4. None of above → overlay hidden (right zone fine as-is)
  #renderRightZoneAction({ events, queue, autopilot }) {
    const overlay = this.#shadow.getElementById('right-actions');
    if (!overlay) return;
    const autopilotRunning = !!(autopilot && (
      autopilot.actual_state === 'running'
      || autopilot.actual_state === 'starting'
      || autopilot.desired_enabled === true
    ));
    const dispatchable = (queue || []).some((g) =>
      (g.status || 'open') === 'open'
      && (g.priority === 'P0' || g.priority === 'P1')
      && Array.isArray(g.acceptance_criteria) && g.acceptance_criteria.length > 0
      && !g.claimed_by && !g.assignee
    );
    const recentEvents = (events || []).length;
    let html = '';
    if (!autopilotRunning && dispatchable) {
      html = `
        <span class="right-actions-text">
          <strong>Fleet parked.</strong> Queue has dispatchable P0/P1 work.
        </span>
        <button class="right-actions-btn" data-action-view="wake-fleet">Wake fleet</button>
      `;
    } else if (autopilotRunning && recentEvents < 10) {
      html = `
        <span class="right-actions-text">
          <strong>Autopilot on, ambient sparse.</strong> Picker may be wedged.
        </span>
        <button class="right-actions-btn" data-action-view="restart-fleet">Stop + restart</button>
      `;
    } else if (recentEvents < 5) {
      html = `
        <span class="right-actions-text">
          <strong>Ambient stream sparse.</strong> Stream may not be wired here.
        </span>
        <button class="right-actions-btn" data-action-view="copy-tail">Copy tail command</button>
      `;
    } else {
      overlay.setAttribute('hidden', '');
      overlay.innerHTML = '';
      return;
    }
    overlay.removeAttribute('hidden');
    overlay.innerHTML = html;
    const btn = overlay.querySelector('button.right-actions-btn');
    if (btn) {
      btn.addEventListener('click', () => this.#onCardAction(btn));
    }
  }

  async #fetchInputs() {
    const [eventsR, queueR, autopilotR, driftR] = await Promise.allSettled([
      fetch('/api/ambient/recent?limit=200'),
      fetch('/api/gap-queue'),
      fetch('/api/autopilot/status'),
      fetch('/api/gap/drift-status'),  // PRODUCT-127: drift count from state.db
    ]);
    let events = [];
    let queue = [];
    let autopilot = null;
    let driftStatus = null;
    try {
      if (eventsR.status === 'fulfilled' && eventsR.value.ok) {
        const d = await eventsR.value.json();
        events = d.events || [];
      }
    } catch {}
    try {
      if (queueR.status === 'fulfilled' && queueR.value.ok) {
        const d = await queueR.value.json();
        queue = d.gaps || [];
      }
    } catch {}
    try {
      if (autopilotR.status === 'fulfilled' && autopilotR.value.ok) {
        autopilot = await autopilotR.value.json();
      }
    } catch {}
    try {
      if (driftR.status === 'fulfilled' && driftR.value.ok) {
        driftStatus = await driftR.value.json();
      }
    } catch {}
    return { events, queue, autopilot, driftStatus };
  }

  #computeSynthesis({ events, queue, autopilot, driftStatus }) {
    const now = Date.now();
    const dayMs = 24 * 3600 * 1000;
    const tenMin = 10 * 60 * 1000;
    const SHIP_KINDS = new Set([
      'pr_merged', 'gap_shipped', 'gap_done', 'pr_closed_merged',
    ]);
    const FEEDBACK_KINDS = new Set([
      'feedback_emitted', 'operator_feedback', 'ambient_feedback',
    ]);

    const tsOf = (e) => e.ts ? new Date(e.ts).getTime() : 0;
    const within = (e, ms) => (now - tsOf(e)) < ms;

    const ships24h   = events.filter((e) => SHIP_KINDS.has((e.kind || '').toLowerCase()) && within(e, dayMs));
    const recentFb   = events.filter((e) => FEEDBACK_KINDS.has((e.kind || '').toLowerCase()) && within(e, tenMin));
    const lastShip   = events.find((e) => SHIP_KINDS.has((e.kind || '').toLowerCase()));
    const openGaps   = queue.filter((g) => (g.status || 'open') === 'open');
    const nextDec    = openGaps
      .filter((g) => Array.isArray(g.acceptance_criteria) && g.acceptance_criteria.length > 0)
      .sort((a, b) => {
        const o = { P0: 0, P1: 1, P2: 2, P3: 3, P4: 4, P5: 5 };
        return (o[a.priority] ?? 9) - (o[b.priority] ?? 9);
      })[0];

    // ─ THE READ ────────────────────────────────────────────────────────────
    let read, confidence;
    if (recentFb.length > 0) {
      const fb = recentFb[0];
      const subj = fb.subject || fb.body?.subject || 'unspecified';
      const ago = this.#ago(new Date(tsOf(fb)));
      read = `Your "${subj}" feedback (${ago}) is reshaping current work. Synthesis is responding live.`;
      confidence = 'high';
    } else if (ships24h.length > 0) {
      const n = ships24h.length;
      const sinceLast = lastShip ? this.#ago(new Date(tsOf(lastShip))) : 'recently';
      read = `${n} ship${n === 1 ? '' : 's'} in the last 24h. Most recent ${sinceLast}.`;
      confidence = ships24h.length >= 3 ? 'high' : 'medium';
    } else if (lastShip) {
      read = `Fleet idle — no ships in 24h. Last ship was ${this.#ago(new Date(tsOf(lastShip)))}.`;
      confidence = 'medium';
    } else {
      read = 'No recent activity in ambient. Either the fleet hasn\'t shipped yet, or ambient.jsonl isn\'t being read here.';
      confidence = 'low';
    }

    // ─ SIGNAL CARDS ────────────────────────────────────────────────────────
    const cards = [];

    // Card 1: Today's arc — PRODUCT-128 (Wake-fleet action when idle + autopilot off)
    const autopilotRunning = !!(autopilot && (
      autopilot.actual_state === 'running'
      || autopilot.actual_state === 'starting'
      || autopilot.desired_enabled === true
    ));
    if (ships24h.length > 0) {
      const topPrs = ships24h
        .filter((e) => e.pr_number)
        .slice(0, 2)
        .map((e) => `#${e.pr_number}`)
        .join(' + ');
      cards.push({
        id: 'todays-arc',
        icon: '📈',
        title: `Today's arc — ${ships24h.length} ship${ships24h.length === 1 ? '' : 's'}`,
        detail: topPrs ? `Most recent: ${topPrs}` : 'No PR numbers attached.',
        actions: [{ label: 'see ships', view: 'noise' }],
      });
    } else if (!autopilotRunning) {
      // Idle + autopilot off → propose [Wake fleet]
      cards.push({
        id: 'todays-arc',
        icon: '📈',
        title: `Today's arc — zero ships, autopilot off`,
        detail: `Fleet is parked. Wake autopilot to start the dispatch loop, or pick a one-off gap manually.`,
        actions: [
          { label: 'Wake fleet', view: 'wake-fleet', primary: true },
          { label: 'see fleet panel', view: 'fleet' },
        ],
      });
    } else {
      // Idle but autopilot is on — diff diagnosis
      const lastErr = autopilot?.last_error;
      cards.push({
        id: 'todays-arc',
        icon: '📈',
        title: `Today's arc — zero ships (autopilot on)`,
        detail: lastErr
          ? `Autopilot running but picker stuck. Last error: ${this.#truncate(String(lastErr), 90)}`
          : `Autopilot on but nothing's shipping. Picker may be wedged or queue is dry.`,
        actions: [
          { label: 'Stop + restart', view: 'restart-fleet', primary: true },
          { label: 'see fleet panel', view: 'fleet' },
        ],
      });
    }

    // Card 1b: Gap-store drift — PRODUCT-127 (Repair-drift action)
    // Prefer the authoritative /api/gap/drift-status count; fall back to
    // local queue heuristic (closed_pr + status=open) when the endpoint is
    // unavailable (e.g. binary not rebuilt yet after this change lands).
    const apiDriftCount = driftStatus?.count ?? null;
    const localDriftCount = queue.filter((g) =>
      g.closed_pr && (g.status || 'open') === 'open'
    ).length;
    const driftCount = apiDriftCount !== null ? apiDriftCount : localDriftCount;
    if (driftCount >= 1) {
      cards.push({
        id: 'gap-store-drift',
        icon: '🧹',
        title: `Gap drift: ${driftCount} instance${driftCount === 1 ? '' : 's'}`,
        detail: `${driftCount} gap${driftCount === 1 ? '' : 's'} with closed_pr set but status still 'open'. Picker may re-claim already-shipped work. One-click repair reconciles state.db.`,
        actions: [
          { label: 'Repair drift', view: 'repair-drift', primary: true },
        ],
      });
    }

    // Card 2: Active reshape (only if feedback exists)
    if (recentFb.length > 0) {
      const fb = recentFb[0];
      const subj = fb.subject || fb.body?.subject || 'unspecified';
      cards.push({
        id: 'active-reshape',
        icon: '🔄',
        title: `Active reshape — "${subj}"`,
        detail: `Feedback emitted ${this.#ago(new Date(tsOf(fb)))}. Synthesis demoting this card if you 🚩 it.`,
        actions: [{ label: 'see feedback', href: '#', view: 'noise' }],
      });
    }

    // Card 1c: No workers + queue has P1 → propose dispatch (PRODUCT-130)
    const fleetWorkers = autopilot?.recent_events?.filter?.((e) =>
      (e.kind || '').includes('worker') || (e.kind || '').includes('claim_')) || [];
    const noWorkers = !autopilotRunning && fleetWorkers.length === 0;
    const dispatchable = openGaps
      .filter((g) => g.priority === 'P1' || g.priority === 'P0')
      .filter((g) => !g.claimed_by && !g.assignee)
      .filter((g) => Array.isArray(g.acceptance_criteria) && g.acceptance_criteria.length > 0)
      .sort((a, b) => {
        const o = { P0: 0, P1: 1 };
        return (o[a.priority] ?? 9) - (o[b.priority] ?? 9);
      })[0];
    if (noWorkers && dispatchable) {
      cards.push({
        id: 'no-workers-dispatch',
        icon: '🚀',
        title: `No workers running — top ${dispatchable.priority} ready to dispatch`,
        detail: `${dispatchable.id}: ${this.#truncate(dispatchable.title || '', 75)}`,
        actions: [
          { label: `Dispatch ${dispatchable.id}`, view: 'dispatch-gap', gapId: dispatchable.id, primary: true },
          { label: 'see gap', view: 'gap', gapId: dispatchable.id },
        ],
      });
    }

    // Card 2b: Fleet-health pattern (only if a meaningful anomaly exists)
    const anomalyKinds = {};
    for (const e of events) {
      const k = (e.kind || '').toLowerCase();
      // Anti-patterns the operator should know about, weighted by severity
      if (k === 'fleet_state_lock_timeout' || k === 'fleet_wedge'
          || k === 'silent_agent' || k === 'pr_stuck'
          || k === 'cache_drift' || k === 'slo_breach') {
        anomalyKinds[k] = (anomalyKinds[k] || 0) + 1;
      }
    }
    const topAnomaly = Object.entries(anomalyKinds).sort((a, b) => b[1] - a[1])[0];
    if (topAnomaly && topAnomaly[1] >= 3) {
      const [kind, count] = topAnomaly;
      const friendly = {
        fleet_state_lock_timeout: 'Lock contention spike',
        fleet_wedge: 'Fleet wedge detected',
        silent_agent: 'Silent agent(s)',
        pr_stuck: 'PR stuck cluster',
        cache_drift: 'Cache thrashing',
        slo_breach: 'SLO breach',
      }[kind] || kind;
      // PRODUCT-129: kinds that map to a one-click remediation get a primary
      // action button. Others fall back to "show events" (drillable evidence).
      const actions = [];
      if (kind === 'fleet_state_lock_timeout' || kind === 'silent_agent') {
        actions.push({
          label: 'Release expired leases',
          view: 'release-expired-leases',
          primary: true,
        });
      }
      actions.push({ label: 'show events', view: 'noise' });
      cards.push({
        id: `anomaly-${kind}`,
        icon: '⚠️',
        title: `${friendly} — ${count} events in window`,
        detail: `Pattern detected via kind=${kind}. May indicate fleet plumbing needs attention.`,
        actions,
      });
    }

    // Card 3: Counter-evidence (REQUIRED — always present)
    // PRODUCT-131: action_kind-specific actions (Draft outreach / Bump priority)
    // instead of just navigating to GitHub. The principle: counter-evidence
    // points at a problem; the action button proposes the fix.
    cards.push({
      id: 'counter-evidence',
      icon: '🟡',
      title: 'Counter-evidence — 0 external dogfooders',
      detail: 'Phase 1 ships don\'t matter if no operator outside Jeff opens the cockpit. PRODUCT-119 is the recruitment gap; today it sits at P2.',
      counter: true,
      actions: [
        { label: 'Draft outreach', view: 'draft-outreach', primary: true },
        { label: 'Bump P2→P1', view: 'bump-priority', gapId: 'PRODUCT-119' },
        { label: 'see gap', view: 'gap', gapId: 'PRODUCT-119' },
      ],
    });

    // Card 4: Next decision (only if a clear candidate exists)
    if (nextDec) {
      cards.push({
        id: 'next-decision',
        icon: '⏭',
        title: `Next decision — ${nextDec.id} (${nextDec.priority})`,
        detail: this.#truncate(nextDec.title || '', 90),
        actions: [
          { label: 'see gap', href: '#', view: 'gap', gapId: nextDec.id },
          { label: 'pick it', href: '#', view: 'pick', gapId: nextDec.id, primary: true },
        ],
      });
    }

    return { read, confidence, cards, evidenceCount: events.length };
  }

  #renderRead(text, confidence, evidenceCount) {
    const t = this.#shadow.getElementById('intel-read-text');
    const m = this.#shadow.getElementById('intel-read-meta');
    if (t) t.textContent = text;
    if (m) {
      const dot = confidence === 'high' ? 'high' : confidence === 'medium' ? 'medium' : 'low';
      const conf = confidence === 'high' ? 'High confidence' : confidence === 'medium' ? 'Medium confidence' : 'Low confidence — limited data';
      m.innerHTML = `
        <span class="intel-confidence">
          <span class="intel-confidence-dot ${dot}"></span>
          ${conf}
        </span>
        <span>· ${evidenceCount} events in window</span>
        <span>·</span>
        <button class="intel-read-evidence" type="button" id="intel-read-evidence">show evidence ↓</button>
      `;
      m.querySelector('#intel-read-evidence')?.addEventListener('click', () => {
        const body = this.#shadow.getElementById('intel-noise-body');
        const toggle = this.#shadow.getElementById('intel-noise-toggle');
        body?.classList.add('open');
        toggle?.setAttribute('aria-expanded', 'true');
        if (toggle?.firstChild) toggle.firstChild.textContent = '▼ ';
        body?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      });
    }
  }

  #renderSignal(cards) {
    const slot = this.#shadow.getElementById('intel-cards');
    if (!slot) return;
    if (cards.length === 0) {
      slot.innerHTML = '<div class="brief-empty">No signal extracted — too little data.</div>';
      return;
    }
    slot.innerHTML = cards.map((c) => {
      const actionsHtml = (c.actions || []).map((a) => `
        <button class="intel-card-btn ${a.primary ? 'primary' : ''}" type="button"
                data-card-id="${this.#escape(c.id)}"
                data-action-view="${this.#escape(a.view || '')}"
                data-action-gap="${this.#escape(a.gapId || '')}">
          ${this.#escape(a.label)}
        </button>`).join('');
      return `
        <div class="intel-card ${c.counter ? 'counter' : ''}" data-card-id="${this.#escape(c.id)}">
          <div class="intel-card-icon">${c.icon || ''}</div>
          <div class="intel-card-title">${this.#escape(c.title)}</div>
          <div class="intel-card-actions">
            ${actionsHtml}
            <button class="intel-card-btn wrong" type="button"
                    data-card-id="${this.#escape(c.id)}"
                    data-action-view="wrong"
                    title="Wrong card? Tell the synthesis.">🚩</button>
          </div>
          <div class="intel-card-detail">${this.#escape(c.detail)}</div>
        </div>
      `;
    }).join('');
    slot.querySelectorAll('button[data-card-id]').forEach((btn) => {
      btn.addEventListener('click', (e) => this.#onCardAction(e.currentTarget));
    });
  }

  #renderNoise(events) {
    const count = this.#shadow.getElementById('intel-noise-count');
    const body  = this.#shadow.getElementById('intel-noise-body');
    if (count) count.textContent = String(events.length);
    if (body) {
      body.innerHTML = events.slice(0, 50).map((e) => `
        <div class="intel-noise-event">
          [${this.#escape(e.ts || '')}] ${this.#escape(e.kind || '?')}
          ${e.pr_number ? `pr=#${e.pr_number}` : ''}
          ${e.subject ? `subj="${this.#escape(this.#truncate(e.subject, 50))}"` : ''}
        </div>`).join('');
    }
  }

  async #onCardAction(btn) {
    const cardId = btn.dataset.cardId;
    const view = btn.dataset.actionView;
    const gapId = btn.dataset.actionGap;

    if (view === 'wrong') {
      // 🚩 — emit FEEDBACK so tomorrow's synthesis demotes this card
      try {
        await fetch('/api/broadcast', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            event: 'FEEDBACK',
            kind: 'preference',
            subject: `cockpit_card_${cardId}`,
            vote: '-1',
            rationale: 'operator flagged cockpit synthesis card as wrong',
          }),
        });
        btn.textContent = '✓';
        btn.disabled = true;
      } catch (e) {
        console.warn('flag-card feedback failed', e);
      }
      return;
    }
    if (view === 'noise') {
      const body = this.#shadow.getElementById('intel-noise-body');
      const toggle = this.#shadow.getElementById('intel-noise-toggle');
      body?.classList.add('open');
      toggle?.setAttribute('aria-expanded', 'true');
      if (toggle?.firstChild) toggle.firstChild.textContent = '▼ ';
      return;
    }
    if (view === 'gap' && gapId) {
      // Best-effort: open gap details in a new window via GH search.
      window.open(`https://github.com/repairman29/chump/issues?q=${gapId}`, '_blank', 'noopener');
      return;
    }
    if (view === 'pick' && gapId) {
      // Trigger picker via existing API; on success show toast via console.
      try {
        const r = await fetch(`/api/gap/work/${encodeURIComponent(gapId)}`, { method: 'POST' });
        const d = await r.json();
        console.info('[cockpit] picked', gapId, d);
        btn.textContent = '✓ picked';
        btn.disabled = true;
      } catch (e) {
        console.warn('pick failed', e);
      }
      return;
    }
    if (view === 'fleet') {
      // Scroll the right zone (fleet sidebar) into focus.
      this.#shadow.querySelector('.zone-right')?.scrollIntoView({ behavior: 'smooth' });
      return;
    }

    // PRODUCT-133 — Copy ambient tail command to clipboard.
    if (view === 'copy-tail') {
      const cmd = 'tail -f .chump-locks/ambient.jsonl | jq -c .';
      try {
        await navigator.clipboard.writeText(cmd);
        btn.textContent = '✓ Copied — paste in terminal';
      } catch {
        btn.textContent = `Run: ${cmd}`;
      }
      btn.disabled = true;
      setTimeout(() => {
        btn.textContent = 'Copy tail command';
        btn.disabled = false;
      }, 5000);
      return;
    }

    // PRODUCT-128 — Wake-fleet button on Today's-arc card
    if (view === 'wake-fleet') {
      btn.disabled = true;
      btn.textContent = 'Starting…';
      try {
        const r = await fetch('/api/autopilot/start', { method: 'POST' });
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        btn.textContent = '✓ Autopilot starting';
        // Re-synthesize after 2s to refresh the cockpit read
        setTimeout(() => this.#synthesize(), 2500);
      } catch (e) {
        btn.textContent = `✗ ${e.message || 'failed'}`;
        btn.disabled = false;
        setTimeout(() => { btn.textContent = 'Wake fleet'; }, 4000);
      }
      return;
    }
    if (view === 'restart-fleet') {
      btn.disabled = true;
      btn.textContent = 'Restarting…';
      try {
        await fetch('/api/autopilot/stop', { method: 'POST' });
        await new Promise((r) => setTimeout(r, 800));
        const r = await fetch('/api/autopilot/start', { method: 'POST' });
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        btn.textContent = '✓ Restarted';
        setTimeout(() => this.#synthesize(), 2500);
      } catch (e) {
        btn.textContent = `✗ ${e.message || 'failed'}`;
        btn.disabled = false;
        setTimeout(() => { btn.textContent = 'Stop + restart'; }, 4000);
      }
      return;
    }

    // PRODUCT-127 — Real /api/gap/dep-clean wire (one-click fix)
    if (view === 'copy-repair' || view === 'repair-drift') {
      btn.disabled = true;
      btn.textContent = 'Repairing…';
      try {
        const r = await fetch('/api/gap/dep-clean', { method: 'POST' });
        if (r.status === 404) {
          // Endpoint not in running binary yet — clipboard fallback
          await navigator.clipboard.writeText('chump gap dep-clean --apply');
          btn.textContent = '✓ Copied (endpoint pending rebuild — paste in terminal)';
        } else if (!r.ok) {
          throw new Error(`HTTP ${r.status}`);
        } else {
          const d = await r.json();
          const n = d.result?.cleaned_count ?? d.result?.count ?? 'some';
          btn.textContent = `✓ Repaired ${n} drift rows`;
          setTimeout(() => this.#synthesize(), 1500);
        }
      } catch (e) {
        btn.textContent = `✗ ${e.message || 'failed'}`;
      }
      setTimeout(() => { btn.disabled = false; }, 5000);
      return;
    }

    // PRODUCT-129 — Release expired leases (real endpoint)
    if (view === 'release-expired-leases') {
      btn.disabled = true;
      btn.textContent = 'Scanning leases…';
      try {
        const r = await fetch('/api/lease/release-expired', { method: 'POST' });
        if (r.status === 404) {
          await navigator.clipboard.writeText(
            'find .chump-locks -name "*.json" -mtime +1h -delete  # rough fallback');
          btn.textContent = '✓ Endpoint pending rebuild — fallback copied';
        } else if (!r.ok) {
          throw new Error(`HTTP ${r.status}`);
        } else {
          const d = await r.json();
          btn.textContent = `✓ Released ${d.released_count ?? 0}/${d.scanned ?? 0}`;
          setTimeout(() => this.#synthesize(), 1500);
        }
      } catch (e) {
        btn.textContent = `✗ ${e.message || 'failed'}`;
      }
      setTimeout(() => { btn.disabled = false; }, 5000);
      return;
    }

    // PRODUCT-130 — Dispatch top-priority gap
    if (view === 'dispatch-gap' && gapId) {
      btn.disabled = true;
      btn.textContent = 'Dispatching…';
      try {
        const r = await fetch(`/api/gap/work/${encodeURIComponent(gapId)}`, {
          method: 'POST',
        });
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        btn.textContent = `✓ Dispatched ${gapId}`;
        setTimeout(() => this.#synthesize(), 2000);
      } catch (e) {
        btn.textContent = `✗ ${e.message || 'failed'}`;
      }
      setTimeout(() => { btn.disabled = false; }, 5000);
      return;
    }

    // PRODUCT-131 — Counter-evidence actions
    if (view === 'draft-outreach') {
      const template =
        'Hi {{NAME}} — \n\n' +
        'I\'m running an experimental coordination platform called Chump that ' +
        'lets autonomous AI agents work as a fleet on your repo. It runs ' +
        '100% locally (or via your own API keys) and the cockpit gives you ' +
        'one-click control over the agents.\n\n' +
        'I\'m looking for 5 dev teams to dogfood it for 30 days. No cost, no ' +
        'lock-in, the data stays on your machine. I just want operator ' +
        'feedback (good and bad). Interested?\n\n' +
        'Quick demo: <link to chump-demo>\nSetup: <link to install guide>\n\n' +
        '— {{YOUR_NAME}}';
      try {
        await navigator.clipboard.writeText(template);
        btn.textContent = '✓ Template copied — paste into Slack/email';
      } catch {
        // Fallback: open mailto with template as body
        const subj = encodeURIComponent('Try Chump — fleet coordination for solo devs');
        const body = encodeURIComponent(template);
        window.open(`mailto:?subject=${subj}&body=${body}`, '_blank');
        btn.textContent = '✓ Opened mail composer';
      }
      btn.disabled = true;
      setTimeout(() => { btn.disabled = false; btn.textContent = 'Draft outreach'; }, 6000);
      return;
    }
    if (view === 'bump-priority' && gapId) {
      // No /api/gap/set endpoint yet — clipboard fallback with the CLI command
      const cmd = `chump gap set ${gapId} --priority P1`;
      try {
        await navigator.clipboard.writeText(cmd);
        btn.textContent = `✓ Command copied — paste to bump ${gapId}`;
      } catch {
        btn.textContent = `Run: ${cmd}`;
      }
      btn.disabled = true;
      setTimeout(() => { btn.disabled = false; btn.textContent = 'Bump P2→P1'; }, 6000);
      return;
    }
  }

  #truncate(s, n) {
    s = String(s || '');
    return s.length > n ? s.slice(0, n - 1) + '…' : s;
  }

  // ── Legacy methods retained for compat (no longer wired) ─────────────────
  async #loadReleaseNotes_LEGACY() {
    const slot = this.#shadow.getElementById('slot-release-notes');
    if (!slot) return;
    try {
      const r = await fetch('/api/ambient/recent?limit=200');
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const d = await r.json();
      const events = (d.events || []).filter((e) => {
        const k = (e.kind || '').toLowerCase();
        return k === 'pr_merged'
            || k === 'gap_shipped'
            || k === 'gap_done'
            || k === 'pr_closed_merged';
      });
      const merges = events.slice(0, 8);
      if (merges.length === 0) {
        slot.innerHTML = `
          <div class="brief-empty">
            No ships in recent ambient. As PRs merge they'll surface here.
            <br><br>
            <em>Want a different signal? Tell me what "release notes" means
            to you — last 7 days? merged PRs by domain? a curated weekly
            summary? Tell me the shape and we'll wire it.</em>
          </div>`;
        return;
      }
      slot.innerHTML = merges.map((e) => {
        const ts = e.ts ? new Date(e.ts) : null;
        const pr = e.pr_number ? `#${e.pr_number}` : '';
        const title = this.#escape(e.title || e.subject || e.gap || e.kind || 'ship');
        const ago = this.#ago(ts);
        const href = e.pr_number
          ? `https://github.com/repairman29/chump/pull/${e.pr_number}`
          : '#';
        return `
          <div class="brief-item">
            <span class="brief-pill ship-pr">SHIPPED</span>
            <div class="brief-body">
              <div class="brief-title">${title}</div>
              <div class="brief-meta">
                ${pr ? `<a href="${href}" target="_blank" rel="noopener">${pr}</a> · ` : ''}${ago}
              </div>
            </div>
          </div>`;
      }).join('');
    } catch (e) {
      slot.innerHTML = `
        <div class="brief-empty">
          Couldn't load release notes (${this.#escape(String(e.message || e))}).
        </div>`;
    }
  }

  // ── Where we're headed — top-priority pickable gaps from the queue ────────
  async #loadRoadmap() {
    const slot = this.#shadow.getElementById('slot-roadmap');
    if (!slot) return;
    try {
      const r = await fetch('/api/gap-queue');
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const d = await r.json();
      const gaps = (d.gaps || [])
        .filter((g) => (g.status || 'open') === 'open')
        .sort((a, b) => {
          const order = { P0: 0, P1: 1, P2: 2, P3: 3, P4: 4, P5: 5 };
          return (order[a.priority] ?? 9) - (order[b.priority] ?? 9);
        })
        .slice(0, 6);
      if (gaps.length === 0) {
        slot.innerHTML = `
          <div class="brief-empty">
            No pickable gaps in this fleet's queue right now.
            <br><br>
            <em>"Where we're headed" can also mean roadmap milestones, not
            just the next 6 gaps. Want me to surface
            <code>docs/product/PWA_ROADMAP.md</code> phases here instead?
            Or both — gaps as "this week" and milestones as "this quarter"?</em>
          </div>`;
        return;
      }
      slot.innerHTML = gaps.map((g) => {
        const pri = g.priority || 'P?';
        const id = this.#escape(g.id || '?');
        const title = this.#escape(g.title || '');
        const effort = g.effort ? `· ${this.#escape(g.effort)}` : '';
        return `
          <div class="brief-item">
            <span class="brief-pill priority-${pri}">${pri}</span>
            <div class="brief-body">
              <div class="brief-title">${title}</div>
              <div class="brief-meta">${id} ${effort}</div>
            </div>
          </div>`;
      }).join('');
    } catch (e) {
      slot.innerHTML = `
        <div class="brief-empty">
          Couldn't load priority queue (${this.#escape(String(e.message || e))}).
        </div>`;
    }
  }

  #escape(s) {
    return String(s || '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  #ago(ts) {
    if (!ts) return '';
    const ms = Date.now() - ts.getTime();
    if (ms < 60_000) return 'just now';
    if (ms < 3_600_000) return `${Math.floor(ms / 60_000)}m ago`;
    if (ms < 86_400_000) return `${Math.floor(ms / 3_600_000)}h ago`;
    return `${Math.floor(ms / 86_400_000)}d ago`;
  }
}

customElements.define('chump-view-cockpit', ChumpViewCockpit);

// ── URL bootstrap ──────────────────────────────────────────────────────────
// The chump-nav cadence router (app.js CHUMP_CADENCES) rewrites ?view=<x>
// to the cadence's default_view when <x> isn't in any cadence's subtabs.
// Since we don't promote cockpit into a cadence here (avoid colliding with
// 5 live leases on app.js), the router would otherwise redirect
// /v2/?view=cockpit → /v2/?view=chat&cadence=now.
//
// Workaround that doesn't touch app.js: read the *original* navigation URL
// from PerformanceNavigationTiming (which survives history.replaceState),
// and if it asked for view=cockpit OR the page is loaded with #cockpit,
// force-render the cockpit view into #main-content after the router has run.
function getOriginalUrl() {
  try {
    const nav = performance.getEntriesByType?.('navigation')?.[0];
    if (nav?.name) return new URL(nav.name);
  } catch {}
  return new URL(location.href);
}

function maybeRenderCockpit() {
  const origView   = getOriginalUrl().searchParams.get('view');
  const curView    = new URLSearchParams(location.search).get('view');
  const hashView   = location.hash === '#cockpit';
  if (origView !== 'cockpit' && curView !== 'cockpit' && !hashView) return;
  const main = document.getElementById('main-content');
  if (!main) return;
  if (main.querySelector('chump-view-cockpit')) return; // idempotent
  main.innerHTML = '';
  main.appendChild(document.createElement('chump-view-cockpit'));
  // Re-stamp the URL so a copy-paste / bookmark reflects what's on screen,
  // and the cadence router doesn't keep rewriting it on subsequent hops.
  try {
    const url = new URL(location.href);
    url.searchParams.set('view', 'cockpit');
    history.replaceState(null, '', url.toString());
  } catch {}
}

if (document.readyState === 'loading') {
  // Wait until DOMContentLoaded + a microtask so chump-nav's connectedCallback
  // (which rewrites the URL) has run first, then we steal the view back.
  document.addEventListener('DOMContentLoaded', () => setTimeout(maybeRenderCockpit, 50));
} else {
  setTimeout(maybeRenderCockpit, 50);
}
window.addEventListener('hashchange', maybeRenderCockpit);
