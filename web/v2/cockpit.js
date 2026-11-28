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
  *, *::before, *::after {
    box-sizing: border-box;
  }
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

  /* ── PRODUCT-378: Dream -> Mission Architect -> Autonomous Factory Studio ── */
  .ws-shell {
    max-width: 1020px;
    margin: 0 auto;
    padding: 28px 24px 56px;
    display: flex;
    flex-direction: column;
    gap: 22px;
  }
  .ws-hero {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .ws-hero-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    flex-wrap: wrap;
  }
  .ws-eyebrow {
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--bronze);
  }
  .ws-ready-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border-radius: 999px;
    background: var(--tone-ok-bg);
    border: 1px solid var(--tone-ok-border);
    color: var(--success);
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 600;
  }
  .ws-ready-pill.warn {
    background: var(--tone-warn-bg);
    border-color: var(--tone-warn-border);
    color: var(--warn);
  }
  .ws-title {
    margin: 0;
    font-family: var(--font-display);
    font-size: 28px;
    font-weight: 600;
    letter-spacing: -0.025em;
    line-height: 1.16;
    color: var(--text);
  }
  .ws-subtitle {
    margin: 0;
    font-size: 14px;
    line-height: 1.55;
    color: var(--text-secondary);
    max-width: 840px;
  }

  /* 3-Stage Pipeline Journey Strip */
  .ws-journey {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 10px;
    margin-top: 6px;
  }
  .ws-stage {
    padding: 10px 13px;
    border-radius: var(--radius-sm);
    background: var(--bg-surface);
    border: 1px solid var(--border);
    display: flex;
    align-items: flex-start;
    gap: 10px;
  }
  .ws-stage.active {
    border-color: var(--accent);
    background: var(--accent-dim);
  }
  .ws-stage-num {
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 700;
    color: var(--accent);
    background: var(--bg-surface);
    border: 1px solid var(--border);
    padding: 2px 7px;
    border-radius: 999px;
    flex-shrink: 0;
  }
  .ws-stage.active .ws-stage-num {
    background: var(--accent);
    color: var(--on-accent);
    border-color: var(--accent);
  }
  .ws-stage-text {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .ws-stage-title {
    font-size: 12.5px;
    font-weight: 600;
    color: var(--text);
  }
  .ws-stage-sub {
    font-size: 11.5px;
    color: var(--text-secondary);
    line-height: 1.35;
  }

  /* Dream Intake Composer Card */
  .ws-composer-card {
    background: var(--bg-surface);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
    box-shadow: var(--shadow-card);
    padding: 20px 22px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .ws-mode-tabs {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px;
    border-radius: var(--radius-sm);
    background: var(--bg-elevated);
    border: 1px solid var(--border);
    align-self: flex-start;
  }
  .ws-mode-tab {
    border: none;
    background: transparent;
    color: var(--text-secondary);
    font-size: 12.5px;
    font-weight: 600;
    padding: 6px 13px;
    border-radius: 4px;
    cursor: pointer;
    transition: background 0.14s, color 0.14s;
  }
  .ws-mode-tab.active {
    background: var(--bg-surface);
    color: var(--accent);
    box-shadow: var(--shadow-card);
  }

  .ws-repo-row {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
    padding-bottom: 12px;
    border-bottom: 1px solid var(--border);
  }
  .ws-repo-row[hidden] { display: none; }
  .ws-field-label {
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-secondary);
  }
  .ws-repo-select {
    padding: 7px 12px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border-strong);
    background: var(--bg);
    color: var(--text);
    font-family: var(--font-sans);
    font-size: 13px;
    font-weight: 600;
    min-width: 210px;
    cursor: pointer;
  }
  .ws-repo-path {
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: var(--text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    max-width: 340px;
  }
  .ws-scout-btn {
    margin-left: auto;
    background: var(--bronze-dim);
    border: 1px solid var(--bronze);
    color: var(--bronze);
    font-weight: 600;
    padding: 6px 12px;
    font-size: 12px;
    border-radius: var(--radius-sm);
    cursor: pointer;
    white-space: nowrap;
  }
  .ws-scout-btn:hover {
    background: var(--bronze);
    color: var(--on-accent);
  }

  .ws-new-repo-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    padding-bottom: 12px;
    border-bottom: 1px solid var(--border);
  }
  .ws-new-repo-bar[hidden] { display: none; }
  .ws-slug-prefix {
    font-family: var(--font-mono);
    font-size: 12.5px;
    color: var(--text-secondary);
  }
  .ws-slug-input {
    padding: 7px 11px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border-strong);
    background: var(--bg);
    color: var(--text);
    font-family: var(--font-mono);
    font-size: 13px;
    font-weight: 600;
    min-width: 220px;
  }

  .ws-custom-repo {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    padding: 10px 12px;
    border-radius: var(--radius-sm);
    background: var(--bg);
    border: 1px solid var(--border);
  }
  .ws-custom-repo[hidden] { display: none; }
  .ws-custom-repo input {
    flex: 1 1 260px;
    padding: 7px 10px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
    background: var(--bg-surface);
    color: var(--text);
    font-family: var(--font-mono);
    font-size: 12px;
  }

  .ws-textarea {
    width: 100%;
    min-height: 108px;
    max-height: 280px;
    resize: vertical;
    padding: 12px 14px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
    font-family: var(--font-sans);
    font-size: 14px;
    line-height: 1.5;
  }
  .ws-textarea:focus {
    outline: 2px solid var(--accent);
    outline-offset: 1px;
    border-color: var(--accent);
  }

  .ws-starters {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }
  .ws-starter-label {
    font-family: var(--font-mono);
    font-size: 10.5px;
    color: var(--text-secondary);
    margin-right: 2px;
  }
  .ws-starter-chip {
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text-secondary);
    border-radius: 999px;
    padding: 4px 10px;
    font-size: 11.5px;
    cursor: pointer;
    transition: background 0.14s, color 0.14s, border-color 0.14s;
  }
  .ws-starter-chip:hover {
    background: var(--accent-dim);
    color: var(--accent);
    border-color: var(--accent);
  }

  .ws-launch-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    flex-wrap: wrap;
    padding-top: 10px;
    border-top: 1px solid var(--border);
  }
  .ws-runners {
    display: flex;
    align-items: center;
    gap: 5px;
    flex-wrap: wrap;
  }
  .ws-runner-pill {
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text-secondary);
    border-radius: var(--radius-sm);
    padding: 5px 10px;
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.14s, color 0.14s, border-color 0.14s;
  }
  .ws-runner-pill:hover {
    color: var(--text);
    background: var(--bg-elevated);
  }
  .ws-runner-pill.active {
    background: var(--accent-dim);
    color: var(--accent);
    border-color: var(--accent);
    font-weight: 600;
  }
  .ws-cta-group {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-left: auto;
  }
  .ws-run-btn {
    min-height: 44px;
    padding: 9px 18px;
    font-size: 13.5px;
    font-weight: 600;
  }
  .ws-chat-btn {
    min-height: 44px;
    padding: 9px 14px;
    font-size: 13px;
  }
  .ws-feedback {
    padding: 10px 13px;
    border-radius: var(--radius-sm);
    font-size: 12.5px;
    background: var(--bg);
    border: 1px solid var(--border);
    color: var(--text-secondary);
  }
  .ws-feedback[hidden] { display: none; }
  .ws-feedback.ok {
    background: var(--tone-ok-bg);
    border-color: var(--tone-ok-border);
    color: var(--success);
  }
  .ws-feedback.err {
    background: var(--tone-err-bg);
    border-color: var(--tone-err-border);
    color: var(--error);
  }

  /* Stage 2 & Stage 3: Draft Plan Approval + Live Running Mission Cards */
  .msn-list {
    display: flex;
    flex-direction: column;
    gap: 18px;
  }
  .msn-card {
    background: var(--bg-surface);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
    box-shadow: var(--shadow-card);
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
  .msn-card.draft {
    border: 2px solid var(--accent);
  }
  .msn-card.needs-decision {
    border: 2px solid var(--bronze);
  }
  .msn-head {
    padding: 16px 20px;
    border-bottom: 1px solid var(--border);
    display: flex;
    flex-direction: column;
    gap: 8px;
    background: var(--bg-surface);
  }
  .msn-head-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    flex-wrap: wrap;
  }
  .msn-badges {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }
  .ws-badge {
    font-family: var(--font-mono);
    font-size: 10.5px;
    font-weight: 600;
    padding: 3px 8px;
    border-radius: 999px;
    background: var(--bg-elevated);
    color: var(--text-secondary);
  }
  .ws-badge.ok { background: var(--tone-ok-bg); color: var(--success); }
  .ws-badge.warn { background: var(--tone-warn-bg); color: var(--warn); }
  .ws-badge.err { background: var(--tone-err-bg); color: var(--error); }
  .ws-badge.accent { background: var(--accent-dim); color: var(--accent); }
  .ws-badge.bronze { background: var(--bronze-dim); color: var(--bronze); }

  .msn-title {
    margin: 0;
    font-family: var(--font-display);
    font-size: 19px;
    font-weight: 600;
    color: var(--text);
    letter-spacing: -0.015em;
  }
  .msn-summary {
    margin: 0;
    font-size: 13px;
    line-height: 1.5;
    color: var(--text-secondary);
  }

  /* Progress bar */
  .msn-progress-wrap {
    display: flex;
    flex-direction: column;
    gap: 5px;
    margin-top: 4px;
  }
  .msn-progress-meta {
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: var(--text-secondary);
  }
  .msn-progress-bar {
    height: 8px;
    width: 100%;
    border-radius: 999px;
    background: var(--bg-elevated);
    overflow: hidden;
  }
  .msn-progress-fill {
    height: 100%;
    background: var(--accent);
    border-radius: 999px;
    transition: width 0.35s ease;
  }

  /* Founder Decision Banner */
  .msn-decision-box {
    margin: 14px 20px 0;
    padding: 14px 16px;
    border-radius: var(--radius-sm);
    background: var(--bronze-dim);
    border: 1px solid var(--bronze);
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .msn-decision-label {
    font-family: var(--font-mono);
    font-size: 10.5px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--bronze);
  }
  .msn-decision-q {
    font-size: 13.5px;
    font-weight: 600;
    color: var(--text);
  }
  .msn-decision-row {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .msn-decision-input {
    flex: 1 1 260px;
    padding: 8px 11px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border-strong);
    background: var(--bg-surface);
    color: var(--text);
    font-size: 13px;
  }

  /* Live Activity & Log Stream */
  .msn-live-box {
    margin: 14px 20px 0;
    padding: 12px 14px;
    border-radius: var(--radius-sm);
    background: var(--bg);
    border: 1px solid var(--border);
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .msn-live-head {
    display: flex;
    align-items: center;
    gap: 8px;
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 600;
    color: var(--accent);
  }
  .msn-log-pre {
    margin: 0;
    padding: 8px 10px;
    border-radius: var(--radius-sm);
    background: var(--bg-elevated);
    color: var(--text-secondary);
    font-family: var(--font-mono);
    font-size: 11px;
    line-height: 1.45;
    max-height: 150px;
    overflow-y: auto;
    white-space: pre-wrap;
    word-break: break-word;
  }

  /* Step list */
  .msn-steps {
    padding: 14px 20px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .msn-step {
    padding: 11px 13px;
    border-radius: var(--radius-sm);
    background: var(--bg);
    border: 1px solid var(--border);
    display: flex;
    align-items: flex-start;
    gap: 11px;
  }
  .msn-step.in_progress {
    border-color: var(--accent);
    background: var(--accent-dim);
  }
  .msn-step.completed {
    opacity: 0.92;
  }
  .msn-step.failed {
    border-color: var(--tone-err-border);
    background: var(--tone-err-bg);
  }
  .msn-step.disabled {
    opacity: 0.52;
  }
  .msn-step-icon {
    font-family: var(--font-mono);
    font-size: 13px;
    font-weight: 700;
    min-width: 22px;
    padding-top: 1px;
    text-align: center;
  }
  .msn-step-icon.ok { color: var(--success); }
  .msn-step-icon.run { color: var(--accent); }
  .msn-step-icon.err { color: var(--error); }
  .msn-step-main {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .msn-step-top {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }
  .msn-step-title {
    font-size: 13.5px;
    font-weight: 600;
    color: var(--text);
    line-height: 1.35;
  }
  .msn-step-desc {
    font-size: 12.5px;
    color: var(--text-secondary);
    line-height: 1.45;
  }
  .msn-step-done {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-secondary);
  }
  .msn-step-receipt {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--success);
  }
  .msn-step-err {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--error);
    white-space: pre-wrap;
  }
  .msn-step-actions {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
  }

  .msn-add-step-row {
    padding: 0 20px 14px;
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .msn-add-step-input {
    flex: 1 1 240px;
    padding: 7px 11px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
    font-size: 12.5px;
  }

  .msn-foot {
    padding: 13px 20px;
    border-top: 1px solid var(--border);
    background: var(--bg-elevated);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    flex-wrap: wrap;
  }
  .msn-launch-cta {
    min-height: 44px;
    padding: 10px 20px;
    font-size: 14px;
    font-weight: 600;
  }

  .ws-empty-missions {
    padding: 24px 18px;
    border-radius: var(--radius);
    background: var(--bg-surface);
    border: 1px dashed var(--border-strong);
    text-align: center;
    color: var(--text-secondary);
    font-size: 13.5px;
    line-height: 1.55;
  }

  .ws-footer-strip {
    padding-top: 10px;
    border-top: 1px solid var(--border);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    flex-wrap: wrap;
    font-size: 12.5px;
    color: var(--text-secondary);
  }
  .ws-text-btn {
    background: none;
    border: none;
    padding: 0;
    color: var(--accent);
    font-size: 12.5px;
    font-weight: 600;
    cursor: pointer;
  }
  .ws-text-btn:hover { text-decoration: underline; }

  @media (max-width: 820px) {
    .ws-shell { padding: 18px 14px 40px; }
    .ws-title { font-size: 22px; }
    .ws-journey { grid-template-columns: 1fr; }
    .ws-cta-group { width: 100%; justify-content: flex-end; }
    .ws-scout-btn { margin-left: 0; }
  }
`;

const DREAM_TEMPLATES = [
  {
    chip: '0→1 Repo Revival',
    vision:
      'Take this repository from its current state to a clean, working, tested v1: fix any broken build/CI checks, implement any unfinished features promised in the README, add end-to-end tests, and ensure the quickstart works out of the box.',
  },
  {
    chip: 'Ship a Major Feature Arc',
    vision:
      'Design and ship a complete vertical feature slice end-to-end: domain types, storage/state layer, API or CLI interface, error handling, and automated unit + integration tests.',
  },
  {
    chip: 'Production Hardening',
    vision:
      'Harden this repository for production release: eliminate panics/unwraps in runtime paths, close test-coverage gaps on failure modes, verify lints/formatting, and align documentation with actual behavior.',
  },
];

const RUNNER_OPTIONS = [
  { id: 'auto',    label: 'Auto (Best)' },
  { id: 'claude',  label: 'Claude Ultra' },
  { id: 'agy',     label: 'Gemini 4 (agy)' },
  { id: 'cascade', label: 'Cloud Cascade' },
  { id: 'ollama',  label: 'Local Offline' },
];

class ChumpViewCockpit extends HTMLElement {
  #shadow;
  #centerTab = 'queue';
  #queueFilter = 'all';
  #queueQuery = '';
  #telemTab = 'fleet';
  #ambientMounted = false;
  #latestInputs = null;
  #pollTimer = null;
  #modeListener = null;
  #repoListener = null;
  #selectedRunner = 'auto';
  #repoMode = 'existing';
  #selectedRepoPath = '';
  #discoveredRepos = [];
  #missions = [];
  #repoCtx = null;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  #currentUiMode() {
    return document.documentElement.getAttribute('data-ui-mode') === 'advanced' ? 'advanced' : 'simple';
  }

  connectedCallback() {
    this.#bootCurrentMode();
    this.#modeListener = () => this.#bootCurrentMode();
    this.#repoListener = () => {
      if (this.#currentUiMode() === 'simple') this.#refreshSimple();
      else this.#refreshAll();
    };
    document.addEventListener('chump:ui-mode-changed', this.#modeListener);
    document.addEventListener('chump:repo-changed', this.#repoListener);
  }

  disconnectedCallback() {
    if (this.#pollTimer) clearInterval(this.#pollTimer);
    if (this.#modeListener) document.removeEventListener('chump:ui-mode-changed', this.#modeListener);
    if (this.#repoListener) document.removeEventListener('chump:repo-changed', this.#repoListener);
  }

  #bootCurrentMode() {
    if (this.#pollTimer) clearInterval(this.#pollTimer);
    this.#ambientMounted = false;
    if (this.#currentUiMode() === 'simple') {
      this.#renderSimpleShell();
      this.#refreshSimple();
      this.#scheduleSimplePoll();
    } else {
      this.#renderShell();
      this.#refreshAll();
      this.#pollTimer = setInterval(() => this.#refreshAll(), 30_000);
    }
  }

  #scheduleSimplePoll() {
    if (this.#pollTimer) clearInterval(this.#pollTimer);
    const anyRunning = this.#missions.some((m) => m.is_running || m.status === 'running');
    const intervalMs = anyRunning ? 3_500 : 15_000;
    this.#pollTimer = setInterval(() => this.#refreshSimple(), intervalMs);
  }

  #renderSimpleShell() {
    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="ws-shell" role="region" aria-label="Chump Autonomous Software Factory">
        <header class="ws-hero">
          <div class="ws-hero-top">
            <span class="ws-eyebrow">Autonomous Software Factory · 0→1 Mission Engine</span>
            <span class="ws-ready-pill" id="ws-ready-pill">
              <span class="status-dot"></span>
              <span id="ws-ready-text">Checking models…</span>
            </span>
          </div>
          <h1 class="ws-title">Feed Chump a dream. Approve the plan. Watch it ship.</h1>
          <p class="ws-subtitle">
            Point Chump at any repo in <code>~/Projects</code>—or start a brand-new repo from an idea. Chump scans the codebase, architects a 5–10 step <strong>L1 → L2 → L3 Mission Plan</strong> for your 1-click approval, then builds, tests, and auto-merges each milestone in isolated worktrees—only pausing if a real product decision needs you.
          </p>

          <div class="ws-journey" aria-label="Mission lifecycle">
            <div class="ws-stage active" id="ws-stage-1">
              <span class="ws-stage-num">1</span>
              <div class="ws-stage-text">
                <span class="ws-stage-title">Feed Vision or Pick Repo</span>
                <span class="ws-stage-sub">Paste a spec, create a new repo, or run a 0→1 repo scout</span>
              </div>
            </div>
            <div class="ws-stage" id="ws-stage-2">
              <span class="ws-stage-num">2</span>
              <div class="ws-stage-text">
                <span class="ws-stage-title">Approve 5–10 Step Plan</span>
                <span class="ws-stage-sub">Edit, uncheck, or add milestones before the fleet starts</span>
              </div>
            </div>
            <div class="ws-stage" id="ws-stage-3">
              <span class="ws-stage-num">3</span>
              <div class="ws-stage-text">
                <span class="ws-stage-title">Hands-Off Auto-Ship</span>
                <span class="ws-stage-sub">Agents code, run test gates &amp; auto-merge verified commits</span>
              </div>
            </div>
          </div>
        </header>

        <section class="ws-composer-card" aria-label="Architect a Mission">
          <div class="ws-mode-tabs" role="tablist" aria-label="Target repository mode">
            <button type="button" class="ws-mode-tab active" data-repo-mode="existing" role="tab" aria-selected="true">
              Existing Repo in ~/Projects
            </button>
            <button type="button" class="ws-mode-tab" data-repo-mode="new" role="tab" aria-selected="false">
              + Brand-New Idea (Create Repo)
            </button>
          </div>

          <div class="ws-repo-row" id="ws-existing-repo-row">
            <label class="ws-field-label" for="ws-repo-select">Repo</label>
            <select class="ws-repo-select" id="ws-repo-select" aria-label="Target repository">
              <option value="">Scanning ~/Projects…</option>
            </select>
            <span class="ws-repo-path" id="ws-repo-path"></span>
            <button type="button" class="ws-scout-btn" id="ws-scout-btn"
                    title="Scan README, tests &amp; CI in this repo and propose a 0→1 revival plan with zero typing">
              Scout &amp; Revive Repo (0→1) →
            </button>
          </div>

          <div class="ws-new-repo-bar" id="ws-new-repo-row" hidden>
            <label class="ws-field-label" for="ws-new-repo-name">New Repo</label>
            <span class="ws-slug-prefix">~/Projects/</span>
            <input type="text" class="ws-slug-input" id="ws-new-repo-name"
                   placeholder="my-new-product" maxlength="64" autocomplete="off">
            <span class="ws-repo-path">Chump will initialize git, README &amp; scaffold on launch</span>
          </div>

          <div class="ws-custom-repo" id="ws-custom-repo" hidden>
            <input type="text" id="ws-custom-repo-input" placeholder="/Users/you/Projects/your-git-repo" aria-label="Local git repository path">
            <button type="button" class="btn btn-primary btn-xs" id="ws-custom-repo-save">Use Path</button>
            <button type="button" class="btn btn-xs" id="ws-custom-repo-cancel">Cancel</button>
          </div>

          <textarea id="msg-input" class="ws-textarea" rows="4"
                    aria-label="Describe your product dream, vision, or milestone spec"
                    placeholder="What's the dream or outcome? Paste a product spec, describe what 'done' looks like (e.g. &quot;Take BEAST-MODE from dormant to a tested, deployable v1&quot;), or click 'Scout &amp; Revive Repo (0→1)' above…"></textarea>

          <div class="ws-starters" aria-label="Vision templates">
            <span class="ws-starter-label">Dream templates:</span>
            ${DREAM_TEMPLATES.map((t, idx) => `
              <button type="button" class="ws-starter-chip" data-starter-idx="${idx}">${this.#escape(t.chip)}</button>
            `).join('')}
          </div>

          <div class="ws-launch-bar">
            <div class="ws-runners" role="radiogroup" aria-label="Agent model runner">
              ${RUNNER_OPTIONS.map((r) => `
                <button type="button" class="ws-runner-pill ${r.id === this.#selectedRunner ? 'active' : ''}"
                        data-runner="${r.id}"
                        role="radio"
                        aria-checked="${r.id === this.#selectedRunner}">
                  ${this.#escape(r.label)}
                </button>
              `).join('')}
            </div>

            <div class="ws-cta-group">
              <button type="button" class="btn ws-chat-btn" id="ws-ask-chat-btn" title="Brainstorm or refine spec in interactive chat">
                Discuss in Chat →
              </button>
              <button type="button" class="btn btn-primary ws-run-btn" id="send-btn" aria-label="Architect Mission Plan">
                Architect Mission Plan →
              </button>
            </div>
          </div>

          <div class="ws-feedback" id="ws-feedback" hidden></div>
        </section>

        <section aria-label="Missions and autonomous progress">
          <div class="msn-list" id="ws-missions-host">
            <div class="ws-empty-missions">Loading missions…</div>
          </div>
        </section>

        <footer class="ws-footer-strip">
          <span>
            Want to inspect raw gaps or open PRs?
            <button type="button" class="ws-text-btn" id="ws-browse-prs">Pull Requests →</button>
            ·
            <button type="button" class="ws-text-btn" id="ws-browse-queue">Backlog Queue →</button>
          </span>
          <button type="button" class="ws-text-btn" id="ws-open-advanced">
            Open Advanced Fleet Telemetry →
          </button>
        </footer>
      </div>
    `;

    this.#wireSimpleInteractions();
  }

  #wireSimpleInteractions() {
    const input = this.#shadow.getElementById('msg-input');
    const architectBtn = this.#shadow.getElementById('send-btn');
    const scoutBtn = this.#shadow.getElementById('ws-scout-btn');
    const chatBtn = this.#shadow.getElementById('ws-ask-chat-btn');
    const repoSelect = this.#shadow.getElementById('ws-repo-select');
    const existingRow = this.#shadow.getElementById('ws-existing-repo-row');
    const newRepoRow = this.#shadow.getElementById('ws-new-repo-row');
    const newRepoInput = this.#shadow.getElementById('ws-new-repo-name');
    const customRow = this.#shadow.getElementById('ws-custom-repo');
    const customInput = this.#shadow.getElementById('ws-custom-repo-input');

    // Mode tabs: Existing Repo vs Brand-New Repo.
    this.#shadow.querySelectorAll('[data-repo-mode]').forEach((tab) => {
      tab.addEventListener('click', () => {
        this.#repoMode = tab.dataset.repoMode === 'new' ? 'new' : 'existing';
        this.#shadow.querySelectorAll('[data-repo-mode]').forEach((t) => {
          const act = t === tab;
          t.classList.toggle('active', act);
          t.setAttribute('aria-selected', String(act));
        });
        if (this.#repoMode === 'new') {
          existingRow?.setAttribute('hidden', '');
          customRow?.setAttribute('hidden', '');
          newRepoRow?.removeAttribute('hidden');
          if (input) {
            input.placeholder =
              'Describe the brand-new product dream, features, stack preference, and what a working v1 looks like…';
          }
          newRepoInput?.focus();
        } else {
          newRepoRow?.setAttribute('hidden', '');
          existingRow?.removeAttribute('hidden');
          if (input) {
            input.placeholder =
              'What\'s the dream or outcome? Paste a product spec, describe what \'done\' looks like, or click \'Scout & Revive Repo (0→1)\' above…';
          }
        }
      });
    });

    // Dream template chips.
    this.#shadow.querySelectorAll('[data-starter-idx]').forEach((chip) => {
      chip.addEventListener('click', () => {
        const idx = Number(chip.dataset.starterIdx);
        const tpl = DREAM_TEMPLATES[idx];
        if (!tpl || !input) return;
        input.value = tpl.vision;
        input.focus();
      });
    });

    // Runner pills.
    this.#shadow.querySelectorAll('[data-runner]').forEach((pill) => {
      pill.addEventListener('click', () => {
        this.#selectedRunner = pill.dataset.runner || 'auto';
        this.#shadow.querySelectorAll('[data-runner]').forEach((p) => {
          const isAct = p === pill;
          p.classList.toggle('active', isAct);
          p.setAttribute('aria-checked', String(isAct));
        });
      });
    });

    // Repo selector + custom path.
    repoSelect?.addEventListener('change', async () => {
      const val = repoSelect.value;
      if (val === '__custom__') {
        customRow?.removeAttribute('hidden');
        customInput?.focus();
        return;
      }
      customRow?.setAttribute('hidden', '');
      this.#selectedRepoPath = val;
      const pathEl = this.#shadow.getElementById('ws-repo-path');
      if (pathEl) {
        pathEl.textContent = val;
        pathEl.title = val;
      }
      if (val && this.#repoCtx?.multi_repo_enabled) {
        fetch('/api/repo/working', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ path: val }),
        }).then(() => document.dispatchEvent(new CustomEvent('chump:repo-changed'))).catch(() => {});
      }
    });

    this.#shadow.getElementById('ws-custom-repo-cancel')?.addEventListener('click', () => {
      customRow?.setAttribute('hidden', '');
      this.#renderRepoSelect();
    });

    this.#shadow.getElementById('ws-custom-repo-save')?.addEventListener('click', () => {
      const raw = (customInput?.value || '').trim();
      if (!raw) return;
      this.#selectedRepoPath = raw;
      if (!this.#discoveredRepos.some((r) => r.path === raw)) {
        const name = raw.split('/').filter(Boolean).pop() || raw;
        this.#discoveredRepos.unshift({ name, path: raw, remote_owner_repo: null });
      }
      customRow?.setAttribute('hidden', '');
      this.#renderRepoSelect();
    });

    // 1-Click Scout & Revive (0->1) button — zero typing required!
    scoutBtn?.addEventListener('click', () => {
      this.#architectMission({ forceScout: true });
    });

    // Primary Architect Mission Plan button + Cmd/Ctrl+Enter.
    architectBtn?.addEventListener('click', () => {
      this.#architectMission({ forceScout: false });
    });
    input?.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        this.#architectMission({ forceScout: false });
      }
    });

    // Discuss in Chat button.
    chatBtn?.addEventListener('click', () => {
      const text = (input?.value || '').trim();
      if (text) {
        try { sessionStorage.setItem('chump.pending_chat_prompt', text); } catch {}
      }
      document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'chat' }));
    });

    // Footer links.
    this.#shadow.getElementById('ws-browse-prs')?.addEventListener('click', () => {
      document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'prs' }));
    });
    this.#shadow.getElementById('ws-browse-queue')?.addEventListener('click', () => {
      document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'agent' }));
    });
    this.#shadow.getElementById('ws-open-advanced')?.addEventListener('click', () => {
      document.dispatchEvent(new CustomEvent('chump:set-ui-mode', { detail: 'advanced' }));
    });
  }

  async #architectMission({ forceScout }) {
    const input = this.#shadow.getElementById('msg-input');
    const architectBtn = this.#shadow.getElementById('send-btn');
    const scoutBtn = this.#shadow.getElementById('ws-scout-btn');
    const newRepoInput = this.#shadow.getElementById('ws-new-repo-name');
    const fb = this.#shadow.getElementById('ws-feedback');

    const vision = forceScout ? (input?.value || '').trim() : (input?.value || '').trim();
    if (this.#repoMode === 'new') {
      const slug = (newRepoInput?.value || '').trim();
      if (!slug) {
        newRepoInput?.focus();
        if (fb) {
          fb.removeAttribute('hidden');
          fb.className = 'ws-feedback err';
          fb.textContent = 'Enter a name for your new repository (e.g. my-dream-app).';
        }
        return;
      }
      if (!vision) {
        input?.focus();
        if (fb) {
          fb.removeAttribute('hidden');
          fb.className = 'ws-feedback err';
          fb.textContent = 'Describe your product dream or spec so Chump knows what to architect.';
        }
        return;
      }
    }

    if (architectBtn) {
      architectBtn.disabled = true;
      architectBtn.textContent = 'Architecting Plan…';
    }
    if (scoutBtn) scoutBtn.disabled = true;
    if (fb) {
      fb.removeAttribute('hidden');
      fb.className = 'ws-feedback';
      fb.textContent = this.#repoMode === 'new'
        ? 'Synthesizing 0→1 greenfield Mission Plan via ProviderCascade…'
        : 'Scanning repository L1 foundation checks, README & commits, and synthesizing a 5–10 step Mission Plan…';
    }

    try {
      const body = {
        vision,
        repo_mode: this.#repoMode,
        repo_path: this.#selectedRepoPath || this.#repoCtx?.effective_root || null,
        new_repo_name: this.#repoMode === 'new' ? (newRepoInput?.value || '').trim() : null,
        runner: this.#selectedRunner,
      };

      const r = await fetch('/api/missions/architect', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'pwa' },
        body: JSON.stringify(body),
      });
      const d = await r.json().catch(() => ({}));
      if (!r.ok || d.error) {
        throw new Error(d.error || `HTTP ${r.status}`);
      }

      if (input) input.value = '';
      if (newRepoInput) newRepoInput.value = '';
      if (fb) {
        fb.className = 'ws-feedback ok';
        fb.textContent = `✓ Proposed "${d.mission?.title || 'Mission Plan'}" (${d.mission?.total_steps || 0} steps) — review and click Approve & Launch below!`;
      }

      await this.#refreshSimple();
      const firstCard = this.#shadow.querySelector('.msn-card');
      firstCard?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    } catch (err) {
      if (fb) {
        fb.className = 'ws-feedback err';
        fb.textContent = `Could not architect mission: ${err.message || err}`;
      }
    } finally {
      if (architectBtn) {
        architectBtn.disabled = false;
        architectBtn.textContent = 'Architect Mission Plan →';
      }
      if (scoutBtn) scoutBtn.disabled = false;
    }
  }

  async #refreshSimple() {
    const [missionsR, repoR, slotsR, queueR] = await Promise.allSettled([
      fetch('/api/missions'),
      fetch('/api/repo/context'),
      fetch('/api/slots'),
      fetch('/api/gap-queue'),
    ]);

    const jsonOr = async (settled, fallback) => {
      try {
        if (settled.status === 'fulfilled' && settled.value.ok) {
          return await settled.value.json();
        }
      } catch {}
      return fallback;
    };

    const missionsDoc = await jsonOr(missionsR, {});
    const repo = await jsonOr(repoR, {});
    const slotsDoc = await jsonOr(slotsR, {});
    const queueDoc = await jsonOr(queueR, {});

    this.#repoCtx = repo;
    if (Array.isArray(missionsDoc.repos) && missionsDoc.repos.length > 0) {
      this.#discoveredRepos = missionsDoc.repos;
    }
    this.#missions = Array.isArray(missionsDoc.missions) ? missionsDoc.missions : [];

    if (!this.#selectedRepoPath) {
      this.#selectedRepoPath = String(repo.effective_root || this.#discoveredRepos[0]?.path || '');
    }

    this.#renderRepoSelect();
    this.#renderSimpleReadiness(Array.isArray(slotsDoc.slots) ? slotsDoc.slots : [], null);
    this.#renderJourneyHighlight();
    this.#renderMissionsList();
    this.#scheduleSimplePoll();

    const browseBtn = this.#shadow.getElementById('ws-browse-queue');
    const openCount = Array.isArray(queueDoc.gaps)
      ? queueDoc.gaps.filter((g) => (g.status || 'open') === 'open').length
      : 0;
    if (browseBtn) {
      browseBtn.textContent = openCount > 0 ? `Backlog Queue (${openCount}) →` : 'Backlog Queue →';
    }

    fetch('/api/stack-status')
      .then((r) => (r.ok ? r.json() : null))
      .then((stack) => {
        if (!this.isConnected || this.#currentUiMode() !== 'simple' || !stack) return;
        this.#renderSimpleReadiness(Array.isArray(slotsDoc.slots) ? slotsDoc.slots : [], stack);
      })
      .catch(() => {});
  }

  #renderJourneyHighlight() {
    const s1 = this.#shadow.getElementById('ws-stage-1');
    const s2 = this.#shadow.getElementById('ws-stage-2');
    const s3 = this.#shadow.getElementById('ws-stage-3');
    const hasRunning = this.#missions.some((m) => m.status === 'running' || m.is_running || m.status === 'needs_decision');
    const hasDraft = this.#missions.some((m) => m.status === 'draft');
    s1?.classList.toggle('active', !hasDraft && !hasRunning);
    s2?.classList.toggle('active', hasDraft && !hasRunning);
    s3?.classList.toggle('active', hasRunning);
  }

  #renderSimpleReadiness(slots, stack) {
    const pill = this.#shadow.getElementById('ws-ready-pill');
    const text = this.#shadow.getElementById('ws-ready-text');
    if (!pill || !text) return;
    const infOk = stack?.cascade_enabled || (stack?.inference?.configured && stack?.inference?.models_reachable !== false);
    if (slots.length > 0) {
      const hasLocal = slots.some((s) => /ollama|local/i.test(String(s.name || '')));
      pill.classList.remove('warn');
      text.textContent = hasLocal
        ? `${slots.length} model slots ready · Cloud + Offline`
        : `${slots.length} model slot${slots.length === 1 ? '' : 's'} ready`;
    } else if (infOk || stack?.primary_backend) {
      pill.classList.remove('warn');
      text.textContent = `Models ready · ${stack?.primary_backend || 'cascade'}`;
    } else if (stack) {
      pill.classList.add('warn');
      text.textContent = 'Configure a model in Settings';
    }
  }

  #renderRepoSelect() {
    const select = this.#shadow.getElementById('ws-repo-select');
    const pathEl = this.#shadow.getElementById('ws-repo-path');
    if (!select) return;

    // Avoid clobbering select while user is actively focused on it.
    if (this.#shadow.activeElement === select && select.options.length > 1) {
      return;
    }

    const repos = this.#discoveredRepos.length > 0
      ? this.#discoveredRepos
      : (this.#repoCtx?.effective_root
        ? [{
            name: String(this.#repoCtx.effective_root).split('/').filter(Boolean).pop() || 'workspace',
            path: String(this.#repoCtx.effective_root),
          }]
        : []);

    const opts = repos.map((r) => {
      const selected = r.path === this.#selectedRepoPath;
      return `<option value="${this.#escape(r.path)}" ${selected ? 'selected' : ''}>${this.#escape(r.name)}</option>`;
    });
    opts.push(`<option value="__custom__">+ Enter another local git repo path…</option>`);
    select.innerHTML = opts.join('');

    if (pathEl) {
      pathEl.textContent = this.#selectedRepoPath || '';
      pathEl.title = this.#selectedRepoPath || '';
    }
  }

  #renderMissionsList() {
    const host = this.#shadow.getElementById('ws-missions-host');
    if (!host) return;

    // Preserve any text typed into a decision or add-step input across background polls.
    const activeEl = this.#shadow.activeElement;
    if (activeEl && activeEl.matches && activeEl.matches('.msn-decision-input, .msn-add-step-input')) {
      return;
    }

    if (this.#missions.length === 0) {
      host.innerHTML = `
        <div class="ws-empty-missions">
          <strong>No active missions yet.</strong><br>
          Pick any repository above (like <code>BEAST-MODE</code>, <code>Froogle</code>, or <code>almanac</code>) and click <strong>Scout &amp; Revive Repo (0→1)</strong>—or paste a product dream and click <strong>Architect Mission Plan →</strong> to see Chump break it into an autonomous roadmap.
        </div>
      `;
      return;
    }

    host.innerHTML = this.#missions.map((m) => this.#renderMissionCard(m)).join('');
    this.#wireMissionCardEvents(host);
  }

  #renderMissionCard(m) {
    const isDraft = m.status === 'draft';
    const isRunning = m.status === 'running' || m.is_running;
    const isDecision = m.status === 'needs_decision';
    const isCompleted = m.status === 'completed';
    const isFailed = m.status === 'failed';

    const statusBadge = isDraft
      ? `<span class="ws-badge accent">Step 2 · Draft Plan Ready for Approval</span>`
      : isRunning
        ? `<span class="ws-badge ok">● Factory Running (Auto-Merge On)</span>`
        : isDecision
          ? `<span class="ws-badge bronze">⚠ Paused for Founder Decision</span>`
          : isCompleted
            ? `<span class="ws-badge ok">✓ Mission Shipped (100%)</span>`
            : isFailed
              ? `<span class="ws-badge err">✗ Step Needs Attention</span>`
              : `<span class="ws-badge">⏸ Paused</span>`;

    const repoBadge = m.repo_mode === 'new' && isDraft
      ? `<span class="ws-badge bronze">NEW REPO: ~/Projects/${this.#escape(m.repo_name)}</span>`
      : `<span class="ws-badge" title="${this.#escape(m.repo_path)}">repo: ${this.#escape(m.repo_name)}</span>`;

    const l1Badge = `<span class="ws-badge">L1 Foundation: ${m.l1_passed ?? 0}/${m.l1_total ?? 5}</span>`;
    const runnerBadge = `<span class="ws-badge">runner: ${this.#escape(m.runner || 'auto')}</span>`;

    const progressHtml = !isDraft
      ? `
        <div class="msn-progress-wrap">
          <div class="msn-progress-meta">
            <span>${m.completed_steps} of ${m.total_steps} milestones shipped (${m.progress_pct}%)</span>
            <span>${isCompleted ? 'All done criteria verified' : 'Anti-cosmetic test gate active'}</span>
          </div>
          <div class="msn-progress-bar" role="progressbar" aria-valuenow="${m.progress_pct}" aria-valuemin="0" aria-valuemax="100">
            <div class="msn-progress-fill" style="width:${m.progress_pct}%"></div>
          </div>
        </div>
      `
      : '';

    const decisionHtml = m.pending_decision
      ? `
        <div class="msn-decision-box">
          <span class="msn-decision-label">Founder Product / Architecture Decision</span>
          <div class="msn-decision-q">${this.#escape(m.pending_decision.question)}</div>
          <div class="msn-decision-row">
            <input type="text" class="msn-decision-input" data-decision-input="${this.#escape(m.id)}"
                   placeholder="Type your preference or direction…">
            <button type="button" class="btn btn-primary"
                    data-msn-action="resolve_decision"
                    data-msn-id="${this.#escape(m.id)}"
                    data-step-id="${this.#escape(m.pending_decision.step_id)}">
              Save Answer ${isDraft ? '' : '&amp; Resume Factory →'}
            </button>
          </div>
        </div>
      `
      : '';

    const activeStep = (m.steps || []).find((s) => s.id === m.active_step_id) || (m.steps || []).find((s) => s.state === 'in_progress');
    const liveLogs = activeStep?.log_tail || [];
    const liveBoxHtml = (isRunning || m.live_activity || liveLogs.length > 0) && !isDraft
      ? `
        <div class="msn-live-box">
          <div class="msn-live-head">
            <span class="status-dot"></span>
            <span>${this.#escape(m.live_activity || (activeStep ? `Working on: ${activeStep.title}` : 'Factory active'))}</span>
          </div>
          ${liveLogs.length > 0 ? `<pre class="msn-log-pre">${this.#escape(liveLogs.join('\n'))}</pre>` : ''}
        </div>
      `
      : '';

    const stepsHtml = (m.steps || []).map((s) => {
      const st = s.state || 'pending';
      const icon = !s.enabled
        ? '–'
        : st === 'completed'
          ? '✓'
          : st === 'in_progress'
            ? '●'
            : st === 'failed'
              ? '✗'
              : st === 'skipped'
                ? '↷'
                : String(s.sequence).padStart(2, '0');
      const iconCls = st === 'completed' ? 'ok' : st === 'in_progress' ? 'run' : st === 'failed' ? 'err' : '';
      const layerTone = s.layer === 'L1' ? 'bronze' : s.layer === 'L3' ? 'ok' : 'accent';

      return `
        <div class="msn-step ${this.#escape(st)} ${!s.enabled ? 'disabled' : ''}">
          ${isDraft
            ? `<input type="checkbox" ${s.enabled ? 'checked' : ''} data-toggle-step="${this.#escape(s.id)}" data-msn-id="${this.#escape(m.id)}" aria-label="Include step ${s.sequence}">`
            : `<span class="msn-step-icon ${iconCls}">${this.#escape(icon)}</span>`}
          <div class="msn-step-main">
            <div class="msn-step-top">
              <span class="ws-badge ${layerTone}">${this.#escape(s.layer)}</span>
              <span class="ws-badge">effort: ${this.#escape(s.effort)}</span>
              ${s.gap_id ? `<span class="ws-badge">${this.#escape(s.gap_id)}</span>` : ''}
              <span class="msn-step-title">${this.#escape(s.title)}</span>
            </div>
            <div class="msn-step-desc">${this.#escape(s.description)}</div>
            <div class="msn-step-done">Done when: ${this.#escape(s.done_criterion)}</div>
            ${s.decision_answer ? `<div class="msn-step-done">Decision: ${this.#escape(s.decision_answer)}</div>` : ''}
            ${s.commit_sha ? `<div class="msn-step-receipt">✓ Merged commit ${this.#escape(s.commit_sha)}${s.diff_stat ? ` · ${this.#escape(s.diff_stat)}` : ''}</div>` : ''}
            ${s.error ? `<div class="msn-step-err">${this.#escape(s.error)}</div>` : ''}
          </div>
          <div class="msn-step-actions">
            ${st === 'failed' ? `
              <button type="button" class="btn btn-primary btn-xs" data-msn-action="retry_step" data-msn-id="${this.#escape(m.id)}" data-step-id="${this.#escape(s.id)}">Retry</button>
              <button type="button" class="btn btn-xs" data-msn-action="skip_step" data-msn-id="${this.#escape(m.id)}" data-step-id="${this.#escape(s.id)}">Skip</button>
            ` : ''}
          </div>
        </div>
      `;
    }).join('');

    const addStepHtml = isDraft
      ? `
        <div class="msn-add-step-row">
          <input type="text" class="msn-add-step-input" data-add-step-input="${this.#escape(m.id)}"
                 placeholder="+ Add a custom milestone to this Mission Plan…">
          <button type="button" class="btn btn-xs" data-add-step-btn="${this.#escape(m.id)}">Add Step</button>
        </div>
      `
      : '';

    const footHtml = isDraft
      ? `
        <div class="msn-foot">
          <button type="button" class="btn" data-delete-msn="${this.#escape(m.id)}">Discard Draft</button>
          <button type="button" class="btn btn-primary msn-launch-cta" data-launch-msn="${this.#escape(m.id)}">
            ✓ Approve &amp; Launch Autonomous Factory (${m.total_steps} Steps) →
          </button>
        </div>
      `
      : `
        <div class="msn-foot">
          <span class="msn-step-done">
            ${isCompleted
              ? `Completed all ${m.total_steps} milestones in ${this.#escape(m.repo_name)}.`
              : `Autonomous worktree isolation + test verification active on ${this.#escape(m.repo_name)}.`}
          </span>
          <div class="msn-step-actions">
            ${isRunning
              ? `<button type="button" class="btn" data-msn-action="pause" data-msn-id="${this.#escape(m.id)}">Pause Factory</button>`
              : (!isCompleted
                ? `<button type="button" class="btn btn-primary" data-msn-action="resume" data-msn-id="${this.#escape(m.id)}">Resume Factory →</button>`
                : '')}
            ${!isRunning ? `<button type="button" class="btn btn-xs" data-delete-msn="${this.#escape(m.id)}">Archive / Remove</button>` : ''}
          </div>
        </div>
      `;

    return `
      <article class="msn-card ${isDraft ? 'draft' : ''} ${isDecision ? 'needs-decision' : ''}" data-mission-card="${this.#escape(m.id)}">
        <div class="msn-head">
          <div class="msn-head-top">
            <div class="msn-badges">
              ${statusBadge}
              ${repoBadge}
              ${l1Badge}
              ${runnerBadge}
            </div>
          </div>
          <h2 class="msn-title">${this.#escape(m.title)}</h2>
          <p class="msn-summary">${this.#escape(m.summary)}</p>
          ${progressHtml}
        </div>
        ${decisionHtml}
        ${liveBoxHtml}
        <div class="msn-steps">${stepsHtml}</div>
        ${addStepHtml}
        ${footHtml}
      </article>
    `;
  }

  #wireMissionCardEvents(host) {
    // Toggle draft step enabled/disabled.
    host.querySelectorAll('[data-toggle-step]').forEach((chk) => {
      chk.addEventListener('change', async () => {
        const msnId = chk.dataset.msnId;
        const stepId = chk.dataset.toggleStep;
        if (!msnId || !stepId) return;
        await fetch(`/api/missions/${encodeURIComponent(msnId)}`, {
          method: 'PATCH',
          headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'pwa' },
          body: JSON.stringify({ steps: [{ id: stepId, enabled: chk.checked }] }),
        }).catch(() => {});
        await this.#refreshSimple();
      });
    });

    // Add custom step to draft.
    host.querySelectorAll('[data-add-step-btn]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const msnId = btn.dataset.addStepBtn;
        const inp = host.querySelector(`[data-add-step-input="${msnId}"]`);
        const title = (inp?.value || '').trim();
        if (!msnId || !title) return;
        btn.disabled = true;
        await fetch(`/api/missions/${encodeURIComponent(msnId)}`, {
          method: 'PATCH',
          headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'pwa' },
          body: JSON.stringify({ add_step: { title, layer: 'L2', effort: 'm' } }),
        }).catch(() => {});
        if (inp) inp.value = '';
        await this.#refreshSimple();
      });
    });

    // 1-Click Approve & Launch Autonomous Factory!
    host.querySelectorAll('[data-launch-msn]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const msnId = btn.dataset.launchMsn;
        if (!msnId) return;
        btn.disabled = true;
        btn.textContent = 'Launching Autonomous Factory…';
        try {
          const r = await fetch(`/api/missions/${encodeURIComponent(msnId)}/launch`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'pwa' },
          });
          const d = await r.json().catch(() => ({}));
          if (!r.ok || d.error) throw new Error(d.error || `HTTP ${r.status}`);
          await this.#refreshSimple();
        } catch (err) {
          btn.disabled = false;
          btn.textContent = `Launch failed: ${err.message || err}`;
        }
      });
    });

    // Delete / Discard mission.
    host.querySelectorAll('[data-delete-msn]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const msnId = btn.dataset.deleteMsn;
        if (!msnId) return;
        btn.disabled = true;
        await fetch(`/api/missions/${encodeURIComponent(msnId)}`, {
          method: 'DELETE',
          headers: { 'X-CSRF-Token': 'pwa' },
        }).catch(() => {});
        await this.#refreshSimple();
      });
    });

    // Control actions: pause, resume, retry_step, skip_step, resolve_decision.
    host.querySelectorAll('[data-msn-action]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const msnId = btn.dataset.msnId;
        const action = btn.dataset.msnAction;
        const stepId = btn.dataset.stepId || null;
        if (!msnId || !action) return;
        let decision_answer = null;
        if (action === 'resolve_decision') {
          const inp = host.querySelector(`[data-decision-input="${msnId}"]`);
          decision_answer = (inp?.value || '').trim();
          if (!decision_answer) {
            inp?.focus();
            return;
          }
        }
        btn.disabled = true;
        await fetch(`/api/missions/${encodeURIComponent(msnId)}/control`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'pwa' },
          body: JSON.stringify({ action, step_id: stepId, decision_answer }),
        }).catch(() => {});
        await this.#refreshSimple();
      });
    });
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
            <button type="button" class="btn" id="cmd-simple-mode-btn" title="Return to simple coding workspace">← Simple Workspace</button>
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
    this.#shadow.getElementById('cmd-simple-mode-btn')?.addEventListener('click', () => {
      document.dispatchEvent(new CustomEvent('chump:set-ui-mode', { detail: 'simple' }));
    });
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
