// web/v2/inbox-notifications.js — PRODUCT-105
//
// In-app live signal layer for the operator inbox:
//   1. Unread badge on a nav anchor (#nav-inbox-link if present)
//   2. Toast notification when a new urgency=now message arrives
//
// Polls /api/inbox/<operator-id>/unread-count (INFRA-1298) every 15s.
// On new high-urgency arrival, shows a toast in the bottom-right.
//
// Opt-out: localStorage.setItem('CHUMP_NO_TOAST', '1').

const POLL_MS = 15_000;

function operatorId() {
  let id = localStorage.getItem('chump_operator_id');
  if (!id) {
    id = `operator-${Math.random().toString(16).slice(2, 10)}`;
    localStorage.setItem('chump_operator_id', id);
  }
  return id;
}

function escapeHtml(s) {
  return String(s || '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

// ── Toast helper ──────────────────────────────────────────────────────────
function ensureToastContainer() {
  let host = document.getElementById('chump-toast-host');
  if (host) return host;
  host = document.createElement('div');
  host.id = 'chump-toast-host';
  Object.assign(host.style, {
    position: 'fixed', right: '16px', bottom: '16px',
    display: 'flex', flexDirection: 'column', gap: '8px',
    zIndex: '99999', maxWidth: '380px', pointerEvents: 'none',
  });
  document.body.appendChild(host);
  return host;
}

function showToast({ title, body, urgency, onClick }) {
  if (localStorage.getItem('CHUMP_NO_TOAST') === '1') return;
  const host = ensureToastContainer();
  const card = document.createElement('div');
  const colorBg = urgency === 'now'
    ? 'rgba(204,51,68,0.95)'
    : (urgency === 'hours' ? 'rgba(204,136,0,0.95)' : 'rgba(60,80,120,0.95)');
  Object.assign(card.style, {
    background: colorBg, color: 'white', borderRadius: '8px',
    padding: '10px 14px', fontFamily: 'system-ui, sans-serif',
    fontSize: '13px', boxShadow: '0 4px 12px rgba(0,0,0,0.35)',
    pointerEvents: 'auto', cursor: 'pointer',
    transform: 'translateY(20px)', opacity: '0',
    transition: 'transform 200ms ease, opacity 200ms ease',
  });
  card.innerHTML = `
    <div style="font-weight:600;margin-bottom:2px;">${escapeHtml(title || 'Inbox')}</div>
    <div style="opacity:0.95;">${escapeHtml(body || '')}</div>
  `;
  card.addEventListener('click', () => {
    if (typeof onClick === 'function') onClick();
    dismiss();
  });
  host.appendChild(card);
  requestAnimationFrame(() => {
    card.style.transform = 'translateY(0)';
    card.style.opacity = '1';
  });
  function dismiss() {
    card.style.transform = 'translateY(20px)';
    card.style.opacity = '0';
    setTimeout(() => card.remove(), 250);
  }
  setTimeout(dismiss, 8000);
}

// ── Badge helper ──────────────────────────────────────────────────────────
function setBadge(count) {
  const link = document.getElementById('nav-inbox-link');
  if (!link) return;
  let badge = link.querySelector('.inbox-badge');
  if (count <= 0) {
    if (badge) badge.remove();
    return;
  }
  if (!badge) {
    badge = document.createElement('span');
    badge.className = 'inbox-badge';
    Object.assign(badge.style, {
      display: 'inline-block', marginLeft: '6px',
      minWidth: '18px', height: '18px',
      padding: '0 5px', borderRadius: '9px',
      background: '#d65468', color: 'white',
      fontSize: '11px', fontWeight: '600',
      textAlign: 'center', lineHeight: '18px',
      verticalAlign: 'middle',
    });
    link.appendChild(badge);
  }
  badge.textContent = count > 99 ? '99+' : String(count);
}

// ── Poll loop ────────────────────────────────────────────────────────────
class InboxNotifier {
  #lastSeenTs = '';
  #lastUnread = 0;

  start() {
    this.#tick();
    setInterval(() => this.#tick(), POLL_MS);
  }

  async #tick() {
    const opId = operatorId();
    try {
      const r = await fetch(`/api/inbox/${encodeURIComponent(opId)}/unread-count`);
      if (!r.ok) return;
      const d = await r.json();
      const unread = Number(d.unread || 0);
      setBadge(unread);

      // If unread count rose, fetch the latest messages and toast on
      // the freshest urgency=now entry the operator hasn't seen.
      if (unread > this.#lastUnread) {
        await this.#maybeToastNewest(opId);
      }
      this.#lastUnread = unread;
    } catch (_e) {
      // Silent on poll errors; will retry next tick.
    }
  }

  async #maybeToastNewest(opId) {
    try {
      const r = await fetch(`/api/inbox/${encodeURIComponent(opId)}?unread=1`);
      if (!r.ok) return;
      const d = await r.json();
      const msgs = d.messages || [];
      // Newest by ts last (chronological order); only toast urgency=now.
      for (let i = msgs.length - 1; i >= 0; i--) {
        const m = msgs[i];
        const ts = m.ts || '';
        if (ts && ts <= this.#lastSeenTs) continue;
        if (m.urgency !== 'now') continue;
        showToast({
          title: `${m.event}${m.kind ? ` · ${m.kind}` : ''}`,
          body: `${m.subject || ''}${m.rationale ? `\n${m.rationale.slice(0, 120)}` : ''}`,
          urgency: m.urgency,
          onClick: () => {
            // Scroll to inbox in the PWA if it's mounted; harmless if not.
            const inbox = document.querySelector('chump-inbox');
            if (inbox) inbox.scrollIntoView({ behavior: 'smooth' });
          },
        });
        this.#lastSeenTs = ts;
        break;
      }
    } catch (_e) {
      // ignore
    }
  }
}

const notifier = new InboxNotifier();
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => notifier.start());
} else {
  notifier.start();
}
