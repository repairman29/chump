// autopilot-toggle.js — PRODUCT-115
//
// Persistent on/off switch for the fleet's autopilot loop. Renders in the
// app header. Polls /api/autopilot/status on mount + every 10s; PUT
// /api/autopilot/start or /stop on click. Color-coded:
//   green = running
//   gray  = stopped
//   amber = starting / transitioning
//   red   = error (desired_enabled but not running)
//
// Endpoints exist server-side (src/web_server.rs handle_autopilot_{status,
// start,stop}); this component is pure UI wiring.

class ChumpAutopilotToggle extends HTMLElement {
  constructor() {
    super();
    this._state = null;
    this._pending = false;
    this._pollTimer = null;
    this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.render();
    this.refresh();
    // Poll every 10s; cheap REST call.
    this._pollTimer = setInterval(() => this.refresh(), 10_000);
  }

  disconnectedCallback() {
    if (this._pollTimer) clearInterval(this._pollTimer);
  }

  async refresh() {
    try {
      const r = await fetch('/api/autopilot/status', {
        headers: this._authHeaders(),
        credentials: 'same-origin',
      });
      if (!r.ok) {
        // Auth failure or server down — show error state without exploding.
        this._state = { actual_state: 'error', desired_enabled: false };
      } else {
        this._state = await r.json();
      }
    } catch (_e) {
      this._state = { actual_state: 'error', desired_enabled: false };
    }
    this.render();
  }

  async toggle() {
    if (this._pending) return;
    if (!this._state) return;
    const turningOn = !this._isEnabled();
    const path = turningOn ? '/api/autopilot/start' : '/api/autopilot/stop';

    this._pending = true;
    this._optimisticState = turningOn ? 'starting' : 'stopping';
    this.render();

    try {
      const r = await fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...this._authHeaders() },
        credentials: 'same-origin',
      });
      const body = await r.json().catch(() => ({}));
      if (r.ok && body.ok !== false) {
        // Emit pwa_pref_changed-style audit via best-effort beacon
        this._emitAmbient('autopilot_toggled', { from: this._state.actual_state, to: turningOn ? 'running' : 'stopped' });
        // Use the returned state immediately so the UI feels responsive.
        if (body.state) this._state = body.state;
      } else {
        this._toastError(body.error || `HTTP ${r.status}`);
      }
    } catch (e) {
      this._toastError(e.message || 'network error');
    } finally {
      this._pending = false;
      this._optimisticState = null;
      // Re-poll to sync with reality (handles transitions like starting → running)
      this.refresh();
    }
  }

  _isEnabled() {
    if (!this._state) return false;
    return this._state.desired_enabled === true;
  }

  _authHeaders() {
    // INFRA-1014: CHUMP_WEB_TOKEN, if set, must be sent. Read from
    // sessionStorage where chumpPrefs.setToken stashes it.
    try {
      const t = window.chumpPrefs && window.chumpPrefs.get
        ? window.chumpPrefs.get('webToken')
        : null;
      if (t) return { 'X-Chump-Auth': t };
    } catch (_e) {}
    return {};
  }

  _toastError(msg) {
    // Best-effort: dispatch a custom event that the notification-center
    // component listens for. Falls through silently if it's not mounted.
    this.dispatchEvent(new CustomEvent('chump-toast', {
      bubbles: true,
      composed: true,
      detail: { kind: 'error', message: `Autopilot: ${msg}` },
    }));
  }

  _emitAmbient(kind, fields) {
    // PWA-side ambient emit (cheap fetch; fail silent).
    try {
      const ts = new Date().toISOString();
      const body = JSON.stringify({ kind, source: 'pwa-autopilot-toggle', ...fields });
      fetch('/api/ambient/emit', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...this._authHeaders() },
        body,
        credentials: 'same-origin',
        keepalive: true,
      }).catch(() => {});
    } catch (_e) {}
  }

  render() {
    const s = this._optimisticState
      ? this._optimisticState
      : (this._state ? this._state.actual_state : 'loading');
    const enabled = this._optimisticState
      ? (this._optimisticState === 'starting')
      : this._isEnabled();
    const labelByState = {
      running: 'ON',
      stopped: 'OFF',
      starting: '→ ON',
      stopping: '→ OFF',
      error: '⚠ ERR',
      loading: '…',
    };
    const label = labelByState[s] || s;
    const colorByState = {
      running:  '#30d158', // green (var --success)
      stopped:  '#6c6c70', // gray
      starting: '#ff9f0a', // amber (var --warn)
      stopping: '#ff9f0a',
      error:    '#ff453a', // red (var --error)
      loading:  '#6c6c70',
    };
    const color = colorByState[s] || '#6c6c70';
    const title = `Autopilot ${label}. ${
      s === 'running' ? 'Fleet is claiming + shipping. Click to pause.' :
      s === 'stopped' ? 'Fleet is idle. Click to start.' :
      s === 'error'   ? (this._state && this._state.last_error) || 'Autopilot in error state. Click to retry.' :
                        'Transitioning...'
    }`;

    this.shadowRoot.innerHTML = `
      <style>
        :host {
          display: inline-flex;
          align-items: center;
          margin-left: 12px;
          font: 12px -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        }
        button {
          display: inline-flex;
          align-items: center;
          gap: 6px;
          padding: 4px 10px;
          border: 1px solid ${color};
          background: ${color}22;
          color: ${color};
          border-radius: 6px;
          cursor: pointer;
          font-weight: 600;
          letter-spacing: 0.3px;
          font-size: 11px;
          line-height: 1;
          transition: background 0.15s ease, opacity 0.15s ease;
        }
        button:hover:not([disabled]) { background: ${color}44; }
        button[disabled] { opacity: 0.6; cursor: progress; }
        .dot {
          width: 8px; height: 8px; border-radius: 50%; background: ${color};
          box-shadow: 0 0 6px ${color};
          ${enabled ? 'animation: pulse 2s ease-in-out infinite;' : ''}
        }
        @keyframes pulse {
          0%, 100% { opacity: 1; }
          50%      { opacity: 0.4; }
        }
        .label { white-space: nowrap; }
        .ap { font-size: 9px; opacity: 0.7; }
      </style>
      <button
        id="toggle"
        ${this._pending ? 'disabled' : ''}
        title="${title.replace(/"/g, '&quot;')}"
        aria-pressed="${enabled}"
        aria-label="Autopilot ${label}"
      >
        <span class="dot"></span>
        <span class="label"><span class="ap">AUTOPILOT</span> ${label}</span>
      </button>
    `;
    const btn = this.shadowRoot.getElementById('toggle');
    if (btn) btn.addEventListener('click', () => this.toggle());
  }
}

customElements.define('chump-autopilot-toggle', ChumpAutopilotToggle);
