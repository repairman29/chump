// web/v2/cockpit.js — Sovereign Operator Cockpit (PRODUCT-122 / PRODUCT-128 / PRODUCT-372)
//
// Unified three-column operator command center aligned with the Warm-Stone,
// Sovereign Forest & Bronze design language of /site/ (and Warm-Obsidian dark mode).
//
// Combines:
//   - Executive 4-KPI telemetry strip (Gap Ledger, 24h Throughput & Leases,
//     Inference Cascade & Spend, 4-Pillar Posture & GitHub Budget)
//   - Left Zone: Synthesized Situation Read + Actionable Signal Cards (including
//     fleet wake/restart and drift repair actions)
//   - Center Zone: Live interactive Gap Queue (filter, search, 1-click Claim /
//     Dispatch, inline + Reserve Gap drawer) + Provider Cascade Slots + Active Leases
//   - Right Zone: Live Operations Advisor & Task Console (/api/advisor/ask +
//     /api/shortcut/task) + tabbed Fleet / Daemons / Triage / Ambient telemetry

const CSS = `
  :host {
    display: block;
    color: var(--text);
    background: var(--bg);
    font-family: var(--font-sans);
  }

  .cockpit-shell {
    max-width: 1520px;
    margin: 0 auto;
    padding: 20px 24px 28px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  /* ── Command Header Row ─────────────────────────────────────────────── */
  .cmd-header {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 16px;
    flex-wrap: wrap;
    padding-bottom: 14px;
    border-bottom: 1px solid var(--border);
  }
  .cmd-title-group {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .cmd-eyebrow {
    font-family: var(--font-mono);
    font-size: 10.5px;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--bronze);
    display: inline-flex;
    align-items: center;
    gap: 8px;
  }
  .cmd-heading-row {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }
  .cmd-heading {
    margin: 0;
    font-family: var(--font-display);
    font-size: 24px;
    font-weight: 600;
    letter-spacing: -0.025em;
    color: var(--text);
    line-height: 1.15;
  }
  .cmd-repo-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 10px;
    border-radius: 999px;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-secondary);
  }
  .cmd-controls {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }
  .autopilot-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 11px;
    border-radius: 999px;
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 600;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    color: var(--text-secondary);
  }
  .autopilot-pill.running {
    background: var(--tone-ok-bg);
    border-color: var(--tone-ok-border);
    color: var(--success);
  }
  .status-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: currentColor;
  }

  .btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    padding: 6px 13px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
    background: var(--bg-surface);
    color: var(--text);
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    text-decoration: none;
    transition: background 0.14s, border-color 0.14s, color 0.14s;
    white-space: nowrap;
  }
  .btn:hover {
    background: var(--bg-elevated);
    border-color: var(--border-strong);
  }
  .btn:disabled {
    opacity: 0.55;
    cursor: default;
  }
  .btn-primary {
    background: var(--accent);
    border-color: var(--accent);
    color: var(--on-accent);
    font-weight: 600;
  }
  .btn-primary:hover {
    filter: brightness(1.08);
    background: var(--accent);
    border-color: var(--accent);
  }
  .btn-bronze {
    background: var(--bronze-dim);
    border-color: var(--bronze-dim);
    color: var(--bronze);
    font-weight: 600;
  }
  .btn-bronze:hover {
    border-color: var(--bronze);
  }
  .btn-xs {
    padding: 3px 9px;
    font-size: 11px;
  }

  /* ── Inline Reserve-Gap Drawer ──────────────────────────────────────── */
  .reserve-drawer {
    background: var(--bg-surface);
    border: 1px solid var(--border-strong);
    border-left: 3px solid var(--accent);
    border-radius: var(--radius);
    padding: 14px 16px;
    box-shadow: var(--shadow-card);
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .reserve-drawer[hidden] { display: none; }
  .reserve-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
  }
  .reserve-title {
    font-family: var(--font-display);
    font-size: 14px;
    font-weight: 600;
    color: var(--text);
  }
  .reserve-grid {
    display: grid;
    grid-template-columns: 120px 95px 95px 140px 1fr auto;
    gap: 8px;
    align-items: center;
  }
  @media (max-width: 1100px) {
    .reserve-grid { grid-template-columns: 1fr 1fr; }
  }
  .field-input, .field-select {
    width: 100%;
    padding: 6px 10px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
    font-size: 12.5px;
  }
  .field-mono { font-family: var(--font-mono); font-size: 11.5px; }
  .reserve-feedback {
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: var(--text-secondary);
  }
  .reserve-feedback.ok  { color: var(--success); }
  .reserve-feedback.err { color: var(--error); }

  /* ── 4-KPI Executive Strip ──────────────────────────────────────────── */
  .kpi-strip {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 12px;
  }
  @media (max-width: 1100px) {
    .kpi-strip { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  }
  @media (max-width: 600px) {
    .kpi-strip { grid-template-columns: 1fr; }
  }
  .kpi-card {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 14px 16px;
    box-shadow: var(--shadow-card);
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .kpi-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }
  .kpi-label {
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--text-secondary);
  }
  .kpi-chip {
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 600;
    padding: 2px 7px;
    border-radius: 999px;
    background: var(--bg-elevated);
    color: var(--text-secondary);
  }
  .kpi-chip.ok   { background: var(--tone-ok-bg); color: var(--success); }
  .kpi-chip.warn { background: var(--tone-warn-bg); color: var(--warn); }
  .kpi-chip.err  { background: var(--tone-err-bg); color: var(--error); }
  .kpi-value-row {
    display: flex;
    align-items: baseline;
    gap: 10px;
  }
  .kpi-value {
    font-family: var(--font-display);
    font-size: 28px;
    font-weight: 700;
    letter-spacing: -0.03em;
    line-height: 1.05;
    color: var(--text);
    font-variant-numeric: tabular-nums;
  }
  .kpi-unit {
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: var(--text-secondary);
  }
  .kpi-sub {
    font-size: 11.5px;
    color: var(--text-secondary);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-top: auto;
    padding-top: 4px;
  }
  .kpi-link {
    background: none;
    border: none;
    padding: 0;
    color: var(--accent);
    font-size: 11.5px;
    font-weight: 600;
    cursor: pointer;
  }
  .kpi-link:hover { text-decoration: underline; }

  .pillar-mini-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 6px;
    margin-top: 2px;
  }
  .pillar-cell {
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    padding: 4px 6px;
    display: flex;
    flex-direction: column;
    align-items: center;
  }
  .pillar-code {
    font-family: var(--font-mono);
    font-size: 9px;
    color: var(--text-secondary);
  }
  .pillar-grade {
    font-family: var(--font-mono);
    font-size: 14px;
    font-weight: 700;
    color: var(--text);
  }
  .pillar-grade.grade-A { color: var(--success); }
  .pillar-grade.grade-B { color: var(--accent); }
  .pillar-grade.grade-C { color: var(--warn); }
  .pillar-grade.grade-F { color: var(--error); }

  /* ── 3-Column Sovereign Workbench ───────────────────────────────────── */
  .workbench {
    display: grid;
    grid-template-columns: minmax(300px, 0.92fr) minmax(430px, 1.38fr) minmax(320px, 1fr);
    gap: 14px;
    align-items: start;
  }
  @media (max-width: 1220px) {
    .workbench {
      grid-template-columns: 1fr 1fr;
    }
    .col-right {
      grid-column: 1 / -1;
    }
  }
  @media (max-width: 820px) {
    .workbench {
      grid-template-columns: 1fr;
    }
  }

  .panel {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    box-shadow: var(--shadow-card);
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
  .panel-head {
    padding: 12px 16px;
    border-bottom: 1px solid var(--border);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    flex-wrap: wrap;
  }
  .panel-title {
    font-family: var(--font-display);
    font-size: 14px;
    font-weight: 600;
    letter-spacing: -0.01em;
    color: var(--text);
  }
  .panel-eyebrow {
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-secondary);
  }
  .panel-body {
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  /* ── Left Zone: Situation Read + Signal Cards ───────────────────────── */
  .intel-read {
    padding: 13px 14px;
    border-radius: var(--radius-sm);
    background: var(--accent-dim);
    border: 1px solid var(--border);
    border-left: 3px solid var(--accent);
  }
  .intel-read-label {
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.07em;
    color: var(--accent);
    text-transform: uppercase;
    margin-bottom: 5px;
  }
  .intel-read-text {
    font-size: 13.5px;
    font-weight: 500;
    line-height: 1.45;
    color: var(--text);
  }
  .intel-read-meta {
    margin-top: 8px;
    font-family: var(--font-mono);
    font-size: 10.5px;
    color: var(--text-secondary);
    display: flex;
    gap: 8px;
    align-items: center;
    flex-wrap: wrap;
  }
  .intel-confidence {
    display: inline-flex;
    align-items: center;
    gap: 5px;
  }
  .intel-confidence-dot {
    display: inline-block;
    width: 7px;
    height: 7px;
    border-radius: 50%;
  }
  .intel-confidence-dot.high   { background: var(--success); }
  .intel-confidence-dot.medium { background: var(--warn); }
  .intel-confidence-dot.low    { background: var(--bronze); }
  .intel-read-evidence {
    background: none;
    border: none;
    padding: 0;
    color: var(--accent);
    cursor: pointer;
    font-family: var(--font-mono);
    font-size: 10.5px;
    text-decoration: underline;
  }

  .intel-signal {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .intel-card {
    padding: 11px 12px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--bg);
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .intel-card.counter {
    border-left: 3px solid var(--bronze);
  }
  .intel-card-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }
  .intel-tag {
    font-family: var(--font-mono);
    font-size: 9.5px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 2px 6px;
    border-radius: 4px;
    background: var(--bg-elevated);
    color: var(--text-secondary);
  }
  .intel-tag.bronze { background: var(--bronze-dim); color: var(--bronze); }
  .intel-card-title {
    font-size: 12.5px;
    font-weight: 600;
    color: var(--text);
    line-height: 1.35;
  }
  .intel-card-detail {
    font-size: 12px;
    color: var(--text-secondary);
    line-height: 1.45;
  }
  .intel-card-actions {
    display: flex;
    gap: 6px;
    align-items: center;
    flex-wrap: wrap;
    margin-top: 2px;
  }
  .intel-card-btn {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 4px 9px;
    border-radius: var(--radius-sm);
    font-size: 11px;
    font-weight: 500;
    cursor: pointer;
    white-space: nowrap;
  }
  .intel-card-btn:hover {
    background: var(--bg-elevated);
    border-color: var(--border-strong);
  }
  .intel-card-btn.primary {
    background: var(--accent);
    color: var(--on-accent);
    border-color: var(--accent);
    font-weight: 600;
  }
  .intel-card-btn.wrong {
    margin-left: auto;
    color: var(--text-secondary);
    font-family: var(--font-mono);
    font-size: 10px;
    padding: 3px 7px;
  }
  .intel-card-btn.wrong:hover {
    color: var(--error);
    border-color: var(--tone-err-border);
  }

  .intel-noise {
    border-top: 1px solid var(--border);
    padding-top: 10px;
  }
  .intel-noise-toggle {
    background: none;
    border: none;
    color: var(--text-secondary);
    font-family: var(--font-mono);
    font-size: 11px;
    cursor: pointer;
    padding: 0;
    text-align: left;
    width: 100%;
  }
  .intel-noise-toggle:hover { color: var(--accent); }
  .intel-noise-body {
    margin-top: 8px;
    max-height: 180px;
    overflow: auto;
    font-family: var(--font-mono);
    font-size: 10.5px;
    color: var(--text-secondary);
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    padding: 6px 8px;
    display: none;
  }
  .intel-noise-body.open { display: block; }
  .intel-noise-event {
    padding: 3px 0;
    border-bottom: 1px solid var(--border);
  }
  .intel-noise-event:last-child { border-bottom: none; }

  /* ── Center Zone: Workbench Tabs (Gap Queue / Cascade / Leases) ─────── */
  .seg-tabs {
    display: inline-flex;
    align-items: center;
    gap: 2px;
    padding: 2px;
    border-radius: var(--radius-sm);
    background: var(--bg-elevated);
    border: 1px solid var(--border);
  }
  .seg-tab {
    border: none;
    background: transparent;
    color: var(--text-secondary);
    font-size: 11.5px;
    font-weight: 600;
    padding: 4px 10px;
    border-radius: 4px;
    cursor: pointer;
    white-space: nowrap;
  }
  .seg-tab[aria-selected="true"] {
    background: var(--bg-surface);
    color: var(--accent);
    box-shadow: var(--shadow-card);
  }

  .queue-toolbar {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }
  .queue-search {
    flex: 1 1 160px;
    padding: 6px 10px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
    font-size: 12px;
  }
  .filter-pills {
    display: inline-flex;
    gap: 4px;
    flex-wrap: wrap;
  }
  .filter-pill {
    padding: 4px 9px;
    border-radius: 999px;
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text-secondary);
    font-family: var(--font-mono);
    font-size: 10.5px;
    font-weight: 500;
    cursor: pointer;
  }
  .filter-pill.active {
    background: var(--accent-dim);
    border-color: var(--accent);
    color: var(--accent);
    font-weight: 600;
  }

  .queue-rows {
    display: flex;
    flex-direction: column;
    gap: 8px;
    max-height: 460px;
    overflow-y: auto;
  }
  .q-row {
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--bg);
    padding: 10px 12px;
    display: flex;
    flex-direction: column;
    gap: 5px;
    transition: border-color 0.12s;
  }
  .q-row:hover { border-color: var(--border-strong); }
  .q-row-head {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }
  .q-id {
    font-family: var(--font-mono);
    font-size: 11.5px;
    font-weight: 600;
    color: var(--text);
  }
  .q-prio {
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 600;
    padding: 1px 6px;
    border-radius: 4px;
    background: var(--bg-elevated);
    color: var(--text-secondary);
  }
  .q-prio.prio-high {
    background: var(--bronze-dim);
    color: var(--bronze);
  }
  .q-status {
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 600;
    padding: 1px 7px;
    border-radius: 999px;
    background: var(--tone-ok-bg);
    color: var(--success);
  }
  .q-status.leased {
    background: var(--tone-warn-bg);
    color: var(--warn);
  }
  .q-domain {
    font-family: var(--font-mono);
    font-size: 10px;
    color: var(--text-secondary);
  }
  .q-title {
    font-size: 12.5px;
    color: var(--text);
    line-height: 1.4;
  }
  .q-foot {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    flex-wrap: wrap;
    margin-top: 2px;
  }
  .q-lease-meta {
    font-family: var(--font-mono);
    font-size: 10.5px;
    color: var(--bronze);
  }
  .q-actions {
    display: inline-flex;
    gap: 6px;
    margin-left: auto;
  }

  /* Cascade table */
  .data-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 12px;
  }
  .data-table th {
    text-align: left;
    padding: 7px 8px;
    border-bottom: 1px solid var(--border);
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-secondary);
  }
  .data-table td {
    padding: 8px;
    border-bottom: 1px solid var(--border);
    font-variant-numeric: tabular-nums;
  }
  .data-table tr:last-child td { border-bottom: none; }
  .mono-cell { font-family: var(--font-mono); font-size: 11.5px; }

  .empty-box {
    padding: 18px 14px;
    text-align: center;
    color: var(--text-secondary);
    font-size: 12px;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
  }

  /* ── Right Zone: Advisor Console + Live Telemetry ───────────────────── */
  .col-right {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .advisor-form {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .advisor-textarea {
    width: 100%;
    min-height: 68px;
    max-height: 160px;
    resize: vertical;
    padding: 8px 10px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
    font-size: 12.5px;
    line-height: 1.45;
  }
  .advisor-textarea:focus {
    outline: 2px solid var(--accent);
    outline-offset: 1px;
  }
  .advisor-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    flex-wrap: wrap;
  }
  .advisor-hint {
    font-family: var(--font-mono);
    font-size: 10.5px;
    color: var(--text-secondary);
  }
  .advisor-reply {
    padding: 10px 12px;
    border-radius: var(--radius-sm);
    background: var(--bg);
    border: 1px solid var(--border);
    font-size: 12.5px;
    line-height: 1.5;
    color: var(--text);
    max-height: 210px;
    overflow-y: auto;
    white-space: pre-wrap;
  }
  .advisor-reply[hidden] { display: none; }

  .right-actions {
    padding: 10px 12px;
    background: var(--accent-dim);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    display: flex;
    gap: 10px;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
  }
  .right-actions[hidden] { display: none; }
  .right-actions-text {
    font-size: 12px;
    color: var(--text);
    flex: 1 1 auto;
  }
  .right-actions-text strong {
    color: var(--accent);
    font-weight: 600;
  }
  .right-actions-btn {
    background: var(--accent);
    color: var(--on-accent);
    border: none;
    border-radius: var(--radius-sm);
    padding: 5px 11px;
    font-size: 11.5px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
  }

  .telem-pane[hidden] { display: none; }
  .triage-section {
    padding-top: 10px;
    margin-top: 10px;
    border-top: 1px solid var(--border);
  }
  .triage-section:first-child {
    padding-top: 0;
    margin-top: 0;
    border-top: none;
  }
  .triage-label {
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-secondary);
    margin-bottom: 6px;
  }
`;

class ChumpViewCockpit extends HTMLElement {
  #shadow;
  #centerTab = 'queue';
  #queueFilter = 'all';
  #queueQuery = '';
  #telemTab = 'fleet';
  #ambientMounted = false;
  #latestInputs = null;
  #pollTimer = null;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#renderShell();
    this.#refreshAll();
    this.#pollTimer = setInterval(() => this.#refreshAll(), 30_000);
  }

  disconnectedCallback() {
    if (this.#pollTimer) clearInterval(this.#pollTimer);
  }

  #renderShell() {
    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="cockpit-shell" role="region" aria-label="Operator Cockpit">
        <!-- Command Header -->
        <header class="cmd-header">
          <div class="cmd-title-group">
            <span class="cmd-eyebrow">Sovereign Fleet Command</span>
            <div class="cmd-heading-row">
              <h1 class="cmd-heading">Operator Cockpit</h1>
              <span class="cmd-repo-pill" id="cmd-repo-pill">repo: detecting…</span>
            </div>
          </div>
          <div class="cmd-controls">
            <span class="autopilot-pill" id="cmd-autopilot-pill">
              <span class="status-dot"></span>
              <span id="cmd-autopilot-label">Autopilot: Parked</span>
            </span>
            <button type="button" class="btn btn-primary" id="cmd-fleet-cta" data-action-view="wake-fleet">Wake fleet</button>
            <button type="button" class="btn btn-bronze" id="cmd-reserve-toggle" aria-expanded="false">+ Reserve Gap</button>
            <button type="button" class="btn" id="cmd-refresh-btn" title="Refresh live telemetry">Refresh</button>
          </div>
        </header>

        <!-- Inline Gap Reservation Drawer (POST /api/gap) -->
        <section class="reserve-drawer" id="reserve-drawer" hidden aria-label="Reserve new gap">
          <div class="reserve-head">
            <span class="reserve-title">Reserve Verified Gap in state.db</span>
            <button type="button" class="btn btn-xs" id="reserve-close-btn">Close</button>
          </div>
          <form class="reserve-grid" id="reserve-form">
            <select class="field-select field-mono" id="res-domain" aria-label="Gap domain">
              <option value="PRODUCT">PRODUCT</option>
              <option value="INFRA">INFRA</option>
              <option value="RESILIENT">RESILIENT</option>
              <option value="CREDIBLE">CREDIBLE</option>
              <option value="EFFECTIVE">EFFECTIVE</option>
            </select>
            <select class="field-select field-mono" id="res-priority" aria-label="Priority">
              <option value="P2">P2</option>
              <option value="P1">P1</option>
              <option value="P0">P0</option>
              <option value="P3">P3</option>
            </select>
            <select class="field-select field-mono" id="res-effort" aria-label="Effort">
              <option value="s">effort: s</option>
              <option value="xs">effort: xs</option>
              <option value="m" selected>effort: m</option>
              <option value="l">effort: l</option>
            </select>
            <input type="text" class="field-input field-mono" id="res-outcome" value="MISSION-010" placeholder="Outcome ID" aria-label="Outcome ID">
            <input type="text" class="field-input" id="res-title" placeholder="Concise engineering title (1–200 chars)…" required maxlength="200" aria-label="Gap title">
            <button type="submit" class="btn btn-primary" id="res-submit-btn">Create Gap</button>
          </form>
          <div class="reserve-feedback" id="reserve-feedback">Collision-safe reservation via GapStore::reserve_verified (P0/P1 linked to MISSION-010).</div>
        </section>

        <!-- 4-Card Executive Metric Strip -->
        <section class="kpi-strip" aria-label="Executive metrics">
          <article class="kpi-card">
            <div class="kpi-top">
              <span class="kpi-label">Gap Ledger · state.db</span>
              <span class="kpi-chip ok" id="kpi-drift-chip">0 drift</span>
            </div>
            <div class="kpi-value-row">
              <span class="kpi-value" id="kpi-open-gaps">—</span>
              <span class="kpi-unit" id="kpi-claimable-unit">open</span>
            </div>
            <div class="kpi-sub">
              <span id="kpi-gap-sub">Loading registry…</span>
              <button type="button" class="kpi-link" data-nav="agent">Full queue →</button>
            </div>
          </article>

          <article class="kpi-card">
            <div class="kpi-top">
              <span class="kpi-label">24h Ships &amp; Leases</span>
              <span class="kpi-chip" id="kpi-lease-chip">0 leases</span>
            </div>
            <div class="kpi-value-row">
              <span class="kpi-value" id="kpi-ships-today">0</span>
              <span class="kpi-unit">merged (24h)</span>
            </div>
            <div class="kpi-sub">
              <span id="kpi-ci-sub">CI telemetry idle</span>
              <button type="button" class="kpi-link" data-nav="prs">Pull requests →</button>
            </div>
          </article>

          <article class="kpi-card">
            <div class="kpi-top">
              <span class="kpi-label">Cascade &amp; Spend</span>
              <span class="kpi-chip ok" id="kpi-posture-chip">network</span>
            </div>
            <div class="kpi-value-row">
              <span class="kpi-value" id="kpi-cost-today">$0.00</span>
              <span class="kpi-unit" id="kpi-slots-unit">session</span>
            </div>
            <div class="kpi-sub">
              <span id="kpi-model-sub">Probing provider cascade…</span>
              <button type="button" class="kpi-link" data-nav="models">Cascade →</button>
            </div>
          </article>

          <article class="kpi-card">
            <div class="kpi-top">
              <span class="kpi-label">4-Pillar Posture</span>
              <span class="kpi-chip ok" id="kpi-gh-chip">GH —</span>
            </div>
            <div class="pillar-mini-grid" id="kpi-pillars-grid">
              <div class="pillar-cell"><span class="pillar-code">EFF</span><span class="pillar-grade">—</span></div>
              <div class="pillar-cell"><span class="pillar-code">CRED</span><span class="pillar-grade">—</span></div>
              <div class="pillar-cell"><span class="pillar-code">RES</span><span class="pillar-grade">—</span></div>
              <div class="pillar-cell"><span class="pillar-code">ZERO</span><span class="pillar-grade">—</span></div>
            </div>
            <div class="kpi-sub">
              <span id="kpi-pillar-sub">SLO check</span>
              <button type="button" class="kpi-link" data-nav="health">Vitals →</button>
            </div>
          </article>
        </section>

        <!-- 3-Column Sovereign Workbench -->
        <div class="workbench">
          <!-- Column 1: Situation Read + Signal -->
          <section class="panel" aria-label="Operational synthesis">
            <div class="panel-head">
              <div>
                <div class="panel-eyebrow">Synthesis</div>
                <div class="panel-title">Situation Read &amp; Signal</div>
              </div>
            </div>
            <div class="panel-body">
              <section class="intel-read" id="intel-read" aria-label="The read">
                <div class="intel-read-label">Current Read</div>
                <div class="intel-read-text" id="intel-read-text">Synthesizing live repository and ambient state…</div>
                <div class="intel-read-meta" id="intel-read-meta"></div>
              </section>

              <section class="intel-signal" id="intel-cards" aria-label="Signal">
                <div class="empty-box">Extracting operational signal…</div>
              </section>

              <section class="intel-noise" aria-label="Event evidence">
                <button type="button" class="intel-noise-toggle" id="intel-noise-toggle" aria-expanded="false">
                  ▶ <span id="intel-noise-count">0</span> ambient events in synthesis window
                </button>
                <div class="intel-noise-body" id="intel-noise-body"></div>
              </section>
            </div>
          </section>

          <!-- Column 2: Interactive Gap Queue / Cascade / Leases Workbench -->
          <section class="panel" aria-label="Dispatch workbench">
            <div class="panel-head">
              <div>
                <div class="panel-eyebrow">Execution Ledger</div>
                <div class="panel-title">Queue, Cascade &amp; Leases</div>
              </div>
              <div class="seg-tabs" role="tablist" aria-label="Workbench view">
                <button type="button" class="seg-tab" role="tab" data-wb-tab="queue" aria-selected="true" id="wb-tab-queue">Queue</button>
                <button type="button" class="seg-tab" role="tab" data-wb-tab="cascade" aria-selected="false" id="wb-tab-cascade">Cascade</button>
                <button type="button" class="seg-tab" role="tab" data-wb-tab="leases" aria-selected="false" id="wb-tab-leases">Leases</button>
              </div>
            </div>
            <div class="panel-body">
              <!-- Queue Pane -->
              <div id="wb-pane-queue">
                <div class="queue-toolbar">
                  <input type="search" class="queue-search" id="wb-queue-search" placeholder="Filter by gap ID, domain, or title…" aria-label="Filter gap queue">
                  <div class="filter-pills" id="wb-filter-pills">
                    <button type="button" class="filter-pill active" data-qfilter="all">All</button>
                    <button type="button" class="filter-pill" data-qfilter="claimable">Claimable</button>
                    <button type="button" class="filter-pill" data-qfilter="high">P0 / P1</button>
                    <button type="button" class="filter-pill" data-qfilter="leased">Leased</button>
                  </div>
                </div>
                <div class="queue-rows" id="wb-queue-rows" style="margin-top:10px;">
                  <div class="empty-box">Loading gap queue…</div>
                </div>
              </div>

              <!-- Cascade Pane -->
              <div id="wb-pane-cascade" hidden>
                <div id="wb-cascade-content">
                  <div class="empty-box">Loading provider cascade slots…</div>
                </div>
              </div>

              <!-- Leases Pane -->
              <div id="wb-pane-leases" hidden>
                <div id="wb-leases-content">
                  <div class="empty-box">Loading active file leases…</div>
                </div>
              </div>
            </div>
          </section>

          <!-- Column 3: Advisor Console + Live Fleet/Daemon/Triage/Ambient -->
          <div class="col-right">
            <section class="panel" aria-label="Operations Advisor">
              <div class="panel-head">
                <div>
                  <div class="panel-eyebrow">Direct Command</div>
                  <div class="panel-title">Advisor &amp; Quick Task</div>
                </div>
                <button type="button" class="btn btn-xs" data-nav="chat">Full Chat →</button>
              </div>
              <div class="panel-body">
                <form class="advisor-form" id="advisor-form">
                  <textarea class="advisor-textarea" id="advisor-input" placeholder="Ask Operations Advisor about repo state, or prefix with /task to queue work…"></textarea>
                  <div class="advisor-bar">
                    <span class="advisor-hint">Uses shared ProviderCascade</span>
                    <button type="submit" class="btn btn-primary btn-xs" id="advisor-submit">Send</button>
                  </div>
                </form>
                <div class="advisor-reply" id="advisor-reply" hidden></div>
              </div>
            </section>

            <section class="panel" aria-label="Fleet and daemon telemetry">
              <div class="panel-head">
                <div>
                  <div class="panel-eyebrow">Live Runtime</div>
                  <div class="panel-title">Fleet &amp; Daemons</div>
                </div>
                <div class="seg-tabs" role="tablist" aria-label="Telemetry view">
                  <button type="button" class="seg-tab" role="tab" data-telem-tab="fleet" aria-selected="true">Fleet</button>
                  <button type="button" class="seg-tab" role="tab" data-telem-tab="daemons" aria-selected="false">Daemons</button>
                  <button type="button" class="seg-tab" role="tab" data-telem-tab="triage" aria-selected="false">Triage</button>
                  <button type="button" class="seg-tab" role="tab" data-telem-tab="ambient" aria-selected="false">Ambient</button>
                </div>
              </div>
              <div class="panel-body">
                <div class="right-actions" id="right-actions" hidden></div>

                <div class="telem-pane" id="telem-pane-fleet">
                  <div id="slot-fleet"></div>
                </div>

                <div class="telem-pane" id="telem-pane-daemons" hidden>
                  <div id="slot-daemon-set"></div>
                </div>

                <div class="telem-pane" id="telem-pane-triage" hidden>
                  <div class="triage-section">
                    <div class="triage-label">Stuck Items</div>
                    <div id="slot-stuck"></div>
                  </div>
                  <div class="triage-section">
                    <div class="triage-label">Operator Attention</div>
                    <div id="slot-attention"></div>
                  </div>
                  <div class="triage-section">
                    <div class="triage-label">Agent Inbox</div>
                    <div id="slot-inbox"></div>
                  </div>
                </div>

                <div class="telem-pane" id="telem-pane-ambient" hidden>
                  <div id="slot-wedge-watch"></div>
                  <div id="slot-ambient" style="margin-top:10px;"></div>
                </div>
              </div>
            </section>
          </div>
        </div>
      </div>
    `;

    // Mount primary Fleet panel immediately; mount Daemons / Triage / Ambient lazily on tab select.
    this.#mount('slot-fleet', 'chump-fleet-sidebar');

    this.#wireInteractions();
  }

  #mount(slotId, tagName) {
    const slot = this.#shadow.getElementById(slotId);
    if (!slot || slot.children.length > 0) return;
    try {
      slot.appendChild(document.createElement(tagName));
    } catch {
      slot.innerHTML = `<div class="empty-box">${this.#escape(tagName)} unavailable</div>`;
    }
  }

  #wireInteractions() {
    // Navigation links.
    this.#shadow.querySelectorAll('[data-nav]').forEach((el) => {
      el.addEventListener('click', () => {
        const target = el.dataset.nav;
        if (target) {
          document.dispatchEvent(new CustomEvent('chump:navigate', { detail: target }));
        }
      });
    });

    // Header Refresh + Fleet CTA + Reserve drawer toggle.
    this.#shadow.getElementById('cmd-refresh-btn')?.addEventListener('click', () => {
      this.#refreshAll();
    });
    this.#shadow.getElementById('cmd-fleet-cta')?.addEventListener('click', (e) => {
      this.#onCardAction(e.currentTarget);
    });

    const reserveDrawer = this.#shadow.getElementById('reserve-drawer');
    const reserveToggle = this.#shadow.getElementById('cmd-reserve-toggle');
    const toggleReserve = (force) => {
      if (!reserveDrawer || !reserveToggle) return;
      const open = typeof force === 'boolean' ? force : reserveDrawer.hasAttribute('hidden');
      if (open) {
        reserveDrawer.removeAttribute('hidden');
        reserveToggle.setAttribute('aria-expanded', 'true');
        this.#shadow.getElementById('res-title')?.focus();
      } else {
        reserveDrawer.setAttribute('hidden', '');
        reserveToggle.setAttribute('aria-expanded', 'false');
      }
    };
    reserveToggle?.addEventListener('click', () => toggleReserve());
    this.#shadow.getElementById('reserve-close-btn')?.addEventListener('click', () => toggleReserve(false));

    // Reserve Gap form submission -> POST /api/gap
    this.#shadow.getElementById('reserve-form')?.addEventListener('submit', async (e) => {
      e.preventDefault();
      const submitBtn = this.#shadow.getElementById('res-submit-btn');
      const fb = this.#shadow.getElementById('reserve-feedback');
      const domain = this.#shadow.getElementById('res-domain')?.value || 'PRODUCT';
      const priority = this.#shadow.getElementById('res-priority')?.value || 'P2';
      const effort = this.#shadow.getElementById('res-effort')?.value || 'm';
      const outcome_id = (this.#shadow.getElementById('res-outcome')?.value || '').trim();
      const titleInput = this.#shadow.getElementById('res-title');
      const title = (titleInput?.value || '').trim();
      if (!title) return;

      if (submitBtn) submitBtn.disabled = true;
      if (fb) {
        fb.className = 'reserve-feedback';
        fb.textContent = 'Reserving gap in state.db…';
      }
      try {
        const payload = { domain, title, priority, effort };
        if (outcome_id) payload.outcome_id = outcome_id;
        const r = await fetch('/api/gap', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'pwa' },
          body: JSON.stringify(payload),
        });
        const d = await r.json().catch(() => ({}));
        if (!r.ok || d.error) {
          throw new Error(d.error || `HTTP ${r.status}`);
        }
        const createdId = d.id || d.gap_id || 'gap';
        if (fb) {
          fb.className = 'reserve-feedback ok';
          fb.textContent = `Reserved ${createdId} in state.db.`;
        }
        if (titleInput) titleInput.value = '';
        await this.#refreshAll();
      } catch (err) {
        if (fb) {
          fb.className = 'reserve-feedback err';
          fb.textContent = `Reservation refused: ${err.message || err}`;
        }
      } finally {
        if (submitBtn) submitBtn.disabled = false;
      }
    });

    // Center workbench segmented tabs.
    this.#shadow.querySelectorAll('[data-wb-tab]').forEach((btn) => {
      btn.addEventListener('click', () => {
        this.#centerTab = btn.dataset.wbTab || 'queue';
        this.#shadow.querySelectorAll('[data-wb-tab]').forEach((b) => {
          b.setAttribute('aria-selected', String(b === btn));
        });
        ['queue', 'cascade', 'leases'].forEach((id) => {
          const pane = this.#shadow.getElementById(`wb-pane-${id}`);
          if (pane) pane.hidden = id !== this.#centerTab;
        });
      });
    });

    // Queue search & filter pills.
    this.#shadow.getElementById('wb-queue-search')?.addEventListener('input', (e) => {
      this.#queueQuery = (e.target.value || '').trim().toLowerCase();
      if (this.#latestInputs) this.#renderQueueWorkbench(this.#latestInputs.queue);
    });
    this.#shadow.querySelectorAll('[data-qfilter]').forEach((pill) => {
      pill.addEventListener('click', () => {
        this.#queueFilter = pill.dataset.qfilter || 'all';
        this.#shadow.querySelectorAll('[data-qfilter]').forEach((p) => {
          p.classList.toggle('active', p === pill);
        });
        if (this.#latestInputs) this.#renderQueueWorkbench(this.#latestInputs.queue);
      });
    });

    // Right-column telemetry segmented tabs.
    this.#shadow.querySelectorAll('[data-telem-tab]').forEach((btn) => {
      btn.addEventListener('click', () => {
        this.#telemTab = btn.dataset.telemTab || 'fleet';
        this.#shadow.querySelectorAll('[data-telem-tab]').forEach((b) => {
          b.setAttribute('aria-selected', String(b === btn));
        });
        ['fleet', 'daemons', 'triage', 'ambient'].forEach((id) => {
          const pane = this.#shadow.getElementById(`telem-pane-${id}`);
          if (pane) pane.hidden = id !== this.#telemTab;
        });
        if (this.#telemTab === 'daemons') {
          this.#mount('slot-daemon-set', 'chump-daemon-set-panel');
        } else if (this.#telemTab === 'triage') {
          this.#mount('slot-stuck', 'chump-stuck-items');
          this.#mount('slot-attention', 'chump-operator-attention');
          this.#mount('slot-inbox', 'chump-inbox');
        } else if (this.#telemTab === 'ambient' && !this.#ambientMounted) {
          this.#ambientMounted = true;
          this.#mount('slot-wedge-watch', 'chump-wedge-watch');
          this.#mount('slot-ambient', 'chump-ambient-viewer');
        }
      });
    });

    // Noise toggle.
    const noiseToggle = this.#shadow.getElementById('intel-noise-toggle');
    const noiseBody = this.#shadow.getElementById('intel-noise-body');
    noiseToggle?.addEventListener('click', () => {
      const open = noiseBody.classList.toggle('open');
      noiseToggle.setAttribute('aria-expanded', String(open));
      if (noiseToggle.firstChild) noiseToggle.firstChild.textContent = open ? '▼ ' : '▶ ';
    });

    // Advisor / Quick Task form.
    this.#shadow.getElementById('advisor-form')?.addEventListener('submit', async (e) => {
      e.preventDefault();
      const input = this.#shadow.getElementById('advisor-input');
      const submit = this.#shadow.getElementById('advisor-submit');
      const replyBox = this.#shadow.getElementById('advisor-reply');
      const text = (input?.value || '').trim();
      if (!text || !replyBox) return;

      if (submit) {
        submit.disabled = true;
        submit.textContent = 'Running…';
      }
      replyBox.removeAttribute('hidden');
      replyBox.textContent = 'Routing via ProviderCascade…';

      try {
        if (text.startsWith('/task ')) {
          const title = text.slice(6).trim();
          const r = await fetch('/api/shortcut/task', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ title }),
          });
          const d = await r.json().catch(() => ({}));
          if (!r.ok) throw new Error(d.error || `HTTP ${r.status}`);
          replyBox.textContent = d.message || `Task created: ${title}`;
          if (input) input.value = '';
        } else {
          const r = await fetch('/api/advisor/ask', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text }),
          });
          if (!r.ok) throw new Error(`HTTP ${r.status}`);
          const d = await r.json();
          replyBox.textContent = d.reply || '(empty response)';
        }
      } catch (err) {
        replyBox.textContent = `Advisor request failed (${err.message || err}). Open Full Chat to inspect provider status.`;
      } finally {
        if (submit) {
          submit.disabled = false;
          submit.textContent = 'Send';
        }
      }
    });
  }

  async #refreshAll() {
    await this.#synthesize();
  }

  async #synthesize() {
    // Phase 1: Fast <60ms local SQLite/in-memory endpoints — paint immediately!
    const fast = await this.#fetchFastInputs();
    const merged = {
      ...(this.#latestInputs || { autopilot: null, driftStatus: null, stack: {}, pillars: {} }),
      ...fast,
    };
    this.#latestInputs = merged;
    this.#paintAll(merged);

    // Phase 2: Slow subprocess-backed endpoints — enrich in background without blocking paint.
    this.#fetchSlowInputs().then((slow) => {
      if (!this.isConnected) return;
      this.#latestInputs = { ...(this.#latestInputs || merged), ...slow };
      this.#paintAll(this.#latestInputs);
    }).catch(() => {});
  }

  #paintAll(inputs) {
    this.#renderKpis(inputs);
    const synth = this.#computeSynthesis(inputs);
    this.#renderRead(synth.read, synth.confidence, synth.evidenceCount);
    this.#renderSignal(synth.cards);
    this.#renderNoise(inputs.events);
    this.#renderQueueWorkbench(inputs.queue);
    this.#renderCascadeWorkbench(inputs.slots, inputs.stack);
    this.#renderLeasesWorkbench(inputs.summary);
    this.#renderRightZoneAction(inputs);
  }

  async #fetchFastInputs() {
    const [eventsR, queueR, summaryR, costR, slotsR, repoR] = await Promise.allSettled([
      fetch('/api/ambient/recent?limit=80'),
      fetch('/api/gap-queue'),
      fetch('/api/dashboard-summary'),
      fetch('/api/telemetry/cost'),
      fetch('/api/slots'),
      fetch('/api/repo/context'),
    ]);

    const jsonOr = async (settled, fallback) => {
      try {
        if (settled.status === 'fulfilled' && settled.value.ok) {
          return await settled.value.json();
        }
      } catch {}
      return fallback;
    };

    const eventsDoc = await jsonOr(eventsR, {});
    const queueDoc = await jsonOr(queueR, {});
    const summary = await jsonOr(summaryR, {});
    const cost = await jsonOr(costR, {});
    const slotsDoc = await jsonOr(slotsR, {});
    const repo = await jsonOr(repoR, {});

    return {
      events: Array.isArray(eventsDoc.events) ? eventsDoc.events : [],
      queue: Array.isArray(queueDoc.gaps) ? queueDoc.gaps : [],
      claimableCount: queueDoc.claimable_count ?? null,
      summary: summary || {},
      cost: cost || {},
      slots: Array.isArray(slotsDoc.slots) ? slotsDoc.slots : [],
      repo: repo || {},
    };
  }

  async #fetchSlowInputs() {
    const [autopilotR, driftR, stackR, pillarsR] = await Promise.allSettled([
      fetch('/api/autopilot/status'),
      fetch('/api/gap/drift-status'),
      fetch('/api/stack-status'),
      fetch('/api/health/pillars'),
    ]);

    const jsonOr = async (settled, fallback) => {
      try {
        if (settled.status === 'fulfilled' && settled.value.ok) {
          return await settled.value.json();
        }
      } catch {}
      return fallback;
    };

    return {
      autopilot: await jsonOr(autopilotR, null),
      driftStatus: await jsonOr(driftR, null),
      stack: (await jsonOr(stackR, {})) || {},
      pillars: (await jsonOr(pillarsR, {})) || {},
    };
  }

  #renderKpis({ queue, claimableCount, driftStatus, summary, stack, cost, pillars, slots, repo, autopilot }) {
    // Header repo & autopilot controls.
    const repoPill = this.#shadow.getElementById('cmd-repo-pill');
    if (repoPill) {
      const root = String(repo.effective_root || '');
      const name = root ? root.split('/').filter(Boolean).pop() : 'workspace';
      repoPill.textContent = `repo: ${name}`;
      repoPill.title = root || 'Active Chump repository';
    }

    const autopilotRunning = !!(autopilot && (
      autopilot.actual_state === 'running'
      || autopilot.actual_state === 'starting'
      || autopilot.desired_enabled === true
    ));
    const apPill = this.#shadow.getElementById('cmd-autopilot-pill');
    const apLabel = this.#shadow.getElementById('cmd-autopilot-label');
    const apCta = this.#shadow.getElementById('cmd-fleet-cta');
    if (apPill && apLabel) {
      apPill.classList.toggle('running', autopilotRunning);
      apLabel.textContent = autopilotRunning ? 'Autopilot: Running' : 'Autopilot: Parked';
    }
    if (apCta && !apCta.disabled) {
      apCta.dataset.actionView = autopilotRunning ? 'restart-fleet' : 'wake-fleet';
      apCta.textContent = autopilotRunning ? 'Stop + restart' : 'Wake fleet';
    }

    // KPI 1: Gap Ledger
    const openGaps = queue.filter((g) => (g.status || 'open') === 'open');
    const claimable = claimableCount != null
      ? claimableCount
      : openGaps.filter((g) => g.preflight_status === 'claimable' || (!g.assigned_session && !g.claimed_by)).length;
    const highPrio = openGaps.filter((g) => g.priority === 'P0' || g.priority === 'P1').length;
    const driftCount = driftStatus?.count ?? queue.filter((g) => g.closed_pr && (g.status || 'open') === 'open').length;

    const openEl = this.#shadow.getElementById('kpi-open-gaps');
    const unitEl = this.#shadow.getElementById('kpi-claimable-unit');
    const gapSub = this.#shadow.getElementById('kpi-gap-sub');
    const driftChip = this.#shadow.getElementById('kpi-drift-chip');
    if (openEl) openEl.textContent = String(openGaps.length);
    if (unitEl) unitEl.textContent = `open · ${claimable} claimable`;
    if (gapSub) gapSub.textContent = `${highPrio} P0/P1 priority items`;
    if (driftChip) {
      driftChip.textContent = driftCount > 0 ? `${driftCount} drift` : '0 drift';
      driftChip.className = `kpi-chip ${driftCount > 0 ? 'warn' : 'ok'}`;
    }

    // KPI 2: 24h Ships & Leases
    const ships = Number.isFinite(summary.today_ships) ? summary.today_ships : 0;
    const leases = Array.isArray(summary.active_leases) ? summary.active_leases : [];
    const ci = summary.ci_qa_score || null;
    const shipsEl = this.#shadow.getElementById('kpi-ships-today');
    const leaseChip = this.#shadow.getElementById('kpi-lease-chip');
    const ciSub = this.#shadow.getElementById('kpi-ci-sub');
    if (shipsEl) shipsEl.textContent = String(ships);
    if (leaseChip) {
      leaseChip.textContent = `${leases.length} active lease${leases.length === 1 ? '' : 's'}`;
      leaseChip.className = `kpi-chip ${leases.length > 0 ? 'ok' : ''}`;
    }
    if (ciSub) {
      ciSub.textContent = ci && typeof ci.pct === 'number'
        ? `CI ${ci.pct.toFixed(0)}% (${ci.sample_size} runs)`
        : (leases.length > 0 ? `Holding ${leases[0].gap}` : 'No active file locks');
    }

    // KPI 3: Cascade & Spend
    const dollars = Number(cost.session_cost_usd ?? cost.total_cost_usd ?? cost.cost_today ?? 0);
    const airgap = stack.air_gap_mode === true;
    const lastModel = stack.llm_last_completion?.label || stack.primary_backend || (slots[0]?.name) || 'cascade ready';
    const costEl = this.#shadow.getElementById('kpi-cost-today');
    const slotsUnit = this.#shadow.getElementById('kpi-slots-unit');
    const postureChip = this.#shadow.getElementById('kpi-posture-chip');
    const modelSub = this.#shadow.getElementById('kpi-model-sub');
    if (costEl) costEl.textContent = `$${dollars.toFixed(2)}`;
    if (slotsUnit) slotsUnit.textContent = `${slots.length} slot${slots.length === 1 ? '' : 's'}`;
    if (postureChip) {
      postureChip.textContent = airgap ? 'air-gap' : 'network';
      postureChip.className = 'kpi-chip ok';
    }
    if (modelSub) modelSub.textContent = this.#truncate(String(lastModel), 28);

    // KPI 4: 4-Pillar Posture & GitHub Budget
    const rl = stack.github_rate_limit || stack.gh_rate_limit;
    const ghChip = this.#shadow.getElementById('kpi-gh-chip');
    if (ghChip && rl && typeof rl.graphql_remaining === 'number' && typeof rl.graphql_limit === 'number') {
      const pct = Math.round((rl.graphql_remaining / Math.max(1, rl.graphql_limit)) * 100);
      ghChip.textContent = `GH ${pct}%`;
      ghChip.className = `kpi-chip ${pct < 20 ? 'err' : pct < 50 ? 'warn' : 'ok'}`;
    }
    const pGrid = this.#shadow.getElementById('kpi-pillars-grid');
    const pSub = this.#shadow.getElementById('kpi-pillar-sub');
    if (pGrid && Array.isArray(pillars.pillars) && pillars.pillars.length > 0) {
      const shortMap = { EFFECTIVE: 'EFF', CREDIBLE: 'CRED', RESILIENT: 'RES', 'ZERO-WASTE': 'ZERO' };
      pGrid.innerHTML = pillars.pillars.map((p) => {
        const code = shortMap[p.pillar] || String(p.pillar || '').slice(0, 4);
        const g = String(p.grade || pillars.fleet_grade || '—');
        return `<div class="pillar-cell" title="${this.#escape(p.pillar)}: ${p.pickable_count ?? 0} pickable, ${p.p0_count ?? 0} P0">
          <span class="pillar-code">${this.#escape(code)}</span>
          <span class="pillar-grade grade-${this.#escape(g)}">${this.#escape(g)}</span>
        </div>`;
      }).join('');
    }
    if (pSub) {
      const breaches = Number(pillars.fleet_slo_breaches ?? 0);
      pSub.textContent = breaches === 0 ? '0 fleet SLO breaches' : `${breaches} SLO breach${breaches === 1 ? '' : 'es'}`;
    }

    // Update Center Workbench tab counts.
    const qTab = this.#shadow.getElementById('wb-tab-queue');
    const cTab = this.#shadow.getElementById('wb-tab-cascade');
    const lTab = this.#shadow.getElementById('wb-tab-leases');
    if (qTab) qTab.textContent = `Queue (${openGaps.length})`;
    if (cTab) cTab.textContent = `Cascade (${slots.length})`;
    if (lTab) lTab.textContent = `Leases (${leases.length})`;
  }

  #renderQueueWorkbench(queue) {
    const host = this.#shadow.getElementById('wb-queue-rows');
    if (!host) return;
    const open = (queue || []).filter((g) => (g.status || 'open') === 'open');

    const filtered = open.filter((g) => {
      const isLeased = !!(g.assigned_session || g.claimed_by);
      const isClaimable = g.preflight_status === 'claimable' || !isLeased;
      if (this.#queueFilter === 'claimable' && !isClaimable) return false;
      if (this.#queueFilter === 'leased' && !isLeased) return false;
      if (this.#queueFilter === 'high' && g.priority !== 'P0' && g.priority !== 'P1') return false;
      if (this.#queueQuery) {
        const hay = `${g.id || ''} ${g.domain || ''} ${g.pillar || ''} ${g.title || ''}`.toLowerCase();
        if (!hay.includes(this.#queueQuery)) return false;
      }
      return true;
    });

    if (filtered.length === 0) {
      host.innerHTML = `<div class="empty-box">No gaps match the current filter. Click <strong>+ Reserve Gap</strong> above to add work to state.db.</div>`;
      return;
    }

    host.innerHTML = filtered.slice(0, 25).map((g) => {
      const isLeased = !!(g.assigned_session || g.claimed_by);
      const prioHigh = g.priority === 'P0' || g.priority === 'P1';
      const holder = g.assigned_session || g.claimed_by || '';
      const shortHolder = holder ? holder.slice(0, 28) : '';
      return `
        <article class="q-row" data-gap-id="${this.#escape(g.id)}">
          <div class="q-row-head">
            <span class="q-id">${this.#escape(g.id)}</span>
            <span class="q-prio ${prioHigh ? 'prio-high' : ''}">${this.#escape(g.priority || 'P2')}/${this.#escape(g.effort || 'm')}</span>
            ${g.domain ? `<span class="q-domain">${this.#escape(g.domain)}</span>` : ''}
            <span class="q-status ${isLeased ? 'leased' : ''}">${isLeased ? 'leased' : 'claimable'}</span>
          </div>
          <div class="q-title">${this.#escape(g.title || '(untitled gap)')}</div>
          <div class="q-foot">
            <span class="q-lease-meta">${shortHolder ? `lease: ${this.#escape(shortHolder)}` : (g.acceptance_criteria_count ? `${g.acceptance_criteria_count} acceptance criteria` : 'ready for claim')}</span>
            <div class="q-actions">
              ${!isLeased ? `<button type="button" class="btn btn-xs" data-q-claim="${this.#escape(g.id)}">Claim</button>` : ''}
              <button type="button" class="btn btn-primary btn-xs" data-q-dispatch="${this.#escape(g.id)}">Dispatch</button>
            </div>
          </div>
        </article>
      `;
    }).join('');

    host.querySelectorAll('[data-q-claim]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const id = btn.dataset.qClaim;
        if (!id) return;
        btn.disabled = true;
        btn.textContent = 'Claiming…';
        try {
          const r = await fetch(`/api/gap/claim/${encodeURIComponent(id)}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'pwa' },
          });
          const d = await r.json().catch(() => ({}));
          if (!r.ok || d.error) throw new Error(d.error || `HTTP ${r.status}`);
          btn.textContent = 'Claimed';
          setTimeout(() => this.#refreshAll(), 800);
        } catch (err) {
          btn.textContent = `Failed`;
          btn.title = String(err.message || err);
          setTimeout(() => { btn.disabled = false; btn.textContent = 'Claim'; }, 2500);
        }
      });
    });

    host.querySelectorAll('[data-q-dispatch]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const id = btn.dataset.qDispatch;
        if (!id) return;
        btn.disabled = true;
        btn.textContent = 'Dispatching…';
        try {
          const r = await fetch(`/api/gap/work/${encodeURIComponent(id)}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'pwa' },
          });
          if (!r.ok) throw new Error(`HTTP ${r.status}`);
          btn.textContent = 'Dispatched';
          setTimeout(() => this.#refreshAll(), 1200);
        } catch (err) {
          btn.textContent = 'Error';
          btn.title = String(err.message || err);
          setTimeout(() => { btn.disabled = false; btn.textContent = 'Dispatch'; }, 2500);
        }
      });
    });
  }

  #renderCascadeWorkbench(slots, stack) {
    const host = this.#shadow.getElementById('wb-cascade-content');
    if (!host) return;
    if (!slots || slots.length === 0) {
      const fallbackBackend = stack?.primary_backend || 'local / unconfigured';
      host.innerHTML = `<div class="empty-box">No multi-slot cascade active (primary backend: <code>${this.#escape(fallbackBackend)}</code>). Configure slots in Settings.</div>`;
      return;
    }

    const rows = slots.map((s) => {
      const p50 = s.latency_ms_p50 != null ? `${Math.round(s.latency_ms_p50)} ms` : '—';
      const tps = s.avg_tokens_per_sec != null ? `${s.avg_tokens_per_sec.toFixed(1)} tok/s` : '—';
      const ok = Number(s.success_count ?? 0);
      const fail = Number(s.sanity_fail_count ?? 0);
      return `
        <tr>
          <td class="mono-cell">${this.#escape(s.name)}</td>
          <td class="mono-cell">${p50}</td>
          <td class="mono-cell">${tps}</td>
          <td class="mono-cell">${ok} ok / ${fail} fail</td>
        </tr>
      `;
    }).join('');

    host.innerHTML = `
      <table class="data-table" aria-label="Provider cascade slots">
        <thead>
          <tr>
            <th>Slot</th>
            <th>p50 Latency</th>
            <th>Throughput</th>
            <th>Receipts</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>
      <div style="margin-top:10px; display:flex; justify-content:flex-end;">
        <button type="button" class="btn btn-xs" id="wb-cascade-settings">Configure Slot Toggles →</button>
      </div>
    `;
    host.querySelector('#wb-cascade-settings')?.addEventListener('click', () => {
      document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'settings' }));
    });
  }

  #renderLeasesWorkbench(summary) {
    const host = this.#shadow.getElementById('wb-leases-content');
    if (!host) return;
    const leases = Array.isArray(summary?.active_leases) ? summary.active_leases : [];
    if (leases.length === 0) {
      host.innerHTML = `<div class="empty-box">No active file leases in <code>.chump-locks/</code>. Claiming a gap acquires path-scoped collision protection automatically.</div>`;
      return;
    }
    const rows = leases.map((l) => {
      const exp = l.expires_at ? this.#until(new Date(l.expires_at)) : 'active';
      return `
        <tr>
          <td class="mono-cell">${this.#escape(l.gap || '—')}</td>
          <td class="mono-cell">${this.#escape(l.session_id || l.holder || 'local-session')}</td>
          <td class="mono-cell">${this.#escape(exp)}</td>
        </tr>
      `;
    }).join('');

    host.innerHTML = `
      <table class="data-table" aria-label="Active file leases">
        <thead>
          <tr>
            <th>Gap</th>
            <th>Session</th>
            <th>Lease TTL</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>
    `;
  }

  // PRODUCT-133: right-zone action overlay.
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
      && !g.claimed_by && !g.assigned_session
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

  #computeSynthesis({ events, queue, autopilot, driftStatus, slots, summary }) {
    const now = Date.now();
    const dayMs = 24 * 3600 * 1000;
    const tenMin = 10 * 60 * 1000;
    const SHIP_KINDS = new Set(['pr_merged', 'gap_shipped', 'gap_done', 'pr_closed_merged']);
    const FEEDBACK_KINDS = new Set(['feedback_emitted', 'operator_feedback', 'ambient_feedback']);

    const tsOf = (e) => (e.ts ? new Date(e.ts).getTime() : 0);
    const within = (e, ms) => (now - tsOf(e)) < ms;

    const ships24h = events.filter((e) => SHIP_KINDS.has((e.kind || '').toLowerCase()) && within(e, dayMs));
    const recentFb = events.filter((e) => FEEDBACK_KINDS.has((e.kind || '').toLowerCase()) && within(e, tenMin));
    const lastShip = events.find((e) => SHIP_KINDS.has((e.kind || '').toLowerCase()));
    const openGaps = queue.filter((g) => (g.status || 'open') === 'open');
    const activeLeases = Array.isArray(summary?.active_leases) ? summary.active_leases : [];
    const nextDec = openGaps
      .filter((g) => !g.assigned_session && !g.claimed_by)
      .sort((a, b) => {
        const o = { P0: 0, P1: 1, P2: 2, P3: 3, P4: 4, P5: 5 };
        return (o[a.priority] ?? 9) - (o[b.priority] ?? 9);
      })[0];

    let read, confidence;
    if (recentFb.length > 0) {
      const fb = recentFb[0];
      const subj = fb.subject || fb.body?.subject || 'operator signal';
      const ago = this.#ago(new Date(tsOf(fb)));
      read = `Operator feedback "${subj}" (${ago}) is active in the coordination stream.`;
      confidence = 'high';
    } else if (ships24h.length > 0) {
      const n = ships24h.length;
      const sinceLast = lastShip ? this.#ago(new Date(tsOf(lastShip))) : 'recently';
      read = `${n} verified ship${n === 1 ? '' : 's'} landed in the last 24h (latest ${sinceLast}); ${openGaps.length} gaps open in state.db.`;
      confidence = ships24h.length >= 3 ? 'high' : 'medium';
    } else if (activeLeases.length > 0) {
      read = `${activeLeases.length} active file lease${activeLeases.length === 1 ? '' : 's'} in flight (${activeLeases.map((l) => l.gap).slice(0, 2).join(', ')}); ${openGaps.length} open gaps in registry.`;
      confidence = 'high';
    } else if (lastShip) {
      read = `Fleet idle — no ships in 24h (last ship ${this.#ago(new Date(tsOf(lastShip)))}). ${openGaps.length} open gaps ready for claim or autopilot dispatch.`;
      confidence = 'medium';
    } else {
      read = `Supervisor standing by with ${openGaps.length} open gaps in state.db and ${slots.length} cascade slots configured.`;
      confidence = openGaps.length > 0 ? 'medium' : 'low';
    }

    const cards = [];

    // Card 1: Today's arc (action when idle + autopilot off)
    const autopilotRunning = !!(autopilot && (
      autopilot.actual_state === 'running'
      || autopilot.actual_state === 'starting'
      || autopilot.desired_enabled === true
    ));
    if (ships24h.length > 0) {
      const topPrs = ships24h
        .filter((e) => e.pr_number)
        .slice(0, 2)
        .map((e) => `pull/${e.pr_number}`)
        .join(', ');
      cards.push({
        id: 'todays-arc',
        tag: 'ARC',
        title: `Today's arc — ${ships24h.length} ship${ships24h.length === 1 ? '' : 's'}`,
        detail: topPrs ? `Recent merges: ${topPrs}` : 'Verified commits recorded in ambient stream.',
        actions: [{ label: 'Inspect events', view: 'noise' }],
      });
    } else if (!autopilotRunning) {
      cards.push({
        id: 'todays-arc',
        tag: 'ARC',
        title: `Today's arc — zero ships, autopilot off`,
        detail: `Fleet is parked. Wake autopilot to start autonomous dispatch, or claim a gap directly in the center workbench.`,
        actions: [
          { label: 'Wake fleet', view: 'wake-fleet', primary: true },
          { label: 'Inspect fleet', view: 'fleet' },
        ],
      });
    } else {
      const lastErr = autopilot?.last_error;
      cards.push({
        id: 'todays-arc',
        tag: 'ARC',
        title: `Today's arc — zero ships (autopilot on)`,
        detail: lastErr
          ? `Autopilot running with picker error: ${this.#truncate(String(lastErr), 90)}`
          : `Autopilot running with zero merges in 24h. Restart the loop if the picker is stalled.`,
        actions: [
          { label: 'Stop + restart', view: 'restart-fleet', primary: true },
          { label: 'Inspect fleet', view: 'fleet' },
        ],
      });
    }

    // Card 2: Gap-store drift — PRODUCT-127
    const apiDriftCount = driftStatus?.count ?? null;
    const localDriftCount = queue.filter((g) => g.closed_pr && (g.status || 'open') === 'open').length;
    const driftCount = apiDriftCount !== null ? apiDriftCount : localDriftCount;
    if (driftCount >= 1) {
      cards.push({
        id: 'gap-store-drift',
        tag: 'DRIFT',
        title: `Registry drift — ${driftCount} stale open row${driftCount === 1 ? '' : 's'}`,
        detail: `${driftCount} gap${driftCount === 1 ? '' : 's'} carry closed_pr receipts while status remains open.`,
        actions: [{ label: 'Repair drift', view: 'repair-drift', primary: true }],
      });
    }

    // Card 3: Next candidate decision
    if (nextDec) {
      cards.push({
        id: 'next-decision',
        tag: 'NEXT',
        title: `Top unclaimed — ${nextDec.id} (${nextDec.priority}/${nextDec.effort || 'm'})`,
        detail: this.#truncate(nextDec.title || '', 96),
        actions: [
          { label: `Dispatch ${nextDec.id}`, view: 'dispatch-gap', gapId: nextDec.id, primary: true },
          { label: 'Focus queue', view: 'focus-queue' },
        ],
      });
    }

    // Card 4: Counter-check / Sovereignty & Cascade receipt
    cards.push({
      id: 'sovereignty-posture',
      tag: 'VERIFY',
      counter: true,
      title: `Cascade & audit receipt — ${slots.length} provider slot${slots.length === 1 ? '' : 's'} wired`,
      detail: slots.length > 0
        ? ` Bandits and fallback slots route locally via ProviderCascade. Audit network egress or tune cost ceilings before overnight runs.`
        : `No provider slots detected yet. Add local Ollama or API credentials in Settings before waking workers.`,
      actions: [
        { label: 'Network audit', view: 'open-network', primary: slots.length === 0 },
        { label: 'Cost ceilings', view: 'open-settings' },
      ],
    });

    return { read, confidence, cards, evidenceCount: events.length };
  }

  #renderRead(text, confidence, evidenceCount) {
    const t = this.#shadow.getElementById('intel-read-text');
    const m = this.#shadow.getElementById('intel-read-meta');
    if (t) t.textContent = text;
    if (m) {
      const dot = confidence === 'high' ? 'high' : confidence === 'medium' ? 'medium' : 'low';
      const conf = confidence === 'high' ? 'High confidence' : confidence === 'medium' ? 'Medium confidence' : 'Baseline read';
      m.innerHTML = `
        <span class="intel-confidence">
          <span class="intel-confidence-dot ${dot}"></span>
          ${conf}
        </span>
        <span>· ${evidenceCount} events</span>
        <button class="intel-read-evidence" type="button" id="intel-read-evidence">evidence ↓</button>
      `;
      m.querySelector('#intel-read-evidence')?.addEventListener('click', () => {
        const body = this.#shadow.getElementById('intel-noise-body');
        const toggle = this.#shadow.getElementById('intel-noise-toggle');
        body?.classList.add('open');
        toggle?.setAttribute('aria-expanded', 'true');
        if (toggle?.firstChild) toggle.firstChild.textContent = '▼ ';
      });
    }
  }

  #renderSignal(cards) {
    const slot = this.#shadow.getElementById('intel-cards');
    if (!slot) return;
    if (cards.length === 0) {
      slot.innerHTML = '<div class="empty-box">No signal cards generated.</div>';
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
          <div class="intel-card-top">
            <span class="intel-tag ${c.counter ? 'bronze' : ''}">${this.#escape(c.tag || 'SIGNAL')}</span>
          </div>
          <div class="intel-card-title">${this.#escape(c.title)}</div>
          <div class="intel-card-detail">${this.#escape(c.detail)}</div>
          <div class="intel-card-actions">
            ${actionsHtml}
            <button class="intel-card-btn wrong" type="button"
                    data-card-id="${this.#escape(c.id)}"
                    data-action-view="wrong"
                    title="Demote noisy signal card">Dismiss</button>
          </div>
        </div>
      `;
    }).join('');
    slot.querySelectorAll('button[data-card-id]').forEach((btn) => {
      btn.addEventListener('click', (e) => this.#onCardAction(e.currentTarget));
    });
  }

  #renderNoise(events) {
    const count = this.#shadow.getElementById('intel-noise-count');
    const body = this.#shadow.getElementById('intel-noise-body');
    if (count) count.textContent = String(events.length);
    if (body) {
      if (events.length === 0) {
        body.innerHTML = '<div class="intel-noise-event">No recent events in ambient.jsonl.</div>';
        return;
      }
      body.innerHTML = events.slice(0, 50).map((e) => `
        <div class="intel-noise-event">
          [${this.#escape(String(e.ts || '').slice(11, 19) || '—')}] ${this.#escape(e.kind || 'event')}
          ${e.pr_number ? `pull/${this.#escape(String(e.pr_number))}` : ''}
          ${e.gap_id || e.gap ? `gap=${this.#escape(String(e.gap_id || e.gap))}` : ''}
        </div>`).join('');
    }
  }

  async #onCardAction(btn) {
    const cardId = btn.dataset.cardId;
    const view = btn.dataset.actionView;
    const gapId = btn.dataset.actionGap;

    if (view === 'wrong') {
      try {
        await fetch('/api/broadcast', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            event: 'FEEDBACK',
            kind: 'preference',
            subject: `cockpit_card_${cardId}`,
            vote: '-1',
            rationale: 'operator dismissed cockpit signal card',
          }),
        });
        btn.textContent = 'Noted';
        btn.disabled = true;
      } catch {}
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

    if (view === 'focus-queue') {
      this.#shadow.getElementById('wb-tab-queue')?.click();
      this.#shadow.getElementById('wb-queue-search')?.focus();
      return;
    }

    if (view === 'open-network') {
      document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'network' }));
      return;
    }

    if (view === 'open-settings') {
      document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'settings' }));
      return;
    }

    if (view === 'fleet') {
      this.#shadow.querySelector('[data-telem-tab="fleet"]')?.click();
      this.#shadow.getElementById('telem-pane-fleet')?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
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

    if (view === 'repair-drift') {
      btn.disabled = true;
      btn.textContent = 'Repairing…';
      try {
        const r = await fetch('/api/gap/dep-clean', { method: 'POST' });
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const d = await r.json().catch(() => ({}));
        const n = d.result?.cleaned_count ?? d.result?.count ?? 0;
        btn.textContent = `✓ Repaired ${n}`;
        setTimeout(() => this.#synthesize(), 1500);
      } catch (e) {
        btn.textContent = `✗ ${e.message || 'failed'}`;
      }
      setTimeout(() => { btn.disabled = false; }, 4000);
      return;
    }

    if (view === 'dispatch-gap' && gapId) {
      btn.disabled = true;
      btn.textContent = 'Dispatching…';
      try {
        const r = await fetch(`/api/gap/work/${encodeURIComponent(gapId)}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'pwa' },
        });
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        btn.textContent = `✓ Dispatched ${gapId}`;
        setTimeout(() => this.#synthesize(), 2000);
      } catch (e) {
        btn.textContent = `✗ ${e.message || 'failed'}`;
      }
      setTimeout(() => { btn.disabled = false; }, 4000);
    }
  }

  #ago(date) {
    const s = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
    if (s < 60) return `${s}s ago`;
    const m = Math.round(s / 60);
    if (m < 60) return `${m}m ago`;
    const h = Math.round(m / 60);
    if (h < 48) return `${h}h ago`;
    return `${Math.round(h / 24)}d ago`;
  }

  #until(date) {
    const s = Math.round((date.getTime() - Date.now()) / 1000);
    if (Number.isNaN(s)) return 'active';
    if (s <= 0) return 'expired';
    if (s < 60) return `${s}s left`;
    const m = Math.round(s / 60);
    if (m < 60) return `${m}m left`;
    return `${Math.floor(m / 60)}h ${m % 60}m left`;
  }

  #truncate(s, n) {
    return s.length <= n ? s : `${s.slice(0, n - 1)}…`;
  }

  #escape(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
}

if (!customElements.get('chump-view-cockpit')) {
  customElements.define('chump-view-cockpit', ChumpViewCockpit);
}
