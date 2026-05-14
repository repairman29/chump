// <chump-pr-card pr-number="NNNN"> — INFRA-1011 PR detail widget.
//
// Polls GET /api/pr/{number} every 10s while state is OPEN; stops on
// MERGED/CLOSED. Renders:
//   - title + link
//   - merge readiness badge (Auto-merge armed / Waiting on CI / Ready /
//     Merged / Closed / Dirty)
//   - per-check rows with status icon + deep link to job log on failure
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
      </div>
    `;
  }

  #esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }
}
customElements.define('chump-pr-card', ChumpPrCard);
