// PRODUCT-094 — PWA in-app notification center
//
// Watches the ambient SSE stream for actionable fleet events and surfaces
// them as an in-app notification feed with badge, panel, dismiss, and
// localStorage persistence.
//
// Components exported:
//   <chump-notification-center>  — invisible singleton; manages SSE + storage
//   <chump-view-notifications>   — the notification panel rendered in main content
//
// Global singleton: window.chumpNotifStore
//
// Event dispatched on document whenever unread count or notification list changes:
//   CustomEvent('chump:notif-updated', { detail: { unread: N, notifications: [...] } })

// ── Constants ────────────────────────────────────────────────────────────────

const NOTIF_KINDS = {
  fleet_wedge:    { color: 'red',    label: 'Fleet Wedge',    urgency: 3 },
  pr_stuck:       { color: 'yellow', label: 'PR Stuck',       urgency: 2 },
  needs_judgment: { color: 'orange', label: 'Needs Judgment', urgency: 2 },
  gap_shipped:    { color: 'green',  label: 'Gap Shipped',    urgency: 1 },
};

const STORAGE_KEY  = 'chump-notifications-v1';
const MAX_STORED   = 50;   // keep last 50
const SSE_RETRY_MS = 4000;

// ── ChumpNotifStore (singleton) ───────────────────────────────────────────────

class ChumpNotifStore extends EventTarget {
  #sse = null;
  #notifications = [];   // newest-first, max MAX_STORED
  #unread = 0;
  #retryTimer = null;

  constructor() {
    super();
    this.#load();
  }

  get notifications() { return this.#notifications; }
  get unread()        { return this.#unread; }

  // ── SSE connection ───────────────────────────────────────────────────────

  connect() {
    if (this.#sse) return;
    this.#open();
  }

  #open() {
    try {
      this.#sse = new EventSource('/api/ambient/stream');
    } catch {
      this.#scheduleRetry();
      return;
    }

    this.#sse.addEventListener('ambient', (e) => {
      try {
        const ev = JSON.parse(e.data);
        if (NOTIF_KINDS[ev.kind]) this.#ingest(ev);
      } catch {}
    });

    this.#sse.onerror = () => {
      if (this.#sse) { try { this.#sse.close(); } catch {} this.#sse = null; }
      this.#scheduleRetry();
    };
  }

  #scheduleRetry() {
    if (this.#retryTimer) return;
    this.#retryTimer = setTimeout(() => {
      this.#retryTimer = null;
      this.#open();
    }, SSE_RETRY_MS);
  }

  // ── Ingestion ─────────────────────────────────────────────────────────────

  #ingest(ev) {
    const meta   = NOTIF_KINDS[ev.kind];
    const gapId  = ev.gap_id || ev.gap || null;
    const note   = ev.note || ev.msg || ev.detail || '';
    const ts     = ev.ts || new Date().toISOString();
    const id     = `${ts}-${ev.kind}-${Math.random().toString(36).slice(2, 7)}`;

    // Deduplicate: skip if same kind+gap_id within 60 s.
    const cutoff = Date.now() - 60_000;
    const dup = this.#notifications.find((n) =>
      n.kind === ev.kind &&
      n.gapId === gapId &&
      new Date(n.ts).getTime() > cutoff
    );
    if (dup) return;

    const notif = {
      id,
      kind:   ev.kind,
      color:  meta.color,
      label:  meta.label,
      gapId,
      note,
      ts,
      read:   false,
    };

    this.#notifications.unshift(notif);
    if (this.#notifications.length > MAX_STORED) {
      this.#notifications = this.#notifications.slice(0, MAX_STORED);
    }

    this.#unread = this.#notifications.filter((n) => !n.read).length;
    this.#save();
    this.#dispatch();
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  markRead(id) {
    const n = this.#notifications.find((n) => n.id === id);
    if (n && !n.read) {
      n.read = true;
      this.#unread = Math.max(0, this.#unread - 1);
      this.#save();
      this.#dispatch();
    }
  }

  dismiss(id) {
    const before = this.#notifications.length;
    this.#notifications = this.#notifications.filter((n) => n.id !== id);
    if (this.#notifications.length !== before) {
      this.#unread = this.#notifications.filter((n) => !n.read).length;
      this.#save();
      this.#dispatch();
    }
  }

  markAllRead() {
    this.#notifications.forEach((n) => { n.read = true; });
    this.#unread = 0;
    this.#save();
    this.#dispatch();
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  #load() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw);
        this.#notifications = Array.isArray(parsed) ? parsed.slice(0, MAX_STORED) : [];
      }
    } catch {}
    this.#unread = this.#notifications.filter((n) => !n.read).length;
  }

  #save() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(this.#notifications));
    } catch {}
  }

  // ── Internal dispatch ─────────────────────────────────────────────────────

  #dispatch() {
    const detail = { unread: this.#unread, notifications: this.#notifications };
    document.dispatchEvent(new CustomEvent('chump:notif-updated', { detail }));
  }
}

// Expose singleton.
window.chumpNotifStore = window.chumpNotifStore || new ChumpNotifStore();

// ── <chump-notification-center> — invisible mount point ───────────────────────
// Starts the SSE connection and updates the nav badge.

class ChumpNotificationCenter extends HTMLElement {
  #unsub = null;

  connectedCallback() {
    this.style.display = 'none';
    window.chumpNotifStore.connect();
    this.#unsub = (e) => this.#onUpdate(e.detail);
    document.addEventListener('chump:notif-updated', this.#unsub);
    // Sync badge now (in case notifications loaded from storage).
    this.#syncBadge(window.chumpNotifStore.unread);
  }

  disconnectedCallback() {
    if (this.#unsub) document.removeEventListener('chump:notif-updated', this.#unsub);
  }

  #onUpdate({ unread }) {
    this.#syncBadge(unread);
  }

  #syncBadge(count) {
    const badge = document.getElementById('notif-nav-badge');
    if (!badge) return;
    badge.textContent = count > 99 ? '99+' : String(count);
    badge.hidden = count === 0;
    // Update aria-label on the nav button.
    const btn = document.querySelector('[data-view="notifications"]');
    if (btn) {
      btn.setAttribute('aria-label', count > 0 ? `Notifications — ${count} unread` : 'Notifications');
    }
  }
}

customElements.define('chump-notification-center', ChumpNotificationCenter);

// ── <chump-view-notifications> — main content panel ───────────────────────────

class ChumpViewNotifications extends HTMLElement {
  #unsub = null;

  connectedCallback() {
    this.#render();
    this.#unsub = (e) => this.#refresh(e.detail.notifications);
    document.addEventListener('chump:notif-updated', this.#unsub);
    // Mark all as read on open.
    window.chumpNotifStore.markAllRead();
  }

  disconnectedCallback() {
    if (this.#unsub) document.removeEventListener('chump:notif-updated', this.#unsub);
  }

  #render() {
    this.innerHTML = `
      <style>
        .nc-wrap { max-width: 760px; margin: 0 auto; padding: 20px 16px; font-family: system-ui, sans-serif; }
        .nc-header { display: flex; align-items: center; gap: 12px; margin-bottom: 20px; }
        .nc-title  { font-size: 18px; font-weight: 600; color: var(--text, #e0e0e0); flex: 1; }
        .nc-mark-all {
          font-size: 12px; padding: 4px 10px; border-radius: 6px; cursor: pointer;
          border: 1px solid #555; background: #2a2a2a; color: #aaa;
        }
        .nc-mark-all:hover { background: #3a3a3a; color: #e0e0e0; }
        .nc-empty { color: #666; font-size: 14px; padding: 40px 0; text-align: center; }
        .nc-list  { display: flex; flex-direction: column; gap: 8px; }

        .nc-item {
          display: flex; gap: 12px; align-items: flex-start; padding: 12px;
          border-radius: 8px; background: #1e1e1e; border: 1px solid #2a2a2a;
          transition: background 0.15s;
        }
        .nc-item.unread { border-color: #3a3a3a; background: #222; }
        .nc-item:hover  { background: #252525; }

        .nc-dot {
          width: 8px; height: 8px; border-radius: 50%; margin-top: 5px; flex-shrink: 0;
        }
        .nc-dot.red    { background: #ff6b6b; box-shadow: 0 0 6px rgba(255,107,107,0.5); }
        .nc-dot.yellow { background: #ffd93d; }
        .nc-dot.orange { background: #ff9f0a; }
        .nc-dot.green  { background: #6bcb77; }
        .nc-dot.grey   { background: #555; }

        .nc-body  { flex: 1; min-width: 0; }
        .nc-kind  { font-size: 11px; font-weight: 600; text-transform: uppercase;
                    letter-spacing: 0.5px; margin-bottom: 2px; }
        .nc-kind.red    { color: #ff6b6b; }
        .nc-kind.yellow { color: #ffd93d; }
        .nc-kind.orange { color: #ff9f0a; }
        .nc-kind.green  { color: #6bcb77; }
        .nc-kind.grey   { color: #999; }

        .nc-note  { font-size: 13px; color: #d0d0d0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .nc-meta  { font-size: 11px; color: #666; margin-top: 3px; }
        .nc-gap-link { color: #4a9eff; text-decoration: none; }
        .nc-gap-link:hover { text-decoration: underline; }

        .nc-dismiss {
          background: none; border: none; cursor: pointer; color: #555;
          font-size: 16px; padding: 0 4px; line-height: 1; flex-shrink: 0;
        }
        .nc-dismiss:hover { color: #aaa; }
      </style>
      <div class="nc-wrap">
        <div class="nc-header">
          <span class="nc-title">🔔 Notifications</span>
          <button class="nc-mark-all" id="nc-mark-all">Mark all read</button>
        </div>
        <div class="nc-list" id="nc-list"></div>
      </div>`;

    this.querySelector('#nc-mark-all').addEventListener('click', () => {
      window.chumpNotifStore.markAllRead();
    });

    this.#refresh(window.chumpNotifStore.notifications);
  }

  #refresh(notifications) {
    const list = this.querySelector('#nc-list');
    if (!list) return;

    if (!notifications.length) {
      list.innerHTML = '<div class="nc-empty">No notifications yet. Fleet events (fleet_wedge, pr_stuck, gap_shipped, needs_judgment) will appear here.</div>';
      return;
    }

    list.innerHTML = '';
    notifications.forEach((n) => {
      const tsLabel  = this.#formatTs(n.ts);
      const note     = n.note ? this.#esc(n.note) : '';
      const gapLink  = n.gapId
        ? `<a class="nc-gap-link" href="#" data-gap="${this.#esc(n.gapId)}">${this.#esc(n.gapId)}</a>`
        : '';
      const meta     = [gapLink, tsLabel].filter(Boolean).join(' · ');

      const row = document.createElement('div');
      row.className = `nc-item${n.read ? '' : ' unread'}`;
      row.dataset.id = n.id;
      row.innerHTML = `
        <span class="nc-dot ${n.color || 'grey'}"></span>
        <div class="nc-body">
          <div class="nc-kind ${n.color || 'grey'}">${this.#esc(n.label || n.kind)}</div>
          ${note ? `<div class="nc-note" title="${this.#esc(n.note)}">${note}</div>` : ''}
          <div class="nc-meta">${meta}</div>
        </div>
        <button class="nc-dismiss" title="Dismiss" data-dismiss="${this.#esc(n.id)}" aria-label="Dismiss">×</button>`;

      // Gap link → navigate to gap queue view.
      row.querySelector('.nc-gap-link')?.addEventListener('click', (e) => {
        e.preventDefault();
        document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'agent' }));
      });

      // Dismiss.
      row.querySelector('.nc-dismiss').addEventListener('click', () => {
        window.chumpNotifStore.dismiss(n.id);
      });

      list.appendChild(row);
    });
  }

  #formatTs(iso) {
    try {
      const d  = new Date(iso);
      const now = new Date();
      const diffMs = now - d;
      if (diffMs < 60_000)  return 'just now';
      if (diffMs < 3600_000) return `${Math.floor(diffMs / 60_000)}m ago`;
      if (diffMs < 86400_000) return `${Math.floor(diffMs / 3600_000)}h ago`;
      return d.toLocaleDateString();
    } catch { return ''; }
  }

  #esc(s) {
    return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
}

customElements.define('chump-view-notifications', ChumpViewNotifications);
