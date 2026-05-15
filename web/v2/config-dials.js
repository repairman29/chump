// config-dials.js — PRODUCT-118
//
// Live operator dials for fleet control: throttle, work-backend, fleet size,
// auth mode, model. Reads + writes /api/settings (existing INFRA-988 backend
// path, this PR extends the whitelist with CHUMP_GH_MAX_CALLS_PER_MIN +
// CHUMP_WORK_BACKEND so they're tunable from the PWA).
//
// Per dial:
//   - current value + source badge (env / config / default)
//   - edit-in-place input
//   - Apply button → POST /api/settings/{key}; status toast on success/error
//
// Hosted in the CONFIG cadence (PRODUCT-106 four-cadence shell).

const DIALS = [
  {
    key: 'CHUMP_GH_MAX_CALLS_PER_MIN',
    label: 'GH API throttle',
    hint: 'Calls/min cap (1=paused, 60=default, 600=unthrottled). Sliding window per INFRA-1079.',
    input: 'number',
    min: 1, max: 600, step: 1,
  },
  {
    key: 'FLEET_SIZE',
    label: 'Fleet workers',
    hint: 'Number of concurrent fleet workers (0 = idle). Affects run-fleet.sh / chump fleet up.',
    input: 'number',
    min: 0, max: 64, step: 1,
  },
  {
    key: 'FLEET_MODEL',
    label: 'Fleet model',
    hint: 'Default model for fleet workers. Cost: opus ≫ sonnet ≫ haiku.',
    input: 'select',
    options: ['haiku', 'sonnet', 'opus'],
  },
  {
    key: 'CHUMP_WORK_BACKEND',
    label: 'Work backend',
    hint: 'Which agent shells out the actual coding work between claim and ship.',
    input: 'select',
    options: ['claude', 'opencode', 'aider', 'chump-local', 'exec-gap'],
  },
  {
    key: 'CHUMP_AUTH_MODE',
    label: 'Anthropic auth',
    hint: 'auto = prefer API key, else OAuth. api-key = force. oauth = force subscription.',
    input: 'select',
    options: ['auto', 'api-key', 'oauth'],
  },
  {
    key: 'CHUMP_ROUND_PRIVACY',
    label: 'Privacy mode',
    hint: 'safe = redact third-party content. dogfood = full content (your own repos only).',
    input: 'select',
    options: ['safe', 'dogfood'],
  },
];

class ChumpConfigDials extends HTMLElement {
  constructor() {
    super();
    this._values = {};   // key -> {value, source}
    this._editing = {};  // key -> draft value (string)
    this._pending = {};  // key -> true while POST in-flight
    this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.render();
    this.refresh();
  }

  _authHeaders() {
    try {
      const t = window.chumpPrefs && window.chumpPrefs.get
        ? window.chumpPrefs.get('webToken')
        : null;
      if (t) return { 'X-Chump-Auth': t };
    } catch (_e) {}
    return {};
  }

  async refresh() {
    try {
      const r = await fetch('/api/settings', {
        headers: this._authHeaders(),
        credentials: 'same-origin',
      });
      if (!r.ok) {
        this._error = `Could not load settings: HTTP ${r.status}`;
      } else {
        this._values = await r.json();
        this._error = null;
      }
    } catch (e) {
      this._error = `Network error: ${e.message}`;
    }
    this.render();
  }

  async _apply(key) {
    const draft = this._editing[key];
    if (draft === undefined || draft === null) return;
    this._pending[key] = true;
    this.render();

    try {
      const r = await fetch(`/api/settings/${encodeURIComponent(key)}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...this._authHeaders(),
        },
        credentials: 'same-origin',
        body: JSON.stringify({ value: String(draft) }),
      });
      const body = await r.json().catch(() => ({}));
      if (r.ok && (body.ok !== false)) {
        this._toast('info', `${key} applied`);
        delete this._editing[key];
        // Refresh to pick up new value + source.
        await this.refresh();
      } else {
        const msg = body.error || body.message || `HTTP ${r.status}`;
        this._toast('error', `${key}: ${msg}`);
      }
    } catch (e) {
      this._toast('error', `${key}: ${e.message || 'network error'}`);
    } finally {
      delete this._pending[key];
      this.render();
    }
  }

  _cancel(key) {
    delete this._editing[key];
    this.render();
  }

  _toast(kind, message) {
    this.dispatchEvent(new CustomEvent('chump-toast', {
      bubbles: true, composed: true,
      detail: { kind, message },
    }));
  }

  _esc(s) {
    return String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
  }

  render() {
    const rowsHtml = DIALS.map((d) => {
      const cur = this._values[d.key] || {};
      const value = (this._editing[d.key] !== undefined)
        ? this._editing[d.key]
        : (cur.value || '');
      const source = cur.source || '?';
      const isEditing = this._editing[d.key] !== undefined;
      const pending = !!this._pending[d.key];

      let inputHtml;
      if (d.input === 'select') {
        const opts = d.options.map((o) =>
          `<option value="${this._esc(o)}" ${o === value ? 'selected' : ''}>${this._esc(o)}</option>`
        ).join('');
        inputHtml = `<select data-key="${d.key}" ${pending ? 'disabled' : ''}>${opts}</select>`;
      } else {
        inputHtml = `<input type="${d.input}" data-key="${d.key}" value="${this._esc(value)}"
            ${d.min != null ? `min="${d.min}"` : ''}
            ${d.max != null ? `max="${d.max}"` : ''}
            ${d.step != null ? `step="${d.step}"` : ''}
            ${pending ? 'disabled' : ''}>`;
      }

      const applyBtn = isEditing
        ? `<button class="apply" data-key="${d.key}" ${pending ? 'disabled' : ''}>${pending ? '…' : 'Apply'}</button>
           <button class="cancel" data-key="${d.key}" ${pending ? 'disabled' : ''}>Cancel</button>`
        : '';

      return `
        <div class="dial">
          <div class="dial-head">
            <label>${this._esc(d.label)}</label>
            <span class="src src-${source}">${source}</span>
          </div>
          <div class="dial-row">
            ${inputHtml}
            ${applyBtn}
          </div>
          <div class="hint">${this._esc(d.hint)}</div>
        </div>
      `;
    }).join('');

    const errHtml = this._error
      ? `<div class="err">${this._esc(this._error)}</div>` : '';

    this.shadowRoot.innerHTML = `
      <style>
        :host {
          display: block;
          font: 13px -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          color: #f0f0f0;
        }
        h2 { font-size: 14px; margin: 0 0 12px; opacity: 0.7; text-transform: uppercase; letter-spacing: 1px; }
        .dial {
          padding: 12px 0;
          border-bottom: 1px solid rgba(255,255,255,0.06);
        }
        .dial-head {
          display: flex; align-items: center; gap: 8px; margin-bottom: 6px;
        }
        .dial-head label { font-weight: 600; }
        .src {
          font-size: 10px; padding: 1px 6px; border-radius: 10px;
          letter-spacing: 0.5px;
        }
        .src-env     { background: rgba(48,209,88,0.2); color: #30d158; }
        .src-config  { background: rgba(10,132,255,0.2); color: #0a84ff; }
        .src-default { background: rgba(255,255,255,0.08); color: #aaa; }
        .dial-row {
          display: flex; gap: 6px; align-items: center; flex-wrap: wrap;
        }
        input, select {
          background: rgba(255,255,255,0.06);
          color: #f0f0f0;
          border: 1px solid rgba(255,255,255,0.15);
          border-radius: 4px;
          padding: 4px 8px;
          font: inherit;
          min-width: 120px;
        }
        button {
          font: 12px inherit;
          padding: 4px 10px;
          border-radius: 4px;
          cursor: pointer;
          border: 1px solid rgba(255,255,255,0.15);
          background: rgba(255,255,255,0.06);
          color: #f0f0f0;
        }
        button.apply { background: rgba(10,132,255,0.2); border-color: rgba(10,132,255,0.4); color: #0a84ff; }
        button:hover:not([disabled]) { background: rgba(255,255,255,0.12); }
        button[disabled] { opacity: 0.5; cursor: not-allowed; }
        .hint {
          font-size: 11px; opacity: 0.6; margin-top: 4px; line-height: 1.4;
        }
        .err {
          padding: 8px; margin-bottom: 12px;
          background: rgba(255,69,58,0.1); color: #ff453a;
          border: 1px solid rgba(255,69,58,0.3); border-radius: 4px;
        }
      </style>
      <h2>Fleet Control</h2>
      ${errHtml}
      ${rowsHtml}
    `;

    // Wire input/select change → editing draft.
    this.shadowRoot.querySelectorAll('input[data-key], select[data-key]').forEach((el) => {
      el.addEventListener('input', (e) => {
        const k = e.target.dataset.key;
        this._editing[k] = e.target.value;
        // Re-render to show Apply button (but preserve focus).
        this.render();
        const next = this.shadowRoot.querySelector(`[data-key="${k}"]`);
        if (next) { next.focus(); next.selectionStart = next.value.length; }
      });
    });
    this.shadowRoot.querySelectorAll('button.apply').forEach((b) => {
      b.addEventListener('click', () => this._apply(b.dataset.key));
    });
    this.shadowRoot.querySelectorAll('button.cancel').forEach((b) => {
      b.addEventListener('click', () => this._cancel(b.dataset.key));
    });
  }
}

customElements.define('chump-config-dials', ChumpConfigDials);
