// <chump-workflow-timeline gap-id="X"> — INFRA-1009 live workflow timeline.
//
// Opens an EventSource on /api/gap/{id}/stream, renders four phase cards
// (preflight → claim → execute → ship) that progress in real time as the
// backend emits `gap_workflow_phase` events.
//
// Each card shows:
//   - phase name (humanized)
//   - state icon (pending / running / done / failed)
//   - live duration timer while running
//   - latest message snippet (truncated)
//
// On `workflow_done` SSE event: optionally embeds a <chump-pr-card>
// (INFRA-1011) when the payload carries a PR number — composes cleanly
// without coupling.
//
// Vanilla Web Component (no build, no CDN) — matches existing PWA pattern.

const PHASES = [
  { id: 'preflight', label: 'Preflight' },
  { id: 'claim', label: 'Claim' },
  { id: 'execute', label: 'Execute' },
  { id: 'ship', label: 'Ship' },
];

class ChumpWorkflowTimeline extends HTMLElement {
  static get observedAttributes() { return ['gap-id']; }
  #es = null;
  #phases = new Map();   // phase_id → { status, started_at, ended_at, message, exit_code }
  #tickTimer = null;
  #doneInfo = null;

  connectedCallback() {
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
    };
    if (status === 'done' || status === 'failed') {
      next.ended_at = evt.ts || new Date().toISOString();
    }
    if (!prev.started_at) next.started_at = evt.ts || new Date().toISOString();
    this.#phases.set(id, next);
    this.#renderRows();
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
    this.innerHTML = `
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
    const ol = this.querySelector('.wf-phases');
    if (!ol) { this.#render(); return; }
    ol.innerHTML = PHASES.map((p) => this.#rowFor(p)).join('');
  }

  #rowFor(p) {
    const state = this.#phases.get(p.id);
    const status = state?.status || 'idle';
    const ic = this.#iconFor(status);
    const dur = state ? this.#durationLabel(state) : '';
    const msg = state?.message ? `<span class="wf-msg">${this.#esc(state.message).slice(0, 120)}</span>` : '';
    return `
      <li class="wf-phase wf-phase-${ic.kind}">
        <span class="wf-phase-icon">${ic.icon}</span>
        <span class="wf-phase-name">${p.label}</span>
        <span class="wf-phase-dur">${dur}</span>
        ${msg}
      </li>
    `;
  }

  #showError(msg) {
    this.innerHTML = `<div class="wf-timeline error">timeline unavailable: ${this.#esc(msg)}</div>`;
  }

  #esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }
}
customElements.define('chump-workflow-timeline', ChumpWorkflowTimeline);
