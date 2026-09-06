// <chump-pr-card pr-number="NNNN"> — INFRA-1011 PR detail widget + PRODUCT-086 action panel.
//
// Polls GET /api/pr/{number} every 10s while state is OPEN; stops on
// MERGED/CLOSED. Renders:
//   - title + link
//   - merge readiness badge (Auto-merge armed / Waiting on CI / Ready /
//     Merged / Closed / Dirty)
//   - per-check rows with status icon + deep link to job log on failure
//   - PRODUCT-086: action panel with Approve, Request changes, Comment, Revert buttons
//     (disabled when PR state doesn't permit them)
//
// Vanilla Web Component to match existing PWA pattern (no build, no CDN).
// Attribute: pr-number — number of the PR to track. Required.
//
// Usage:
//   <chump-pr-card pr-number="1822"></chump-pr-card>

const CSS = `
  :host {
    display: block;
    font-size: 12px;
    color: var(--text-primary);
  }
  .pr-card {
    border: 1px solid var(--border, #2a2a2e);
    border-radius: var(--radius-sm, 6px);
    padding: 8px 12px;
    background: var(--surface, transparent);
    max-width: 480px;
  }
  .pr-card.loading,
  .pr-card.error { opacity: 0.6; }
  .pr-card-header {
    display: flex; justify-content: space-between; align-items: center;
    gap: 8px; margin-bottom: 6px;
  }
  .pr-card-title {
    color: inherit; text-decoration: none; font-weight: 500;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .pr-card-title:hover { text-decoration: underline; }
  .pr-card-badge {
    font-size: 10px; padding: 2px 8px; border-radius: 10px;
    white-space: nowrap;
  }
  .pr-card-badge-ok      { background: rgba(60,180,90,0.18);  color: #4ec170; }
  .pr-card-badge-warn    { background: rgba(204,136,0,0.18);  color: #d99a23; }
  .pr-card-badge-fail    { background: rgba(204,51,68,0.18);  color: #d65468; }
  .pr-card-badge-pending { background: rgba(120,140,180,0.18); color: #aab5cc; }
  .pr-card-checks {
    list-style: none; padding: 0; margin: 0;
    max-height: 220px; overflow-y: auto;
  }
  .pr-check {
    display: flex; gap: 6px; align-items: center;
    font-size: 11px; padding: 1px 0;
  }
  .pr-check-icon { width: 14px; text-align: center; font-weight: 600; }
  .pr-check-ok      .pr-check-icon { color: #4ec170; }
  .pr-check-fail    .pr-check-icon { color: #d65468; }
  .pr-check-pending .pr-check-icon { color: #aab5cc; }
  .pr-check-skip    .pr-check-icon { color: var(--text-tertiary, #777); }
  .pr-check a { color: inherit; text-decoration: none; }
  .pr-check a:hover { text-decoration: underline; }
  .pr-check-empty {
    font-style: italic; color: var(--text-tertiary, #777);
    font-size: 11px; padding-top: 4px;
  }
  .pr-card-sha {
    margin-top: 6px; font-size: 10px;
    color: var(--text-tertiary, var(--text-secondary));
    font-family: ui-monospace, SFMono-Regular, monospace;
  }

  /* PRODUCT-086: PR action panel — approve, request changes, comment, revert buttons. */
  .pr-card-actions {
    display: flex; gap: 6px; margin-top: 10px; flex-wrap: wrap;
  }
  .pr-action-btn {
    padding: 6px 12px; font-size: 12px;
    border: 1px solid var(--border, #2a2a2e);
    background: var(--surface, #1a1a1e);
    color: var(--text, #ddd);
    border-radius: 4px; cursor: pointer;
    transition: all 150ms ease;
  }
  .pr-action-btn:hover:not(:disabled) {
    background: var(--accent, #2a4a7a);
    border-color: var(--accent, #4a7abb);
  }
  .pr-action-btn:disabled {
    opacity: 0.5; cursor: not-allowed;
  }

  /* Mobile-friendly action panel: smaller buttons and text wrap on narrow viewports */
  @media (max-width: 640px) {
    .pr-action-btn {
      padding: 4px 8px; font-size: 11px; flex: 1; min-width: 60px;
    }
  }
`;

// PRODUCT-086: Action modal — appears when user clicks approve/request-changes/comment.
// This modal is appended to document.body (outside any shadow root, so it can
// overlay the whole viewport with position:fixed) — its CSS therefore can't
// live in ChumpPrCard's shadow <style> and is injected into document.head
// once instead.
const MODAL_CSS = `
  .pr-action-modal {
    position: fixed; top: 0; left: 0; right: 0; bottom: 0;
    z-index: 1000; display: flex; align-items: center; justify-content: center;
  }
  .pr-action-modal-overlay {
    position: absolute; top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0,0,0,0.6);
  }
  .pr-action-modal-content {
    position: relative; background: var(--surface, #1a1a1e);
    border: 1px solid var(--border, #2a2a2e);
    border-radius: 8px; box-shadow: 0 4px 16px rgba(0,0,0,0.4);
    width: 90%; max-width: 500px; max-height: 80vh;
    overflow-y: auto;
  }
  .pr-action-modal-header {
    display: flex; justify-content: space-between; align-items: center;
    padding: 16px; border-bottom: 1px solid var(--border, #2a2a2e);
  }
  .pr-action-modal-header h2 {
    margin: 0; font-size: 18px; font-weight: 600;
  }
  .pr-action-modal-close {
    background: transparent; border: none; font-size: 24px;
    cursor: pointer; color: var(--text, #ddd);
    padding: 0; width: 30px; height: 30px;
  }
  .pr-action-modal-close:hover { color: var(--accent, #4a7abb); }
  .pr-action-modal-body {
    padding: 16px;
  }
  .pr-action-modal-textarea {
    width: 100%; padding: 10px; font-size: 13px;
    border: 1px solid var(--border, #2a2a2e);
    background: var(--input-bg, #0a0a0e);
    color: var(--text, #ddd);
    border-radius: 4px; font-family: ui-monospace, monospace;
    min-height: 100px; resize: vertical;
  }
  .pr-action-modal-textarea:focus { outline: none; border-color: var(--accent, #4a7abb); }
  .pr-action-modal-footer {
    display: flex; gap: 8px; justify-content: flex-end;
    padding: 16px; border-top: 1px solid var(--border, #2a2a2e);
  }
  .pr-action-modal-cancel, .pr-action-modal-submit {
    padding: 8px 16px; font-size: 12px;
    border: 1px solid var(--border, #2a2a2e);
    background: var(--surface, #1a1a1e);
    color: var(--text, #ddd);
    border-radius: 4px; cursor: pointer;
  }
  .pr-action-modal-submit {
    background: var(--accent, #2a4a7a);
    border-color: var(--accent, #4a7abb);
    color: #fff;
  }
  .pr-action-modal-submit:hover { background: var(--accent-hover, #3a5a8a); }
  .pr-action-modal-cancel:hover { background: var(--border, #2a2a2e); }
`;

let modalStylesInjected = false;
function ensureModalStylesInjected() {
  if (modalStylesInjected) return;
  modalStylesInjected = true;
  const style = document.createElement('style');
  style.textContent = MODAL_CSS;
  document.head.appendChild(style);
}

/**
 * INFRA-1011: <chump-pr-card pr-number="N"> — embeddable PR detail tile.
 * Renders state badge + per-check rows. Auto-mounts where a host UI puts
 * it (sidebar, agents view, workflow timeline); no layout opinions here.
 *
 * PRODUCT-086: adds an action panel (Approve / Request changes / Comment /
 * Revert) and a comment modal appended to document.body on click.
 */
class ChumpPrCard extends HTMLElement {
  static get observedAttributes() { return ['pr-number']; }
  #timer = null;
  #stopped = false;
  #data = null;
  #shadow;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#render({ loading: true });
    this.#poll();
    this.#startTimer();
  }

  disconnectedCallback() {
    this.#clearTimer();
  }

  attributeChangedCallback(name, oldV, newV) {
    if (name === 'pr-number' && oldV !== newV) {
      this.#stopped = false;
      this.#poll();
    }
  }

  #startTimer() {
    this.#clearTimer();
    this.#timer = setInterval(() => {
      if (this.#stopped) return;
      this.#poll();
    }, 10_000);
  }

  #clearTimer() {
    if (this.#timer) { clearInterval(this.#timer); this.#timer = null; }
  }

  #poll() {
    const n = this.getAttribute('pr-number');
    if (!n) { this.#render({ error: 'no pr-number attribute' }); return; }
    fetch(`/api/pr/${encodeURIComponent(n)}`)
      .then((r) => {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then((d) => {
        this.#data = d;
        this.#render({ data: d });
        // Stop polling once the PR is settled.
        const s = (d.state || '').toUpperCase();
        if (s === 'MERGED' || s === 'CLOSED') {
          this.#stopped = true;
          this.#clearTimer();
        }
      })
      .catch((e) => this.#render({ error: String(e).slice(0, 60), pr: n }));
  }

  #badgeFor(d) {
    const s = (d.state || '').toUpperCase();
    const ms = (d.merge_state_status || '').toUpperCase();
    if (s === 'MERGED') return { label: 'Merged', kind: 'ok' };
    if (s === 'CLOSED') return { label: 'Closed (unmerged)', kind: 'warn' };
    if (d.auto_merge) {
      const method = d.auto_merge_method || 'SQUASH';
      return { label: `Auto-merge armed (${method})`, kind: 'pending' };
    }
    if (ms === 'CLEAN') return { label: 'Ready to merge', kind: 'ok' };
    if (ms === 'DIRTY') return { label: 'Dirty (rebase needed)', kind: 'warn' };
    if (ms === 'BLOCKED') return { label: 'Blocked', kind: 'warn' };
    if (ms === 'BEHIND') return { label: 'Behind base — update needed', kind: 'warn' };
    if (ms === 'UNSTABLE') return { label: 'Unstable (non-required CI failing)', kind: 'warn' };
    return { label: ms || 'Unknown', kind: 'pending' };
  }

  #checkIcon(c) {
    const conc = (c.conclusion || '').toUpperCase();
    const stat = (c.status || '').toUpperCase();
    if (conc === 'SUCCESS') return { icon: '✓', kind: 'ok' };
    if (conc === 'FAILURE') return { icon: '✗', kind: 'fail' };
    if (conc === 'SKIPPED' || conc === 'NEUTRAL') return { icon: '∅', kind: 'skip' };
    if (stat === 'IN_PROGRESS' || stat === 'QUEUED' || stat === 'PENDING') return { icon: '⏵', kind: 'pending' };
    return { icon: '?', kind: 'skip' };
  }

  #canApprove(d) {
    return (d.state || '').toUpperCase() === 'OPEN';
  }

  #canRequestChanges(d) {
    return (d.state || '').toUpperCase() === 'OPEN';
  }

  #canComment(d) {
    return (d.state || '').toUpperCase() === 'OPEN';
  }

  #canRevert(d) {
    return (d.state || '').toUpperCase() === 'MERGED';
  }

  #setupActions(el) {
    const prNum = this.getAttribute('pr-number');
    const d = this.#data || {};

    // Approve button
    const approveBtn = el.querySelector('.pr-action-approve');
    if (approveBtn) {
      approveBtn.disabled = !this.#canApprove(d);
      approveBtn.addEventListener('click', () => this.#showCommentModal('approve', prNum));
    }

    // Request changes button
    const reqChangesBtn = el.querySelector('.pr-action-request-changes');
    if (reqChangesBtn) {
      reqChangesBtn.disabled = !this.#canRequestChanges(d);
      reqChangesBtn.addEventListener('click', () => this.#showCommentModal('request_changes', prNum));
    }

    // Comment button
    const commentBtn = el.querySelector('.pr-action-comment');
    if (commentBtn) {
      commentBtn.disabled = !this.#canComment(d);
      commentBtn.addEventListener('click', () => this.#showCommentModal('comment', prNum));
    }

    // Revert button
    const revertBtn = el.querySelector('.pr-action-revert');
    if (revertBtn) {
      revertBtn.disabled = !this.#canRevert(d);
      revertBtn.addEventListener('click', () => {
        if (confirm(`Are you sure you want to revert PR #${prNum}? This will create a new PR with the revert.`)) {
          this.#performAction('revert', prNum, null);
        }
      });
    }
  }

  #showCommentModal(action, prNum) {
    ensureModalStylesInjected();
    const modal = document.createElement('div');
    modal.className = 'pr-action-modal';
    modal.innerHTML = `
      <div class="pr-action-modal-overlay"></div>
      <div class="pr-action-modal-content">
        <div class="pr-action-modal-header">
          <h2>${action === 'approve' ? 'Approve PR' : action === 'request_changes' ? 'Request Changes' : 'Comment'}</h2>
          <button class="pr-action-modal-close">×</button>
        </div>
        <div class="pr-action-modal-body">
          <textarea class="pr-action-modal-textarea" placeholder="Optional comment..."></textarea>
        </div>
        <div class="pr-action-modal-footer">
          <button class="pr-action-modal-cancel">Cancel</button>
          <button class="pr-action-modal-submit">Submit</button>
        </div>
      </div>
    `;

    const closeBtn = modal.querySelector('.pr-action-modal-close');
    const cancelBtn = modal.querySelector('.pr-action-modal-cancel');
    const submitBtn = modal.querySelector('.pr-action-modal-submit');
    const textarea = modal.querySelector('.pr-action-modal-textarea');

    const close = () => modal.remove();
    closeBtn.addEventListener('click', close);
    cancelBtn.addEventListener('click', close);

    submitBtn.addEventListener('click', () => {
      this.#performAction(action, prNum, textarea.value);
      close();
    });

    document.body.appendChild(modal);
    textarea.focus();
  }

  #performAction(action, prNum, body) {
    const endpoint = `/api/prs/${prNum}/${action}`;
    const payload = body !== null ? { body } : {};

    const btn = this.#shadow.querySelector(`.pr-action-${action}`);
    if (btn) btn.disabled = true;

    // Get session ID from sessionStorage if available
    const sessionId = sessionStorage.getItem('chump_session_id') || 'pwa-inline';

    fetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Session-ID': sessionId,
      },
      body: JSON.stringify(payload),
    })
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then(() => {
        // Refresh PR state after action
        this.#poll();
      })
      .catch((e) => {
        alert(`Action failed: ${e.message}`);
        if (btn) btn.disabled = false;
      });
  }

  #render({ loading, error, data, pr }) {
    if (loading) {
      this.#shadow.innerHTML = `<style>${CSS}</style><div class="pr-card loading">loading PR…</div>`;
      return;
    }
    if (error) {
      this.#shadow.innerHTML = `<style>${CSS}</style><div class="pr-card error">PR #${pr ?? ''} unavailable (${error})</div>`;
      return;
    }
    const d = data;
    const badge = this.#badgeFor(d);
    const checks = (d.checks || []).map((c) => {
      const ic = this.#checkIcon(c);
      const linkOpen = c.link ? `<a href="${c.link}" target="_blank" rel="noopener">` : '';
      const linkClose = c.link ? `</a>` : '';
      return `<li class="pr-check pr-check-${ic.kind}"><span class="pr-check-icon">${ic.icon}</span> ${linkOpen}${this.#esc(c.name)}${linkClose}</li>`;
    }).join('');

    const actionPanel = `
      <div class="pr-card-actions">
        <button class="pr-action-btn pr-action-approve" title="Approve this PR">Approve</button>
        <button class="pr-action-btn pr-action-request-changes" title="Request changes">Request changes</button>
        <button class="pr-action-btn pr-action-comment" title="Add a comment">Comment</button>
        <button class="pr-action-btn pr-action-revert" title="Revert this PR">Revert</button>
      </div>
    `;

    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="pr-card">
        <div class="pr-card-header">
          <a class="pr-card-title" href="${d.url || '#'}" target="_blank" rel="noopener">
            #${d.number} ${this.#esc(d.title || '')}
          </a>
          <span class="pr-card-badge pr-card-badge-${badge.kind}">${badge.label}</span>
        </div>
        <ul class="pr-card-checks">${checks || '<li class="pr-check-empty">no checks yet</li>'}</ul>
        ${d.head_sha ? `<div class="pr-card-sha" title="head SHA">${String(d.head_sha).slice(0, 8)} → ${this.#esc(d.base_branch || 'main')}</div>` : ''}
        ${actionPanel}
      </div>
    `;

    // Setup action listeners after rendering
    this.#setupActions(this.#shadow);
  }

  #esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }
}
customElements.define('chump-pr-card', ChumpPrCard);
