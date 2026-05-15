// web/v2/fleet-message.js — PRODUCT-103
//
// <chump-fleet-message> Web Component: operator-facing compose form for
// firing any a2a event (INTENT / HANDOFF / STUCK / DONE / WARN / ALERT /
// FEEDBACK) from the PWA. POSTs to /api/broadcast (INFRA-1296).
//
// Pairs with <chump-inbox> (PRODUCT-104) for two-way operator comms.

const EVENTS = ['STUCK', 'HANDOFF', 'WARN', 'ALERT', 'FEEDBACK', 'INTENT', 'DONE'];
const FEEDBACK_KINDS = ['defect', 'proposal', 'preference', 'retro'];
const URGENCIES = ['', 'now', 'hours', 'digest'];

const CSS = `
  :host { display: block; }
  form {
    display: grid; gap: 12px; padding: 16px;
    background: var(--bg-secondary, #1a1a1c);
    border: 1px solid var(--border, #2a2a2e);
    border-radius: 10px; max-width: 640px;
  }
  label { display: block; font-size: 12px; color: var(--text-secondary,#8a8a8e); margin-bottom: 4px; }
  select, input, textarea {
    width: 100%; box-sizing: border-box;
    padding: 8px 10px; font-size: 14px;
    background: var(--bg, #0d0d0f); color: var(--text,#e5e5ea);
    border: 1px solid var(--border,#2a2a2e); border-radius: 6px;
    font-family: inherit;
  }
  textarea { min-height: 80px; resize: vertical; }
  .row { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .actions { display: flex; gap: 8px; justify-content: flex-end; align-items: center; }
  button {
    padding: 8px 16px; font-size: 14px; font-weight: 500;
    background: var(--accent, #0a84ff); color: white;
    border: none; border-radius: 6px; cursor: pointer;
  }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  .status { font-size: 12px; color: var(--text-secondary,#8a8a8e); }
  .status.ok { color: #4ec170; }
  .status.err { color: #d65468; }
  .hidden { display: none; }
  .hint { font-size: 11px; color: var(--text-secondary,#8a8a8e); opacity: 0.7; margin-top: 2px; }
`;

class ChumpFleetMessage extends HTMLElement {
  #shadow;
  #activeSessions = [];

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#render();
    this.#loadActiveSessions();
  }

  #render() {
    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <form id="msg-form">
        <div class="row">
          <div>
            <label for="event">Event type</label>
            <select id="event">
              ${EVENTS.map((e) => `<option value="${e}">${e}</option>`).join('')}
            </select>
          </div>
          <div>
            <label for="urgency">Urgency</label>
            <select id="urgency">
              <option value="">(default)</option>
              <option value="now">now</option>
              <option value="hours">hours</option>
              <option value="digest">digest</option>
            </select>
          </div>
        </div>
        <div id="kind-row" class="hidden">
          <label for="kind">Kind</label>
          <select id="kind"></select>
          <div class="hint" id="kind-hint"></div>
        </div>
        <div>
          <label for="subject">Subject (gap-id or policy name)</label>
          <input type="text" id="subject" placeholder="INFRA-1234 or auto-merge-policy" />
        </div>
        <div>
          <label for="recipient">Recipient session (optional; leave blank for fleet broadcast)</label>
          <input type="text" id="recipient" list="active-sessions" placeholder="operator-abc12345 or session-id or fleet-*" />
          <datalist id="active-sessions"></datalist>
        </div>
        <div>
          <label for="rationale">Rationale / message</label>
          <textarea id="rationale" placeholder="what + why + suggested action"></textarea>
        </div>
        <div id="vote-row" class="hidden">
          <label>Vote</label>
          <select id="vote">
            <option value="0">no vote</option>
            <option value="+1">+1 (agree)</option>
            <option value="-1">-1 (disagree)</option>
          </select>
        </div>
        <div class="actions">
          <span id="status" class="status"></span>
          <button type="submit" id="submit">Send</button>
        </div>
      </form>
    `;
    const eventSel = this.#shadow.getElementById('event');
    const kindRow = this.#shadow.getElementById('kind-row');
    const kindSel = this.#shadow.getElementById('kind');
    const kindHint = this.#shadow.getElementById('kind-hint');
    const voteRow = this.#shadow.getElementById('vote-row');

    const onEventChange = () => {
      const e = eventSel.value;
      if (e === 'FEEDBACK') {
        kindRow.classList.remove('hidden');
        kindSel.innerHTML = FEEDBACK_KINDS.map((k) => `<option value="${k}">${k}</option>`).join('');
        kindHint.textContent = 'defect / proposal / preference / retro';
        this.#updateVoteVisibility();
      } else if (e === 'ALERT') {
        kindRow.classList.remove('hidden');
        kindSel.innerHTML = '<option value="">(custom)</option>';
        kindSel.outerHTML = '<input type="text" id="kind" placeholder="alert sub-type, e.g. fleet_wedge" />';
        kindHint.textContent = 'free-form (e.g. fleet_wedge, disk_critical)';
        voteRow.classList.add('hidden');
      } else {
        kindRow.classList.add('hidden');
        voteRow.classList.add('hidden');
      }
    };
    eventSel.addEventListener('change', onEventChange);
    this.#shadow.addEventListener('change', (ev) => {
      if (ev.target.id === 'kind') this.#updateVoteVisibility();
    });
    this.#shadow.getElementById('msg-form').addEventListener('submit', (ev) => {
      ev.preventDefault();
      this.#submit();
    });
  }

  #updateVoteVisibility() {
    const eventSel = this.#shadow.getElementById('event');
    const kindEl = this.#shadow.getElementById('kind');
    const voteRow = this.#shadow.getElementById('vote-row');
    if (eventSel.value === 'FEEDBACK' && kindEl && kindEl.value === 'preference') {
      voteRow.classList.remove('hidden');
    } else {
      voteRow.classList.add('hidden');
    }
  }

  #loadActiveSessions() {
    fetch('/api/fleet-status')
      .then((r) => r.ok ? r.json() : Promise.reject(r.status))
      .then((d) => {
        // fleet-status returns a list of sessions; extract their IDs.
        const sessions = Array.isArray(d) ? d : (d.sessions || d.workers || []);
        this.#activeSessions = sessions
          .map((s) => s.session_id || s.id || s.session || s.name)
          .filter((s) => typeof s === 'string' && s.length > 0);
        const dl = this.#shadow.getElementById('active-sessions');
        if (dl) {
          dl.innerHTML = this.#activeSessions
            .map((s) => `<option value="${s}"></option>`)
            .join('');
        }
      })
      .catch(() => {
        // Best-effort; recipient field still accepts free text.
      });
  }

  async #submit() {
    const status = this.#shadow.getElementById('status');
    const submitBtn = this.#shadow.getElementById('submit');
    const event = this.#shadow.getElementById('event').value;
    const subject = this.#shadow.getElementById('subject').value.trim();
    const rationale = this.#shadow.getElementById('rationale').value.trim();
    const recipient = this.#shadow.getElementById('recipient').value.trim();
    const urgency = this.#shadow.getElementById('urgency').value || undefined;
    const kindEl = this.#shadow.getElementById('kind');
    const kind = kindEl ? kindEl.value.trim() : '';
    const voteEl = this.#shadow.getElementById('vote');
    const vote = voteEl && !voteEl.closest('.hidden') ? voteEl.value : undefined;

    // Client-side validation matching server's per-event requirements.
    const subjectRequired = ['INTENT', 'HANDOFF', 'STUCK', 'DONE', 'FEEDBACK'].includes(event);
    if (subjectRequired && !subject) {
      this.#setStatus(`${event} requires a subject`, 'err');
      return;
    }
    if (event === 'HANDOFF' && !recipient) {
      this.#setStatus('HANDOFF requires a recipient', 'err');
      return;
    }
    if ((event === 'FEEDBACK' || event === 'ALERT') && !kind) {
      this.#setStatus(`${event} requires a kind`, 'err');
      return;
    }

    submitBtn.disabled = true;
    this.#setStatus('Sending…', '');
    const body = {
      event,
      ...(subject ? { subject } : {}),
      ...(rationale ? { rationale } : {}),
      ...(recipient ? { recipient } : {}),
      ...(kind ? { kind } : {}),
      ...(urgency ? { urgency } : {}),
      ...(vote && vote !== '0' ? { vote } : {}),
    };
    try {
      const r = await fetch('/api/broadcast', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!r.ok) {
        const txt = await r.text().catch(() => '');
        throw new Error(`HTTP ${r.status}: ${txt}`);
      }
      this.#setStatus('Sent ✓', 'ok');
      // Clear rationale + subject; preserve event-type + recipient for repeat-send.
      this.#shadow.getElementById('rationale').value = '';
      if (event !== 'HANDOFF') {
        this.#shadow.getElementById('subject').value = '';
      }
    } catch (e) {
      this.#setStatus(`Failed: ${String(e.message || e).slice(0, 200)}`, 'err');
    } finally {
      submitBtn.disabled = false;
    }
  }

  #setStatus(text, cls) {
    const el = this.#shadow.getElementById('status');
    el.textContent = text;
    el.className = `status ${cls}`;
  }
}
customElements.define('chump-fleet-message', ChumpFleetMessage);
