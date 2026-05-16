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

class ChumpPrCard extends HTMLElement {
  static get observedAttributes() { return ['pr-number']; }
  #timer = null;
  #stopped = false;
  #data = null;

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

    const btn = this.querySelector(`.pr-action-${action}`);
    if (btn) btn.disabled = true;

    fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
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
      this.innerHTML = `<div class="pr-card loading">loading PR…</div>`;
      return;
    }
    if (error) {
      this.innerHTML = `<div class="pr-card error">PR #${pr ?? ''} unavailable (${error})</div>`;
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

    this.innerHTML = `
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
    this.#setupActions(this);
  }

  #esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }
}
customElements.define('chump-pr-card', ChumpPrCard);
