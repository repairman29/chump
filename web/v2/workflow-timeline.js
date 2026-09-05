const PHASES = [
  { id: 'preflight', label: 'Preflight' },
  { id: 'claim', label: 'Claim' },
  { id: 'execute', label: 'Execute' },
  { id: 'ship', label: 'Ship' },
];

// INFRA-1013: max consecutive retries per phase before button is disabled.
const MAX_RETRIES = 3;

// INFRA-1587/INFRA-4663: styles live in a shadow root so this component's
// CSS travels with the .js file instead of web/v2/index.html.
const STYLE = `
  :host { display: block; font-size: 12px; }
  .wf-timeline {
    border: 1px solid var(--border, #2a2a2e);
    border-radius: var(--radius-sm, 6px);
    padding: 8px 12px;
    background: var(--surface, transparent);
    max-width: 520px;
  }
  .wf-header {
    font-size: 11px;
    color: var(--text-tertiary, var(--text-secondary));
    text-transform: uppercase;
    letter-spacing: 0.04em;
    padding-bottom: 4px;
    border-bottom: 1px solid var(--border, #2a2a2e);
    margin-bottom: 6px;
  }
  .wf-phases { list-style: none; padding: 0; margin: 0; }
  .wf-phase {
    display: grid;
    grid-template-columns: 18px 80px 70px 1fr;
    gap: 8px;
    align-items: baseline;
    padding: 3px 0;
    font-variant-numeric: tabular-nums;
  }
  .wf-phase-icon { text-align: center; font-weight: 600; }
  .wf-phase-name { font-weight: 500; }
  .wf-phase-dur {
    color: var(--text-tertiary, var(--text-secondary));
    font-size: 11px;
  }
  .wf-msg {
    color: var(--text-secondary);
    font-size: 11px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .wf-phase-ok      .wf-phase-icon { color: #4ec170; }
  .wf-phase-fail    .wf-phase-icon { color: #d65468; }
  .wf-phase-pending .wf-phase-icon { color: #aab5cc; }
  .wf-phase-idle    .wf-phase-icon { color: var(--text-tertiary, #777); }
  .wf-done {
    margin-top: 8px; padding-top: 6px;
    border-top: 1px solid var(--border, #2a2a2e);
    font-size: 11px; color: #4ec170;
  }
  .wf-timeline.error { color: var(--accent-error, #d65468); }
  /* INFRA-1013: retry/log controls on failed phase cards */
  .wf-fail-actions {
    display: flex; gap: 6px; align-items: center; margin-top: 4px;
  }
  .wf-retry {
    font-size: 10px; padding: 2px 8px; border-radius: 3px; cursor: pointer;
    background: #d65468; color: #fff; border: none;
  }
  .wf-retry:disabled {
    background: #555; color: #999; cursor: not-allowed;
  }
  .wf-log-link {
    font-size: 10px; color: var(--text-secondary, #aab5cc);
  }
  .wf-stdout {
    margin-top: 4px; font-size: 10px;
  }
  .wf-stdout pre {
    background: var(--bg-tertiary, #1a1a1e); padding: 4px 6px; border-radius: 3px;
    white-space: pre-wrap; word-break: break-all; max-height: 80px; overflow: auto;
  }
`;

/**
 * <chump-workflow-timeline gap-id="X"> — INFRA-1009 live workflow timeline.
 *
 * Opens an EventSource on /api/gap/{id}/stream, renders four phase cards
 * (preflight → claim → execute → ship) that progress in real time as the
 * backend emits `gap_workflow_phase` events.
 *
 * Each card shows:
 *   - phase name (humanized)
 *   - state icon (pending / running / done / failed)
 *   - live duration timer while running
 *   - latest message snippet (truncated)
 *
 * On `workflow_done` SSE event: optionally embeds a <chump-pr-card>
 * (INFRA-1011) when the payload carries a PR number — composes cleanly
 * without coupling.
 *
 * Vanilla Web Component (no build, no CDN) — matches existing PWA pattern.
 */
class ChumpWorkflowTimeline extends HTMLElement {
  static get observedAttributes() { return ['gap-id']; }
  #es = null;
  #phases = new Map();   // phase_id → { status, started_at, ended_at, message, exit_code, stdout_tail }
  #tickTimer = null;
  #doneInfo = null;
  #retryCounts = new Map(); // phase_id → retry count
  #root = null;

  connectedCallback() {
    this.#root = this.shadowRoot || this.attachShadow({ mode: 'open' });
    this.#render();
    this.#connect();
    // 1Hz tick to update the duration counters of running phases.
    this.#tickTimer = setInterval(() => this.#renderRows(), 1000);
  }

  disconnectedCallback() {
    this.#close();
    if (this.#tickTimer) clearInterval(this.#tickTimer);
  }

  attributeChangedCallback(name, oldV, newV) {
    if (name === 'gap-id' && oldV !== newV) {
      this.#close();
      this.#phases.clear();
      this.#retryCounts.clear();
      this.#doneInfo = null;
      this.#connect();
    }
  }

  #connect() {
    const gap = this.getAttribute('gap-id');
    if (!gap) return;
    try {
      this.#es = new EventSource(`/api/gap/${encodeURIComponent(gap)}/stream`);
    } catch (e) {
      this.#showError('cannot open stream: ' + e);
      return;
    }
    this.#es.addEventListener('phase', (e) => {
      try { this.#applyPhase(JSON.parse(e.data)); } catch {}
    });
    this.#es.addEventListener('workflow_done', (e) => {
      try { this.#doneInfo = JSON.parse(e.data); } catch { this.#doneInfo = { done: true }; }
      this.#render();
      this.#close();
    });
    this.#es.onerror = () => {
      // EventSource auto-reconnects; surface a soft indicator.
      this.#renderRows();
    };
  }

  #close() {
    if (this.#es) { try { this.#es.close(); } catch {} this.#es = null; }
  }

  #applyPhase(evt) {
    const id = evt.phase || evt.workflow_phase;
    if (!id) return;
    const known = PHASES.some((p) => p.id === id);
    if (!known) return;
    const prev = this.#phases.get(id) || { status: 'running', started_at: evt.ts || new Date().toISOString(), message: '' };
    const status = evt.phase_status === 'complete' ? 'done'
                 : evt.phase_status === 'failed' ? 'failed'
                 : 'running';
    const next = {
      ...prev,
      status,
      message: evt.message || prev.message,
      exit_code: evt.exit_code ?? prev.exit_code,
      stdout_tail: evt.stdout_tail ?? prev.stdout_tail,
    };
    if (status === 'done' || status === 'failed') {
      next.ended_at = evt.ts || new Date().toISOString();
    }
    if (!prev.started_at) next.started_at = evt.ts || new Date().toISOString();
    this.#phases.set(id, next);
    this.#renderRows();
  }

  // INFRA-1013: trigger retry from a phase via POST /api/gap/work/{id}/retry?from_phase=<p>
  async #retryPhase(phaseId) {
    const gap = this.getAttribute('gap-id');
    if (!gap) return;
    const count = (this.#retryCounts.get(phaseId) || 0) + 1;
    this.#retryCounts.set(phaseId, count);
    this.#renderRows(); // update button state immediately
    try {
      const resp = await fetch(
        `/api/gap/work/${encodeURIComponent(gap)}/retry?from_phase=${encodeURIComponent(phaseId)}`,
        { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' } }
      );
      const body = await resp.json();
      if (body.status === 'max_retries_exceeded') {
        // Show "manual intervention" state — button already disabled from count check
        const state = this.#phases.get(phaseId) || {};
        this.#phases.set(phaseId, { ...state, message: 'Max retries exceeded — manual intervention required' });
        this.#renderRows();
      } else {
        // Retry started — reset phase to running to show progress
        const state = this.#phases.get(phaseId) || {};
        this.#phases.set(phaseId, { ...state, status: 'running', ended_at: undefined });
        this.#renderRows();
        if (!this.#es) this.#connect(); // re-subscribe to stream if closed
      }
    } catch (e) {
      console.error('[workflow-timeline] retry failed:', e);
    }
  }

  #durationLabel(p) {
    if (!p.started_at) return '';
    const start = Date.parse(p.started_at);
    const end = p.ended_at ? Date.parse(p.ended_at) : Date.now();
    const ms = Math.max(0, end - start);
    if (ms < 1000) return `${ms}ms`;
    if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
    const m = Math.floor(ms / 60000);
    const s = Math.floor((ms % 60000) / 1000);
    return `${m}m${s.toString().padStart(2, '0')}s`;
  }

  #iconFor(status) {
    if (status === 'done') return { icon: '✓', kind: 'ok' };
    if (status === 'failed') return { icon: '✗', kind: 'fail' };
    if (status === 'running') return { icon: '⏵', kind: 'pending' };
    return { icon: '·', kind: 'idle' };
  }

  #render() {
    const gap = this.getAttribute('gap-id') || '?';
    const rowsHtml = PHASES.map((p) => this.#rowFor(p)).join('');
    const doneBanner = this.#doneInfo
      ? `<div class="wf-done">workflow complete${this.#doneInfo.pr ? ` — <a href="${this.#doneInfo.url || '#'}" target="_blank">PR #${this.#doneInfo.pr}</a>` : ''}</div>`
      : '';
    this.#root.innerHTML = `
      <style>${STYLE}</style>
      <div class="wf-timeline">
        <div class="wf-header"><span>Workflow ${this.#esc(gap)}</span></div>
        <ol class="wf-phases">${rowsHtml}</ol>
        ${doneBanner}
        ${this.#doneInfo && this.#doneInfo.pr
          ? `<chump-pr-card pr-number="${this.#doneInfo.pr}"></chump-pr-card>`
          : ''}
      </div>
    `;
  }

  #renderRows() {
    // Hot-path: only re-render the phase rows, not the whole tree (saves a flash).
    const ol = this.#root.querySelector('.wf-phases');
    if (!ol) { this.#render(); return; }
    ol.innerHTML = PHASES.map((p) => this.#rowFor(p)).join('');
  }

  #rowFor(p) {
    const state = this.#phases.get(p.id);
    const status = state?.status || 'idle';
    const ic = this.#iconFor(status);
    const dur = state ? this.#durationLabel(state) : '';
    const msg = state?.message ? `<span class="wf-msg">${this.#esc(state.message).slice(0, 120)}</span>` : '';

    // INFRA-1013: retry controls for failed phases
    let failureExtra = '';
    if (status === 'failed') {
      const gap = this.getAttribute('gap-id') || '';
      const retryCount = this.#retryCounts.get(p.id) || 0;
      const exhausted = retryCount >= MAX_RETRIES;
      const retryBtn = exhausted
        ? `<button class="wf-retry" disabled title="Manual intervention recommended after ${MAX_RETRIES} retries">Retry (exhausted)</button>`
        : `<button class="wf-retry" data-phase="${this.#esc(p.id)}" onclick="this.getRootNode().host.retryPhase('${this.#esc(p.id)}')">Retry phase</button>`;
      const stdoutSection = state?.stdout_tail
        ? `<details class="wf-stdout"><summary>Last output</summary><pre>${this.#esc(state.stdout_tail)}</pre></details>`
        : '';
      const requestId = state?.request_id || '';
      const logLink = requestId
        ? `<a class="wf-log-link" href="/api/logs/${encodeURIComponent(requestId)}" target="_blank">View full log</a>`
        : '';
      failureExtra = `<div class="wf-fail-actions">${retryBtn}${logLink}</div>${stdoutSection}`;
    }

    return `
      <li class="wf-phase wf-phase-${ic.kind}">
        <span class="wf-phase-icon">${ic.icon}</span>
        <span class="wf-phase-name">${p.label}</span>
        <span class="wf-phase-dur">${dur}</span>
        ${msg}
        ${failureExtra}
      </li>
    `;
  }

  // Public method for inline onclick handlers
  retryPhase(phaseId) {
    this.#retryPhase(phaseId);
  }

  #showError(msg) {
    this.#root.innerHTML = `<style>${STYLE}</style><div class="wf-timeline error">timeline unavailable: ${this.#esc(msg)}</div>`;
  }

  #esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }
}
customElements.define('chump-workflow-timeline', ChumpWorkflowTimeline);
