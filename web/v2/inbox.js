// web/v2/inbox.js — PRODUCT-104
//
// <chump-inbox> Web Component: operator-facing inbox view.
// Reads GET /api/inbox/<operator-id> (INFRA-1298); shows targeted a2a
// messages with contextual reply buttons that POST /api/broadcast
// (INFRA-1296) to close the loop.
//
// Operator identity resolved from .chump/operator_id (INFRA-1297) via a
// short-lived /api/health-style cookie; fallback: localStorage('operator_id').
// Until INFRA-1297 ships server-side helpers, we rely on the localStorage
// fallback the user sets via a Settings panel (or chump init prompts).

const POLL_MS = 30_000;

const CSS = `
  :host { display: block; font-family: inherit; }
  .empty {
    padding: 24px; text-align: center;
    color: var(--text-secondary, #8a8a8e); font-size: 13px;
  }
  .row {
    display: grid; grid-template-columns: auto 1fr auto;
    gap: 10px; align-items: start;
    padding: 12px 14px; margin-bottom: 8px;
    background: var(--bg-secondary, #1a1a1c);
    border: 1px solid var(--border, #2a2a2e);
    border-radius: 8px;
  }
  .badges { display: flex; flex-direction: column; gap: 4px; min-width: 84px; }
  .badge {
    font-size: 10px; padding: 2px 6px; border-radius: 4px;
    text-align: center; font-weight: 600;
  }
  .badge.event { background: rgba(10,132,255,0.18); color: #6ab8ff; }
  .badge.urgency-now    { background: rgba(204,51,68,0.22);  color: #ff8a99; }
  .badge.urgency-hours  { background: rgba(204,136,0,0.22);  color: #ffc56a; }
  .badge.urgency-digest { background: rgba(120,140,180,0.18); color: #aab5cc; }
  .body { min-width: 0; }
  .meta { font-size: 11px; color: var(--text-secondary,#8a8a8e); margin-bottom: 4px; }
  .subject { font-weight: 600; margin-bottom: 4px; word-wrap: break-word; }
  .rationale {
    font-size: 13px; color: var(--text,#e5e5ea);
    white-space: pre-wrap; word-wrap: break-word;
  }
  .actions { display: flex; flex-direction: column; gap: 4px; min-width: 90px; }
  button {
    padding: 5px 10px; font-size: 12px;
    border-radius: 5px; border: 1px solid var(--border,#2a2a2e);
    background: var(--bg, #0d0d0f); color: var(--text,#e5e5ea); cursor: pointer;
  }
  button:hover { background: var(--bg-tertiary, #25252a); }
  button.primary { background: var(--accent,#0a84ff); color: white; border-color: transparent; }
  button.danger  { color: #d65468; }
  .header {
    display: flex; justify-content: space-between; align-items: center;
    padding: 0 0 12px; border-bottom: 1px solid var(--border,#2a2a2e); margin-bottom: 12px;
  }
  .header .ops { display: flex; gap: 8px; }
  .count { color: var(--text-secondary,#8a8a8e); font-size: 12px; }
`;

function escapeHtml(s) {
  return String(s || '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function ageStr(ts) {
  const t = new Date(ts).getTime();
  if (!t) return '';
  const ms = Date.now() - t;
  if (ms < 60_000) return `${Math.max(1, Math.floor(ms / 1000))}s ago`;
  if (ms < 3_600_000) return `${Math.floor(ms / 60_000)}m ago`;
  if (ms < 86_400_000) return `${Math.floor(ms / 3_600_000)}h ago`;
  return `${Math.floor(ms / 86_400_000)}d ago`;
}

function resolveOperatorId() {
  // PRODUCT-103/104 hook: when INFRA-1297 lands server-side operator-id
  // exposure (planned /api/whoami), prefer that. For now use localStorage,
  // generating a fresh one if absent.
  let id = localStorage.getItem('chump_operator_id');
  if (!id) {
    const rand = Math.random().toString(16).slice(2, 10);
    id = `operator-${rand}`;
    localStorage.setItem('chump_operator_id', id);
  }
  return id;
}

class ChumpInbox extends HTMLElement {
  #shadow;
  #pollTimer = null;
  #operatorId;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#operatorId = this.getAttribute('operator-id') || resolveOperatorId();
    this.#render([]);
    this.#load();
    this.#pollTimer = setInterval(() => this.#load(), POLL_MS);
  }

  disconnectedCallback() {
    if (this.#pollTimer) clearInterval(this.#pollTimer);
  }

  async #load() {
    try {
      const r = await fetch(`/api/inbox/${encodeURIComponent(this.#operatorId)}`);
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const d = await r.json();
      this.#render(d.messages || []);
    } catch (e) {
      this.#render([], `Inbox load failed: ${String(e.message || e)}`);
    }
  }

  #render(messages, errMsg) {
    const rows = (messages || []).map((m, i) => this.#renderRow(m, i)).join('');
    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="header">
        <div>
          <strong>Inbox</strong>
          <span class="count">— ${messages.length} message${messages.length === 1 ? '' : 's'}</span>
        </div>
        <div class="ops">
          <button id="ack-all">Mark all read</button>
          <button id="refresh">Refresh</button>
        </div>
      </div>
      ${errMsg ? `<div class="empty">${escapeHtml(errMsg)}</div>` : ''}
      ${messages.length === 0 && !errMsg
        ? `<div class="empty">No messages. The inbox catches STUCK, HANDOFF and FEEDBACK targeted at <code>${escapeHtml(this.#operatorId)}</code>.</div>`
        : rows}
    `;
    this.#shadow.getElementById('refresh').addEventListener('click', () => this.#load());
    this.#shadow.getElementById('ack-all').addEventListener('click', () => this.#ackAll());
    (messages || []).forEach((m, i) => {
      this.#shadow.querySelectorAll(`[data-msg-idx="${i}"] button[data-action]`)
        .forEach((btn) => btn.addEventListener('click', (ev) => this.#onAction(m, ev.currentTarget.dataset.action)));
    });
  }

  #renderRow(m, i) {
    const event = m.event || '?';
    const urgency = m.urgency || '';
    const subject = m.subject || m.gap || m.corr_id || '(no subject)';
    const rationale = m.rationale || m.reason || '';
    const fromSession = m.session || '?';
    const ts = m.ts || '';
    const urgencyCls = urgency ? `urgency-${urgency}` : '';

    const buttons = [];
    if (event === 'STUCK') {
      buttons.push(`<button class="primary" data-action="take">Take it</button>`);
    } else if (event === 'HANDOFF') {
      buttons.push(`<button class="primary" data-action="accept">Accept</button>`);
      buttons.push(`<button data-action="decline">Decline</button>`);
    } else if (event === 'FEEDBACK') {
      if (m.kind === 'preference') {
        buttons.push(`<button data-action="vote-plus">+1</button>`);
        buttons.push(`<button data-action="vote-minus">-1</button>`);
      }
    }
    buttons.push(`<button data-action="ack">Ack</button>`);
    buttons.push(`<button class="danger" data-action="dismiss">Dismiss</button>`);

    return `
      <div class="row" data-msg-idx="${i}">
        <div class="badges">
          <span class="badge event">${escapeHtml(event)}</span>
          ${m.kind ? `<span class="badge event">${escapeHtml(m.kind)}</span>` : ''}
          ${urgency ? `<span class="badge ${urgencyCls}">${escapeHtml(urgency)}</span>` : ''}
        </div>
        <div class="body">
          <div class="meta">from <code>${escapeHtml(fromSession)}</code> · ${ageStr(ts)}</div>
          <div class="subject">${escapeHtml(subject)}</div>
          ${rationale ? `<div class="rationale">${escapeHtml(rationale)}</div>` : ''}
        </div>
        <div class="actions">${buttons.join('')}</div>
      </div>
    `;
  }

  async #onAction(m, action) {
    switch (action) {
      case 'take':
        await this.#emit({
          event: 'HANDOFF', subject: m.subject || m.gap || m.corr_id || '',
          recipient: this.#operatorId,
          rationale: `Operator took: ${m.rationale || m.reason || ''}`.slice(0, 280),
        });
        await this.#ackUpTo(m.ts);
        break;
      case 'accept':
        // Equivalent: emit INTENT for the gap so siblings see ownership.
        await this.#emit({
          event: 'INTENT', subject: m.subject || m.gap || m.corr_id || '',
          rationale: 'accepted via inbox',
        });
        await this.#ackUpTo(m.ts);
        break;
      case 'decline':
        // Decline = ack only; sender's STUCK will surface to fleet via cooldown.
        await this.#ackUpTo(m.ts);
        break;
      case 'vote-plus':
        await this.#emit({
          event: 'FEEDBACK', kind: 'preference',
          subject: m.subject || m.corr_id || '',
          vote: '+1', rationale: 'via inbox',
        });
        await this.#ackUpTo(m.ts);
        break;
      case 'vote-minus':
        await this.#emit({
          event: 'FEEDBACK', kind: 'preference',
          subject: m.subject || m.corr_id || '',
          vote: '-1', rationale: 'via inbox',
        });
        await this.#ackUpTo(m.ts);
        break;
      case 'ack':
      case 'dismiss':
        await this.#ackUpTo(m.ts);
        break;
    }
    this.#load();
  }

  async #emit(body) {
    try {
      await fetch('/api/broadcast', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
    } catch (e) {
      // Visible toast handled at compose layer; here a console log is fine.
      console.warn('broadcast failed', e);
    }
  }

  async #ackUpTo(ts) {
    try {
      await fetch(`/api/inbox/${encodeURIComponent(this.#operatorId)}/ack`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(ts ? { up_to_ts: ts } : {}),
      });
    } catch (e) {
      console.warn('ack failed', e);
    }
  }

  async #ackAll() {
    await this.#ackUpTo(null);
    this.#load();
  }
}
customElements.define('chump-inbox', ChumpInbox);
