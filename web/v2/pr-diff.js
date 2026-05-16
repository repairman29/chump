// <chump-pr-diff pr-number="NNNN"> — PRODUCT-085 PR diff renderer + AC-fit panel.
//
// Fetches GET /api/pr/{N}/diff and GET /api/pr/{N}/ac-fit from the backend.
// Renders:
//   • Syntax-highlighted unified diff (light syntax via CSS classes, no CDN dep)
//   • AC-fit panel showing per-bullet check / unknown / cross verdict
//   • 3-mode toggle: Unified (default) | Split | AC-fit-only
//   • Per-file collapse/expand; pagination at LINES_PER_PAGE
//
// Vanilla Web Component, no build step required.
// Usage: <chump-pr-diff pr-number="2073"></chump-pr-diff>
//
// PRODUCT-085.

const LINES_PER_PAGE = 1000;

class ChumpPrDiff extends HTMLElement {
  static get observedAttributes() { return ['pr-number']; }
  #mode = 'unified'; // 'unified' | 'split' | 'ac-fit-only'
  #diffText = '';
  #acData = null;
  #diffPage = 0;
  #loading = false;

  connectedCallback() {
    this.#init();
  }

  attributeChangedCallback(name, _o, _n) {
    if (name === 'pr-number') this.#init();
  }

  #init() {
    const n = this.getAttribute('pr-number');
    if (!n) { this.#render(); return; }
    this.#loading = true;
    this.#render();
    Promise.all([
      fetch(`/api/pr/${encodeURIComponent(n)}/diff`).then(r => r.ok ? r.text() : Promise.reject(r.status)),
      fetch(`/api/pr/${encodeURIComponent(n)}/ac-fit`).then(r => r.ok ? r.json() : null).catch(() => null),
    ]).then(([diff, ac]) => {
      this.#diffText = diff || '';
      this.#acData = ac;
      this.#diffPage = 0;
      this.#loading = false;
      this.#render();
    }).catch(e => {
      this.#diffText = `Error loading diff: ${e}`;
      this.#loading = false;
      this.#render();
    });
  }

  #render() {
    const n = this.getAttribute('pr-number') || '?';
    this.innerHTML = `<style>${ChumpPrDiff.#css()}</style>${this.#html(n)}`;
    this.querySelector('.diff-mode-tabs')?.addEventListener('click', e => {
      const btn = e.target.closest('[data-mode]');
      if (btn) { this.#mode = btn.dataset.mode; this.#render(); }
    });
    this.querySelectorAll('.file-toggle').forEach(el =>
      el.addEventListener('click', () => {
        const body = el.closest('.file-block').querySelector('.file-body');
        body.hidden = !body.hidden;
        el.textContent = body.hidden ? '▶' : '▼';
      })
    );
    this.querySelector('.diff-prev')?.addEventListener('click', () => { this.#diffPage = Math.max(0, this.#diffPage - 1); this.#render(); });
    this.querySelector('.diff-next')?.addEventListener('click', () => { this.#diffPage++; this.#render(); });
  }

  #html(n) {
    if (this.#loading) return `<div class="diff-loading">Loading diff for PR #${n}…</div>`;
    if (!this.getAttribute('pr-number')) return `<div class="diff-empty">No PR number set.</div>`;

    const tabs = ['unified', 'split', 'ac-fit-only'].map(m =>
      `<button class="mode-btn${this.#mode === m ? ' active' : ''}" data-mode="${m}">${
        m === 'unified' ? 'Unified' : m === 'split' ? 'Split' : 'AC Fit'
      }</button>`
    ).join('');

    const header = `
      <div class="diff-header">
        <span class="diff-pr-label">PR #${n} diff</span>
        <div class="diff-mode-tabs">${tabs}</div>
      </div>`;

    if (this.#mode === 'ac-fit-only') return header + this.#acFitPanel();

    const diffHtml = this.#mode === 'split'
      ? this.#renderSplit()
      : this.#renderUnified();

    return header + diffHtml + (this.#mode !== 'ac-fit-only' ? this.#acFitPanel(true) : '');
  }

  // ── Unified diff renderer ───────────────────────────────────────────────

  #renderUnified() {
    if (!this.#diffText) return '<div class="diff-empty">No diff available.</div>';
    const files = this.#splitIntoFiles(this.#diffText);
    const allLines = this.#diffText.split('\n');
    const totalPages = Math.ceil(allLines.length / LINES_PER_PAGE);

    if (totalPages > 1) {
      // Pagination mode: show one page of raw diff lines, no file splitting
      const start = this.#diffPage * LINES_PER_PAGE;
      const pageLines = allLines.slice(start, start + LINES_PER_PAGE);
      const pager = `
        <div class="diff-pager">
          <button class="diff-prev"${this.#diffPage === 0 ? ' disabled' : ''}>◀ Prev</button>
          <span>Lines ${start + 1}–${Math.min(start + LINES_PER_PAGE, allLines.length)} of ${allLines.length}</span>
          <button class="diff-next"${this.#diffPage >= totalPages - 1 ? ' disabled' : ''}>Next ▶</button>
        </div>`;
      return `<div class="diff-unified">${this.#highlightLines(pageLines)}</div>${pager}`;
    }

    // No pagination — render per-file blocks with collapse/expand
    return files.map(f => this.#fileBlock(f)).join('');
  }

  #fileBlock({ header, lines }) {
    const filename = header.replace(/^diff --git a\// , '').split(' ')[0] || header;
    const body = `<div class="file-body"><pre class="diff-pre">${this.#highlightLines(lines)}</pre></div>`;
    return `
      <div class="file-block">
        <div class="file-header">
          <span class="file-toggle">▼</span>
          <span class="file-name">${this.#esc(filename)}</span>
        </div>
        ${body}
      </div>`;
  }

  // ── Split diff renderer ─────────────────────────────────────────────────

  #renderSplit() {
    if (!this.#diffText) return '<div class="diff-empty">No diff available.</div>';
    const files = this.#splitIntoFiles(this.#diffText);
    return files.map(f => this.#splitFileBlock(f)).join('');
  }

  #splitFileBlock({ header, lines }) {
    const filename = header.replace(/^diff --git a\//, '').split(' ')[0] || header;
    const pairs = this.#buildSplitPairs(lines);
    const rows = pairs.map(({ left, right }) => `
      <tr>
        <td class="split-cell ${left.kind}">${left.kind !== 'empty' ? `<pre>${this.#esc(left.text)}</pre>` : ''}</td>
        <td class="split-cell ${right.kind}">${right.kind !== 'empty' ? `<pre>${this.#esc(right.text)}</pre>` : ''}</td>
      </tr>`).join('');
    return `
      <div class="file-block">
        <div class="file-header"><span class="file-toggle">▼</span><span class="file-name">${this.#esc(filename)}</span></div>
        <div class="file-body">
          <table class="split-table"><tbody>${rows}</tbody></table>
        </div>
      </div>`;
  }

  #buildSplitPairs(lines) {
    const pairs = [];
    let i = 0;
    while (i < lines.length) {
      const l = lines[i];
      if (l.startsWith('-')) {
        // Collect a hunk of deletions + additions and pair them
        const dels = [];
        const adds = [];
        while (i < lines.length && lines[i].startsWith('-')) { dels.push(lines[i].slice(1)); i++; }
        while (i < lines.length && lines[i].startsWith('+')) { adds.push(lines[i].slice(1)); i++; }
        const max = Math.max(dels.length, adds.length);
        for (let j = 0; j < max; j++) {
          pairs.push({
            left:  j < dels.length ? { kind: 'del', text: dels[j] } : { kind: 'empty', text: '' },
            right: j < adds.length ? { kind: 'add', text: adds[j] } : { kind: 'empty', text: '' },
          });
        }
      } else if (l.startsWith('+')) {
        pairs.push({ left: { kind: 'empty', text: '' }, right: { kind: 'add', text: l.slice(1) } });
        i++;
      } else {
        const text = l.startsWith('\\') ? l : l.slice(1); // context line
        pairs.push({ left: { kind: 'ctx', text }, right: { kind: 'ctx', text } });
        i++;
      }
    }
    return pairs;
  }

  // ── AC-fit panel ────────────────────────────────────────────────────────

  #acFitPanel(inline = false) {
    const ac = this.#acData;
    if (!ac) return '';
    if (!ac.gap_id) return `<div class="ac-panel ac-panel-note">${this.#esc(ac.note || 'No gap ID in PR title.')}</div>`;

    const bullets = (ac.ac_bullets || []).map(b => {
      const icon = b.verdict === 'check' ? '✅' : b.verdict === 'cross' ? '❌' : '❓';
      const kws = b.matched_keywords.length
        ? `<span class="ac-kws">${b.matched_keywords.slice(0, 5).map(k => this.#esc(k)).join(', ')}</span>`
        : '';
      return `<li class="ac-bullet ac-${b.verdict}">${icon} <span class="ac-text">${this.#esc(b.text)}</span>${kws}</li>`;
    }).join('');

    return `
      <div class="ac-panel${inline ? ' ac-panel-inline' : ''}">
        <div class="ac-panel-title">AC fit — <a href="#" onclick="return false">${this.#esc(ac.gap_id)}</a>: ${this.#esc(ac.gap_title || '')}</div>
        <ul class="ac-list">${bullets || '<li class="ac-bullet ac-unknown">No AC bullets found.</li>'}</ul>
      </div>`;
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  #splitIntoFiles(text) {
    const files = [];
    let current = null;
    for (const line of text.split('\n')) {
      if (line.startsWith('diff --git ')) {
        if (current) files.push(current);
        current = { header: line, lines: [] };
      } else if (current) {
        current.lines.push(line);
      }
    }
    if (current) files.push(current);
    return files.length ? files : [{ header: 'diff', lines: text.split('\n') }];
  }

  #highlightLines(lines) {
    return lines.map(line => {
      if (line.startsWith('+++') || line.startsWith('---')) return `<span class="dh">${this.#esc(line)}</span>`;
      if (line.startsWith('@@')) return `<span class="dg">${this.#esc(line)}</span>`;
      if (line.startsWith('+')) return `<span class="da">${this.#esc(line)}</span>`;
      if (line.startsWith('-')) return `<span class="dd">${this.#esc(line)}</span>`;
      if (line.startsWith('diff ')) return `<span class="df">${this.#esc(line)}</span>`;
      return `<span class="dc">${this.#esc(line)}</span>`;
    }).join('\n');
  }

  #esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  static #css() {
    return `
      :host { display: block; font-family: var(--font-mono, monospace); font-size: 12px; }
      .diff-header { display: flex; align-items: center; justify-content: space-between; padding: 6px 8px; background: var(--surface2, #1e1e2e); border-radius: 6px 6px 0 0; }
      .diff-pr-label { font-size: 13px; font-weight: 600; color: var(--text1, #cdd6f4); }
      .diff-mode-tabs { display: flex; gap: 4px; }
      .mode-btn { padding: 3px 10px; border: 1px solid var(--overlay0, #6c7086); border-radius: 4px; background: transparent; color: var(--text2, #a6adc8); cursor: pointer; font-size: 11px; }
      .mode-btn.active { background: var(--blue, #89b4fa); color: var(--base, #1e1e2e); border-color: transparent; }
      .diff-loading, .diff-empty { padding: 16px; color: var(--subtext0, #a6adc8); }
      pre.diff-pre { margin: 0; padding: 8px; overflow-x: auto; background: var(--base, #1e1e2e); border-radius: 0 0 6px 6px; line-height: 1.5; }
      .file-block { border: 1px solid var(--overlay0, #6c7086); border-radius: 6px; margin-bottom: 8px; overflow: hidden; }
      .file-header { display: flex; align-items: center; gap: 8px; padding: 4px 8px; background: var(--surface1, #181825); cursor: pointer; }
      .file-toggle { font-size: 10px; user-select: none; color: var(--subtext0, #a6adc8); }
      .file-name { font-size: 12px; color: var(--blue, #89b4fa); }
      .dh { color: var(--subtext1, #bac2de); }
      .dg { color: var(--teal, #94e2d5); }
      .da { color: var(--green, #a6e3a1); background: rgba(166,227,161,.08); }
      .dd { color: var(--red, #f38ba8); background: rgba(243,139,168,.08); }
      .df { color: var(--mauve, #cba6f7); font-weight: bold; }
      .dc { color: var(--text2, #a6adc8); }
      .split-table { width: 100%; border-collapse: collapse; }
      .split-cell { width: 50%; vertical-align: top; padding: 0; border-right: 1px solid var(--overlay0, #6c7086); }
      .split-cell pre { margin: 0; padding: 2px 4px; white-space: pre-wrap; }
      .split-cell.add { background: rgba(166,227,161,.08); }
      .split-cell.del { background: rgba(243,139,168,.08); }
      .split-cell.ctx { background: transparent; }
      .split-cell.empty { background: var(--surface0, #313244); }
      .diff-pager { display: flex; gap: 8px; align-items: center; padding: 6px 8px; background: var(--surface1, #181825); }
      .diff-pager button { padding: 3px 10px; border-radius: 4px; border: 1px solid var(--overlay0, #6c7086); background: transparent; color: var(--text2, #a6adc8); cursor: pointer; }
      .diff-pager button:disabled { opacity: 0.4; cursor: default; }
      .ac-panel { border: 1px solid var(--overlay0, #6c7086); border-radius: 6px; margin-top: 8px; overflow: hidden; }
      .ac-panel-inline { margin-top: 12px; }
      .ac-panel-title { padding: 6px 10px; background: var(--surface1, #181825); font-size: 12px; font-weight: 600; color: var(--text1, #cdd6f4); }
      .ac-list { list-style: none; margin: 0; padding: 8px 10px; display: flex; flex-direction: column; gap: 4px; }
      .ac-bullet { font-size: 12px; line-height: 1.4; }
      .ac-bullet.ac-check .ac-text { color: var(--green, #a6e3a1); }
      .ac-bullet.ac-unknown .ac-text { color: var(--subtext0, #a6adc8); }
      .ac-bullet.ac-cross .ac-text { color: var(--red, #f38ba8); }
      .ac-kws { margin-left: 6px; font-size: 10px; color: var(--subtext1, #bac2de); background: var(--surface0, #313244); padding: 1px 4px; border-radius: 3px; }
      .ac-panel-note { padding: 8px 10px; color: var(--subtext0, #a6adc8); font-size: 12px; }
    `;
  }
}

customElements.define('chump-pr-diff', ChumpPrDiff);
