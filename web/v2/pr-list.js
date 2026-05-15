// <chump-view-prs> — PRODUCT-084 PR list view.
//
// Polls GET /api/prs every 30s and renders three sections:
//   Open         — all open PRs (newest → oldest)
//   Just shipped — merged in the last 24 h
//   Stuck        — open PRs that are DIRTY/BLOCKED for > 4 h
//
// Each row: #N, title, author, age, merge-state badge, CI summary, GitHub link.
// Click on a row → dispatches chump:pr-detail with {number} for PRODUCT-085.
//
// Vanilla Web Component; no build step, no CDN. Air-gap safe.

const POLL_MS = 30_000;

class ChumpViewPrs extends HTMLElement {
  #timer = null;
  #controller = null;

  connectedCallback() {
    this.#render({ loading: true });
    this.#poll();
    this.#timer = setInterval(() => this.#poll(), POLL_MS);
  }

  disconnectedCallback() {
    clearInterval(this.#timer);
    this.#timer = null;
    this.#controller?.abort();
  }

  async #poll() {
    this.#controller?.abort();
    this.#controller = new AbortController();
    try {
      const r = await fetch('/api/prs', { signal: this.#controller.signal });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const d = await r.json();
      this.#render({ data: d });
    } catch (e) {
      if (e.name === 'AbortError') return;
      this.#render({ error: String(e).slice(0, 80) });
    }
  }

  // ── Render ────────────────────────────────────────────────────────────────

  #render({ loading, error, data }) {
    if (loading) {
      this.innerHTML = `<div class="prl-shell"><div class="prl-loading">Loading PRs…</div></div>`;
      return;
    }
    if (error) {
      this.innerHTML = `<div class="prl-shell prl-error">PR list unavailable: ${this.#esc(error)}</div>`;
      return;
    }

    const open       = data.open        ?? [];
    const merged     = data.just_merged ?? [];
    const stuck      = data.stuck       ?? [];
    const lastShipS  = data.last_ship_ago_s;

    const openHtml   = this.#section('Open',          open,   true,  lastShipS);
    const mergedHtml = this.#section('Just shipped',  merged, false, lastShipS);
    const stuckHtml  = stuck.length
      ? this.#section('Stuck (>4 h DIRTY/BLOCKED)', stuck, true, null)
      : '';

    const fetched = data.fetched_at_s
      ? new Date(data.fetched_at_s * 1000).toLocaleTimeString()
      : '—';

    this.innerHTML = `
      <style>
        .prl-shell      { padding:16px 20px; max-width:1200px; font-family:var(--font,system-ui,sans-serif); }
        .prl-header     { display:flex; align-items:baseline; gap:12px; margin-bottom:16px; }
        .prl-title      { font-size:18px; font-weight:600; color:var(--text,#e0e0e0); }
        .prl-fetched    { font-size:11px; color:var(--text-secondary,#888); }
        .prl-section    { margin-bottom:20px; }
        .prl-section-hdr{ font-size:12px; text-transform:uppercase; letter-spacing:.06em;
                          color:var(--text-secondary,#888); margin-bottom:8px;
                          display:flex; align-items:center; gap:6px; }
        .prl-count      { background:rgba(255,255,255,.08); padding:1px 6px; border-radius:10px;
                          font-size:11px; }
        .prl-empty      { color:var(--text-secondary,#888); font-size:13px; padding:8px 4px; }
        .prl-table      { width:100%; border-collapse:collapse; }
        .prl-row        { cursor:pointer; border-bottom:1px solid var(--border,rgba(255,255,255,.06));
                          transition:background .1s; }
        .prl-row:hover  { background:var(--bg-elevated,rgba(255,255,255,.04)); }
        .prl-num        { width:52px; padding:8px 6px; color:var(--accent,#4a9eff);
                          font-variant-numeric:tabular-nums; white-space:nowrap; font-size:13px; }
        .prl-ttitle     { padding:8px 6px; font-size:13px; color:var(--text,#e0e0e0);
                          max-width:440px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .prl-author     { width:100px; padding:8px 6px; font-size:12px; color:var(--text-secondary,#888);
                          overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .prl-age        { width:72px; padding:8px 6px; font-size:12px;
                          color:var(--text-secondary,#888); white-space:nowrap; }
        .prl-state      { width:110px; padding:8px 6px; }
        .prl-ci         { width:60px; padding:8px 6px; font-size:12px; text-align:center; }
        .prl-gh         { width:32px; padding:8px 4px; text-align:center; }
        .prl-badge      { display:inline-block; padding:2px 7px; border-radius:4px; font-size:11px;
                          font-weight:500; white-space:nowrap; }
        .badge-ok       { background:rgba(50,215,75,.15); color:#32d74b; }
        .badge-warn     { background:rgba(255,159,10,.15); color:#ff9f0a; }
        .badge-pending  { background:rgba(10,132,255,.15); color:#4a9eff; }
        .badge-merged   { background:rgba(130,80,255,.15); color:#c08fff; }
        .ci-ok          { color:#32d74b; }
        .ci-fail        { color:#ff453a; }
        .ci-pending     { color:#ff9f0a; }
        .prl-gh a       { color:var(--text-secondary,#888); text-decoration:none; font-size:14px; }
        .prl-gh a:hover { color:var(--accent,#4a9eff); }
        .prl-error      { color:#ff453a; padding:16px; }
        .prl-loading    { color:var(--text-secondary,#888); padding:16px; }
      </style>
      <div class="prl-shell">
        <div class="prl-header">
          <span class="prl-title">Pull Requests</span>
          <span class="prl-fetched">updated ${this.#esc(fetched)}</span>
        </div>
        ${stuckHtml}
        ${openHtml}
        ${mergedHtml}
      </div>
    `;

    // Wire row clicks → detail dispatch
    this.querySelectorAll('.prl-row[data-pr]').forEach((row) => {
      row.addEventListener('click', (e) => {
        // Don't intercept the GitHub link click
        if (e.target.closest('a')) return;
        const num = parseInt(row.dataset.pr, 10);
        document.dispatchEvent(new CustomEvent('chump:pr-detail', { detail: { number: num } }));
      });
    });
  }

  #section(label, rows, isOpen, lastShipAgoS) {
    if (!isOpen && rows.length === 0) {
      const empty = lastShipAgoS != null
        ? `No ships in the last 24 h. Last ship: ${this.#fmtAge(lastShipAgoS)} ago`
        : 'No PRs merged in the last 24 h.';
      return `
        <div class="prl-section">
          <div class="prl-section-hdr">${this.#esc(label)} <span class="prl-count">0</span></div>
          <div class="prl-empty">${this.#esc(empty)}</div>
        </div>`;
    }
    if (rows.length === 0) {
      return `
        <div class="prl-section">
          <div class="prl-section-hdr">${this.#esc(label)} <span class="prl-count">0</span></div>
          <div class="prl-empty">None.</div>
        </div>`;
    }

    const rowsHtml = rows.map((pr) => this.#prRow(pr)).join('');
    return `
      <div class="prl-section">
        <div class="prl-section-hdr">${this.#esc(label)} <span class="prl-count">${rows.length}</span></div>
        <table class="prl-table">
          <tbody>${rowsHtml}</tbody>
        </table>
      </div>`;
  }

  #prRow(pr) {
    const badge = this.#mergeBadge(pr.merge_state);
    const ci    = this.#ciBadge(pr);
    return `
      <tr class="prl-row" data-pr="${pr.number}">
        <td class="prl-num">#${pr.number}</td>
        <td class="prl-ttitle" title="${this.#esc(pr.title)}">${this.#esc(pr.title)}</td>
        <td class="prl-author">${this.#esc(pr.author || '—')}</td>
        <td class="prl-age">${this.#fmtAge(pr.age_s)}</td>
        <td class="prl-state"><span class="prl-badge ${badge.cls}">${badge.label}</span></td>
        <td class="prl-ci ${ci.cls}" title="${ci.title}">${ci.icon}</td>
        <td class="prl-gh"><a href="${this.#esc(pr.url || '#')}" target="_blank" rel="noopener" title="Open on GitHub" aria-label="PR #${pr.number} on GitHub">↗</a></td>
      </tr>`;
  }

  #mergeBadge(state) {
    switch ((state || '').toUpperCase()) {
      case 'CLEAN':    return { cls: 'badge-ok',      label: 'Clean' };
      case 'DIRTY':    return { cls: 'badge-warn',    label: 'Dirty' };
      case 'BLOCKED':  return { cls: 'badge-warn',    label: 'Blocked' };
      case 'BEHIND':   return { cls: 'badge-warn',    label: 'Behind' };
      case 'MERGED':   return { cls: 'badge-merged',  label: 'Merged' };
      case 'UNSTABLE': return { cls: 'badge-warn',    label: 'Unstable' };
      default:         return { cls: 'badge-pending', label: state || '?' };
    }
  }

  #ciBadge(pr) {
    if (pr.ci_fail > 0) return { cls: 'ci-fail',    icon: `✗${pr.ci_fail}`, title: `${pr.ci_fail} failing` };
    if (pr.ci_pass > 0) return { cls: 'ci-ok',      icon: `✓${pr.ci_pass}`, title: `${pr.ci_pass} passing` };
    return                      { cls: 'ci-pending', icon: '…',              title: 'No checks yet' };
  }

  #fmtAge(secs) {
    if (secs == null || secs < 0) return '—';
    const s = Number(secs);
    if (s < 60)  return `${s}s`;
    if (s < 3600) return `${Math.round(s / 60)}m`;
    if (s < 86400) return `${Math.round(s / 3600)}h`;
    return `${Math.round(s / 86400)}d`;
  }

  #esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }
}
customElements.define('chump-view-prs', ChumpViewPrs);
