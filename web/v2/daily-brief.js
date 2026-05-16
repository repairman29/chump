// daily-brief.js — PRODUCT-078
// PWA Daily Brief: "while you were away" surface.
// Web component <chump-view-brief> — Shadow DOM, no framework.

const LAST_VISIT_KEY = 'chump:last-pwa-visit';
const DISMISS_KEY    = 'chump:brief-dismissed';   // JSON: { "<kind>:<ts>": true }
const DISMISS_RESET_HOUR = 0;                       // midnight local

function getDismissed() {
  try { return JSON.parse(localStorage.getItem(DISMISS_KEY) || '{}'); } catch { return {}; }
}
function setDismissed(map) {
  localStorage.setItem(DISMISS_KEY, JSON.stringify(map));
}
function maybeResetDismissals() {
  const d = new Date();
  if (d.getHours() === DISMISS_RESET_HOUR && d.getMinutes() < 5) {
    localStorage.removeItem(DISMISS_KEY);
  }
}
function itemKey(item) { return `${item.kind}:${item.ts}`; }

function sinceLabel(sinceAgoSecs) {
  if (sinceAgoSecs < 120) return 'just now';
  if (sinceAgoSecs < 3600) return `${Math.round(sinceAgoSecs / 60)}m ago`;
  if (sinceAgoSecs < 86400) return `${Math.round(sinceAgoSecs / 3600)}h ago`;
  return `${Math.round(sinceAgoSecs / 86400)}d ago`;
}

const BUCKET_META = {
  done:            { label: '✅ Done while you were away', cls: 'done',       emptyText: 'Nothing shipped yet.' },
  needs_judgment:  { label: '⚠️ Needs your judgment',     cls: 'needs',      emptyText: 'No action needed.' },
  alerts:          { label: '🚨 Fleet alerts',             cls: 'alerts',     emptyText: 'All clear.' },
};

class ChumpViewBrief extends HTMLElement {
  constructor() {
    super();
    this._shadow = this.attachShadow({ mode: 'open' });
    this._data   = null;
    this._loading = false;
    this._visListener = null;
  }

  connectedCallback() {
    this._render('<p class="loading">Loading daily brief…</p>');
    this._load();
    // Refresh the brief whenever the tab regains focus.
    this._visListener = () => {
      if (!document.hidden) this._load();
    };
    document.addEventListener('visibilitychange', this._visListener);
  }

  disconnectedCallback() {
    if (this._visListener) {
      document.removeEventListener('visibilitychange', this._visListener);
    }
  }

  async _load() {
    if (this._loading) return;
    this._loading = true;
    maybeResetDismissals();

    // Persist current visit time BEFORE fetching (next load uses this as `since`).
    const nowTs  = Math.floor(Date.now() / 1000);
    const lastTs = parseInt(localStorage.getItem(LAST_VISIT_KEY) || '0', 10);
    localStorage.setItem(LAST_VISIT_KEY, String(nowTs));

    const since = lastTs > 0 ? lastTs : nowTs - 8 * 3600;
    try {
      const res = await fetch(`/api/brief?since=${since}`, {
        headers: { Authorization: `Bearer ${window.CHUMP_TOKEN || ''}` },
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      this._data = await res.json();
      this._renderData();
    } catch (e) {
      this._render(`<p class="error">Failed to load brief: ${e.message}</p>`);
    } finally {
      this._loading = false;
    }
  }

  _renderData() {
    const d = this._data;
    if (!d) return;
    const dismissed = getDismissed();
    const since = sinceLabel(d.since_ago_secs || 0);
    const total  = (d.counts?.done || 0) + (d.counts?.needs_judgment || 0) + (d.counts?.alerts || 0);

    let html = `
      <style>
        :host { display: block; font-family: system-ui, sans-serif; }
        h2 { font-size: 1.1rem; margin: 0 0 .5rem; color: #334; }
        .tagline { font-size: .85rem; color: #667; margin-bottom: 1rem; }
        .bucket { margin-bottom: 1.25rem; }
        .bucket h3 { font-size: .95rem; margin: 0 0 .4rem; }
        .bucket.done h3  { color: #276; }
        .bucket.needs h3 { color: #740; }
        .bucket.alerts h3 { color: #800; }
        .item { display: flex; align-items: baseline; gap: .5rem; padding: .3rem 0;
                border-bottom: 1px solid #eee; font-size: .875rem; }
        .item:last-child { border-bottom: none; }
        .item .ts { color: #999; font-size: .75rem; flex-shrink: 0; }
        .item .summary { flex: 1; }
        .item a { color: #357; text-decoration: none; }
        .item a:hover { text-decoration: underline; }
        .dismiss-btn { background: none; border: none; cursor: pointer; color: #aaa;
                       font-size: .75rem; padding: 0 .25rem; }
        .dismiss-btn:hover { color: #600; }
        .empty { color: #aaa; font-size: .85rem; font-style: italic; padding: .25rem 0; }
        .loading { color: #888; }
        .error { color: #c00; }
        .refresh-btn { margin-top: .75rem; font-size: .8rem; padding: .25rem .6rem;
                       border: 1px solid #bbb; border-radius: 4px; cursor: pointer;
                       background: #f5f5f5; }
      </style>
      <h2>📋 Daily Brief</h2>
      <p class="tagline">Since you last looked (${since}): ${total} item${total === 1 ? '' : 's'}</p>
    `;

    for (const [key, meta] of Object.entries(BUCKET_META)) {
      const items = (d.buckets?.[key] || []).filter(i => !dismissed[itemKey(i)]);
      html += `<div class="bucket ${meta.cls}"><h3>${meta.label}</h3>`;
      if (items.length === 0) {
        html += `<div class="empty">${meta.emptyText}</div>`;
      } else {
        for (const item of items) {
          const tsLabel = item.ts ? new Date(item.ts).toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'}) : '';
          const ikey    = itemKey(item).replace(/"/g, '&quot;');
          const summaryHtml = item.url
            ? `<a href="${item.url}" target="_blank" rel="noopener">${this._esc(item.summary)}</a>`
            : this._esc(item.summary);
          html += `
            <div class="item" data-key="${ikey}">
              <span class="ts">${tsLabel}</span>
              <span class="summary">${summaryHtml}</span>
              <button class="dismiss-btn" data-dismiss="${ikey}" title="Dismiss">✕</button>
            </div>`;
        }
      }
      html += `</div>`;
    }

    html += `<button class="refresh-btn" id="brief-refresh">↺ Refresh</button>`;
    this._render(html);

    // Wire dismiss buttons.
    this._shadow.querySelectorAll('.dismiss-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const key = btn.dataset.dismiss;
        const d2  = getDismissed();
        d2[key] = true;
        setDismissed(d2);
        btn.closest('.item')?.remove();
      });
    });

    this._shadow.getElementById('brief-refresh')?.addEventListener('click', () => {
      this._loading = false;
      this._load();
    });
  }

  _render(innerHtml) {
    this._shadow.innerHTML = innerHtml;
  }

  _esc(str) {
    return String(str || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
}

customElements.define('chump-view-brief', ChumpViewBrief);
