// <chump-ambient-viewer> — PRODUCT-091: real-time ambient.jsonl event tail.
//
// SSE-backed ambient event viewer with kind filter chips, color-coded severity,
// auto-scroll pause/resume, and a seeded initial batch of recent events.
//
// Usage: <chump-ambient-viewer></chump-ambient-viewer>
//
// Vanilla Web Component, no build, no CDN.

const SEVERITY = {
  fleet_wedge:    'red',
  silent_agent:   'red',
  pr_stuck:       'yellow',
  bot_merge_failure: 'yellow',
  scratch_commit_blocked: 'yellow',
  fleet_auth_fallback: 'yellow',
  gap_shipped:    'green',
  ship_complete:  'green',
  gap_check_false_positive: 'blue',
};

const FILTER_KINDS = [
  'fleet_wedge', 'silent_agent', 'pr_stuck', 'bot_merge_failure',
  'gap_shipped', 'gap_check_false_positive', 'lease_acquired', 'lease_released',
];

class ChumpAmbientViewer extends HTMLElement {
  #sse = null;
  #autoScroll = true;
  #activeKind = null;

  connectedCallback() {
    this.#render();
    this.#connect();
  }

  disconnectedCallback() {
    if (this.#sse) this.#sse.close();
  }

  #render() {
    this.innerHTML = `
      <style>
        .av-wrap { font-family: monospace; font-size: 13px; }
        .av-chips { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 8px; }
        .av-chip { padding: 2px 8px; border-radius: 12px; border: 1px solid #555;
                   cursor: pointer; background: #2a2a2a; color: #ccc; }
        .av-chip.active { background: #4a9eff; color: #000; border-color: #4a9eff; }
        .av-list { height: 300px; overflow-y: auto; border: 1px solid #333;
                   background: #1a1a1a; padding: 4px; }
        .av-row { padding: 2px 4px; border-bottom: 1px solid #222; display: flex; gap: 8px; }
        .av-ts { color: #666; min-width: 90px; flex-shrink: 0; }
        .av-kind { min-width: 160px; flex-shrink: 0; }
        .av-kind.red    { color: #ff6b6b; }
        .av-kind.yellow { color: #ffd93d; }
        .av-kind.green  { color: #6bcb77; }
        .av-kind.blue   { color: #4a9eff; }
        .av-detail { color: #aaa; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .av-paused { font-size: 11px; color: #888; padding: 2px 6px;
                     background: #333; border-radius: 4px; display: none; }
        .av-paused.show { display: inline; }
      </style>
      <div class="av-wrap">
        <div class="av-chips">
          <span class="av-chip active" data-kind="">All</span>
          ${FILTER_KINDS.map(k => `<span class="av-chip" data-kind="${k}">${k}</span>`).join('')}
          <span class="av-paused" id="av-pause-badge">⏸ paused</span>
        </div>
        <div class="av-list" id="av-list"></div>
      </div>`;

    const list = this.querySelector('#av-list');

    list.addEventListener('scroll', () => {
      const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 20;
      this.#autoScroll = atBottom;
      this.querySelector('#av-pause-badge').classList.toggle('show', !atBottom);
    });

    this.querySelectorAll('.av-chip').forEach(chip => {
      chip.addEventListener('click', () => {
        this.querySelectorAll('.av-chip').forEach(c => c.classList.remove('active'));
        chip.classList.add('active');
        const kind = chip.dataset.kind || null;
        if (kind !== this.#activeKind) {
          this.#activeKind = kind;
          list.innerHTML = '';
          if (this.#sse) this.#sse.close();
          this.#connect();
        }
      });
    });
  }

  #connect() {
    const url = this.#activeKind
      ? `/api/ambient/stream?kind=${encodeURIComponent(this.#activeKind)}`
      : '/api/ambient/stream';
    const sse = new EventSource(url);
    this.#sse = sse;

    sse.addEventListener('ambient', (e) => {
      try {
        const ev = JSON.parse(e.data);
        this.#appendRow(ev);
      } catch (_) {}
    });

    sse.onerror = () => {
      setTimeout(() => {
        if (this.isConnected) this.#connect();
      }, 3000);
    };
  }

  #appendRow(ev) {
    const list = this.querySelector('#av-list');
    if (!list) return;

    const kind = ev.kind || ev.event || '?';
    const ts = (ev.ts || '').slice(11, 19); // HH:MM:SS
    const gap = ev.gap_id || ev.gap || '';
    const note = ev.note || ev.detail || ev.msg || '';
    const severity = SEVERITY[kind] || '';

    const detail = [gap, note].filter(Boolean).join(' — ');

    const row = document.createElement('div');
    row.className = 'av-row';
    row.innerHTML = `
      <span class="av-ts">${ts}</span>
      <span class="av-kind ${severity}">${kind}</span>
      <span class="av-detail" title="${detail.replace(/"/g, '&quot;')}">${detail}</span>`;

    list.appendChild(row);

    if (this.#autoScroll) {
      list.scrollTop = list.scrollHeight;
    }

    // Cap to last 500 rows to avoid memory growth.
    while (list.children.length > 500) {
      list.removeChild(list.firstChild);
    }
  }
}

customElements.define('chump-ambient-viewer', ChumpAmbientViewer);
