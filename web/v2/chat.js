// Chump v2 — Chat pane Web Component.
// Wires directly to /api/chat SSE stream and /api/stack-status for model info.
// No build step, no CDN. Air-gap safe by construction.

// ── Inline SSE block parser (ported from /sse-event-parser.js) ─────────────────
function createSseBlockParser(onParsedEvent) {
  let carry = '', blockEvent = '', blockDataLines = [];
  const flushBlock = () => {
    if (!blockEvent && blockDataLines.length === 0) return;
    const dataStr = blockDataLines.join('\n');
    let ev = blockEvent;
    if (!ev && dataStr) {
      try { const p = JSON.parse(dataStr); if (p?.type) ev = p.type; } catch (_) {}
    }
    if (ev && dataStr) {
      try { onParsedEvent({ event: ev, data: JSON.parse(dataStr) }); } catch (_) {}
    }
    blockEvent = ''; blockDataLines = [];
  };
  const handleLine = (raw) => {
    const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    if (!line) { flushBlock(); return; }
    if (line.startsWith('event:')) { if (blockEvent || blockDataLines.length) flushBlock(); blockEvent = line.slice(6).trim(); }
    else if (line.startsWith('data:')) blockDataLines.push(line.slice(5).trimStart());
  };
  return {
    push(chunk) {
      carry += String(chunk).replace(/\r\n/g, '\n').replace(/\r/g, '\n');
      for (;;) { const i = carry.indexOf('\n'); if (i < 0) break; handleLine(carry.slice(0, i)); carry = carry.slice(i + 1); }
    },
    finish() { if (carry.length) { handleLine(carry); carry = ''; } flushBlock(); },
  };
}

// ── Simple markdown renderer (subset) ──────────────────────────────────────────
function renderMarkdown(text) {
  return text
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/\*(.+?)\*/g, '<em>$1</em>')
    .replace(/\n\n+/g, '</p><p>')
    .replace(/\n/g, '<br>')
    .replace(/^/, '<p>').replace(/$/, '</p>');
}

// ── <chump-chat> ───────────────────────────────────────────────────────────────
const CHAT_CSS = `
  :host { display: flex; flex-direction: column; height: 100%; overflow: hidden; }

  #messages {
    flex: 1; overflow-y: auto; padding: 16px;
    display: flex; flex-direction: column; gap: 12px;
    scroll-behavior: smooth;
  }

  .msg { max-width: 88%; display: flex; flex-direction: column; gap: 4px; }
  .msg.user { align-self: flex-end; align-items: flex-end; }
  .msg.assistant { align-self: flex-start; align-items: flex-start; }

  .bubble {
    padding: 10px 14px; border-radius: 14px; font-size: 14px; line-height: 1.5;
    word-break: break-word;
  }
  .msg.user .bubble {
    background: var(--accent, #0a84ff); color: #fff;
    border-bottom-right-radius: 4px;
  }
  .msg.assistant .bubble {
    background: var(--bg-surface, #141414); color: var(--text, #f0f0f0);
    border: 1px solid var(--border, rgba(255,255,255,0.08));
    border-bottom-left-radius: 4px;
  }
  .bubble p { margin: 0; }
  .bubble p + p { margin-top: 8px; }
  .bubble code {
    background: var(--bg-elevated, #1e1e1e); padding: 1px 5px;
    border-radius: 4px; font-family: "SF Mono", monospace; font-size: 12px;
  }

  .tool-card {
    margin-top: 6px; padding: 8px 12px;
    background: var(--bg-elevated, #1e1e1e);
    border: 1px solid var(--border, rgba(255,255,255,0.08));
    border-radius: 10px; font-size: 12px; color: var(--text-secondary, #8a8a8e);
  }
  .tool-name {
    font-family: "SF Mono", monospace; font-weight: 600;
    color: var(--accent, #0a84ff); margin-bottom: 4px;
  }
  .tool-result { margin-top: 4px; color: var(--text-secondary, #8a8a8e); white-space: pre-wrap; max-height: 120px; overflow-y: auto; }

  .thinking-line {
    font-size: 11px; color: var(--text-secondary, #8a8a8e); padding: 4px 0 0 2px;
    font-style: italic;
  }

  .empty-state {
    flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center;
    gap: 12px; padding: 32px; text-align: center; color: var(--text-secondary, #8a8a8e);
  }
  .empty-icon { font-size: 40px; }
  .empty-title { font-size: 17px; font-weight: 600; color: var(--text, #f0f0f0); }
  .empty-body { font-size: 13px; max-width: 340px; line-height: 1.6; }

  #composer {
    display: flex; align-items: flex-end; gap: 8px;
    padding: 10px 16px calc(10px + var(--safe-bottom, 0px));
    border-top: 1px solid var(--border, rgba(255,255,255,0.08));
    background: var(--bg, #0a0a0a);
    flex-shrink: 0;
  }
  #input {
    flex: 1; background: var(--bg-surface, #141414);
    border: 1px solid var(--border, rgba(255,255,255,0.08));
    color: var(--text, #f0f0f0); border-radius: 14px;
    padding: 10px 14px; font-size: 14px; resize: none; min-height: 40px; max-height: 140px;
    font-family: inherit; line-height: 1.4; outline: none;
  }
  #input:focus { border-color: var(--accent, #0a84ff); }
  #send-btn {
    width: 36px; height: 36px; border-radius: 50%; background: var(--accent, #0a84ff);
    border: none; color: #fff; cursor: pointer; font-size: 16px;
    display: flex; align-items: center; justify-content: center;
    flex-shrink: 0; transition: opacity 0.15s;
  }
  #send-btn:disabled { opacity: 0.4; cursor: default; }
  #stop-btn {
    width: 36px; height: 36px; border-radius: 50%;
    background: var(--bg-surface, #141414);
    border: 1px solid var(--border, rgba(255,255,255,0.08));
    color: var(--text-secondary, #8a8a8e); cursor: pointer; font-size: 14px;
    display: none; align-items: center; justify-content: center; flex-shrink: 0;
  }
  #stop-btn.visible { display: flex; }
`;

class ChumpChat extends HTMLElement {
  #shadow;
  #sessionId = null;
  #abortCtrl = null;
  #model = null;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#render();
    this.#checkModel();
  }

  #render() {
    this.#shadow.innerHTML = `
      <style>${CHAT_CSS}</style>
      <div id="messages"></div>
      <div id="composer">
        <textarea id="input" placeholder="Message Chump…" rows="1" aria-label="Chat input"></textarea>
        <button id="stop-btn" title="Stop" aria-label="Stop generation">■</button>
        <button id="send-btn" aria-label="Send">▶</button>
      </div>
    `;
    const input = this.#shadow.getElementById('input');
    const sendBtn = this.#shadow.getElementById('send-btn');
    const stopBtn = this.#shadow.getElementById('stop-btn');

    sendBtn.addEventListener('click', () => this.#send());
    stopBtn.addEventListener('click', () => this.#stop());
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); this.#send(); }
    });
    input.addEventListener('input', () => {
      input.style.height = 'auto';
      input.style.height = Math.min(input.scrollHeight, 140) + 'px';
    });
  }

  #checkModel() {
    fetch('/api/stack-status')
      .then((r) => r.json())
      .then((d) => {
        const model = d.openai_model || d.openai_api_base || null;
        this.#model = model;
        if (!model && !d.openai_api_base) this.#showEmptyState();
      })
      .catch(() => {
        this.#showEmptyState('offline');
      });
  }

  #showEmptyState(reason = 'no-model') {
    const msgs = this.#shadow.getElementById('messages');
    msgs.innerHTML = `
      <div class="empty-state">
        <span class="empty-icon">🤖</span>
        <span class="empty-title">${reason === 'offline' ? 'Agent offline' : 'No model configured'}</span>
        <p class="empty-body">${
          reason === 'offline'
            ? 'Could not reach the Chump agent. Start it with <code>chump --web</code> and reload.'
            : 'Set <code>OPENAI_API_BASE</code> and <code>OPENAI_MODEL</code>, then start with <code>chump --web</code>.'
        }</p>
      </div>
    `;
    const input = this.#shadow.getElementById('input');
    const sendBtn = this.#shadow.getElementById('send-btn');
    if (input) input.disabled = true;
    if (sendBtn) sendBtn.disabled = true;
  }

  #send() {
    const input = this.#shadow.getElementById('input');
    const sendBtn = this.#shadow.getElementById('send-btn');
    const stopBtn = this.#shadow.getElementById('stop-btn');
    const text = input.value.trim();
    if (!text) return;

    input.value = '';
    input.style.height = 'auto';
    sendBtn.disabled = true;
    stopBtn.classList.add('visible');

    this.#appendMsg('user', text);
    const assistantEl = this.#appendMsg('assistant', '', true);
    const bubble = assistantEl.querySelector('.bubble');

    this.#abortCtrl = new AbortController();
    let fullText = '';
    let currentToolCard = null;

    const parser = createSseBlockParser(({ event, data }) => {
      if (event === 'web_session_ready' && data.session_id) {
        this.#sessionId = data.session_id;
      } else if (event === 'thinking' || event === 'model_call_start') {
        let hint = assistantEl.querySelector('.thinking-line');
        if (!hint) { hint = document.createElement('div'); hint.className = 'thinking-line'; assistantEl.appendChild(hint); }
        hint.textContent = event === 'model_call_start'
          ? `Model round ${(data.round || 0) + 1}…`
          : `Thinking… ${data.elapsed_ms || 0}ms`;
      } else if (event === 'text_delta' && data.delta) {
        fullText += data.delta;
        bubble.innerHTML = renderMarkdown(fullText);
        this.#scrollBottom();
      } else if (event === 'text_complete' && data.text) {
        fullText = data.text;
        bubble.innerHTML = renderMarkdown(fullText);
        this.#scrollBottom();
      } else if (event === 'tool_call_start') {
        currentToolCard = document.createElement('div');
        currentToolCard.className = 'tool-card';
        currentToolCard.innerHTML = `<div class="tool-name">⚡ ${data.tool || 'tool'}</div><div class="tool-args">${this.#fmtArgs(data.args)}</div>`;
        assistantEl.appendChild(currentToolCard);
        this.#scrollBottom();
      } else if (event === 'tool_call_result') {
        if (currentToolCard) {
          const result = document.createElement('div');
          result.className = 'tool-result';
          result.textContent = typeof data.result === 'string' ? data.result.slice(0, 400) : JSON.stringify(data.result)?.slice(0, 400) ?? '';
          currentToolCard.appendChild(result);
        }
      } else if (event === 'turn_complete') {
        const hint = assistantEl.querySelector('.thinking-line');
        if (hint) hint.remove();
      }
    });

    fetch('/api/chat', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ message: text, session_id: this.#sessionId }),
      signal: this.#abortCtrl.signal,
    })
      .then(async (res) => {
        if (!res.ok) { bubble.innerHTML = `<p>Error ${res.status}</p>`; return; }
        const reader = res.body.getReader();
        const dec = new TextDecoder();
        for (;;) {
          const { done, value } = await reader.read();
          if (value) parser.push(dec.decode(value, { stream: true }));
          if (done) { parser.push(dec.decode(new Uint8Array(), { stream: false })); parser.finish(); break; }
        }
        if (!fullText && !assistantEl.querySelector('.tool-card')) {
          bubble.innerHTML = '<em style="color:var(--text-secondary,#8a8a8e)">No response received. Is the agent running?</em>';
        }
      })
      .catch((err) => {
        if (err.name !== 'AbortError') bubble.innerHTML = `<em>Connection lost: ${err.message}</em>`;
      })
      .finally(() => {
        this.#abortCtrl = null;
        sendBtn.disabled = false;
        stopBtn.classList.remove('visible');
        const hint = assistantEl.querySelector('.thinking-line');
        if (hint) hint.remove();
      });
  }

  #stop() {
    this.#abortCtrl?.abort();
  }

  #appendMsg(role, text, streaming = false) {
    const msgs = this.#shadow.getElementById('messages');
    // Remove empty state if present
    const empty = msgs.querySelector('.empty-state');
    if (empty) empty.remove();

    const el = document.createElement('div');
    el.className = `msg ${role}`;
    el.innerHTML = `<div class="bubble">${role === 'user' ? this.#esc(text) : (streaming ? '<span class="cursor">▋</span>' : renderMarkdown(text))}</div>`;
    msgs.appendChild(el);
    this.#scrollBottom();
    return el;
  }

  #scrollBottom() {
    const msgs = this.#shadow.getElementById('messages');
    msgs.scrollTop = msgs.scrollHeight;
  }

  #esc(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
  #fmtArgs(args) {
    if (!args) return '';
    try {
      const s = typeof args === 'string' ? args : JSON.stringify(args, null, 2);
      return `<pre style="margin:0;font-size:11px;opacity:0.6;max-height:60px;overflow:hidden;white-space:pre-wrap">${this.#esc(s.slice(0,200))}</pre>`;
    } catch { return ''; }
  }
}
customElements.define('chump-chat', ChumpChat);

// ── <chump-model-picker> (full-screen overlay on click) ───────────────────────
const PICKER_CSS = `
  :host { display: inline-block; }
  .model-btn {
    font-size: 11px; font-family: "SF Mono", monospace;
    padding: 3px 8px; background: var(--bg-surface, #141414);
    border: 1px solid var(--border, rgba(255,255,255,0.08));
    border-radius: 6px; color: var(--text-secondary, #8a8a8e);
    cursor: pointer; white-space: nowrap; max-width: 180px;
    overflow: hidden; text-overflow: ellipsis;
    transition: border-color 0.15s; line-height: 1.6;
  }
  .model-btn:hover { border-color: var(--accent, #0a84ff); color: var(--text, #f0f0f0); }
  .model-btn .dot { display: inline-block; width: 5px; height: 5px; border-radius: 50%; margin-right: 5px; vertical-align: middle; }
  .dot.ok { background: var(--success, #30d158); }
  .dot.err { background: var(--error, #ff453a); }
  dialog {
    background: var(--bg-surface, #141414); border: 1px solid var(--border, rgba(255,255,255,0.08));
    border-radius: 14px; padding: 20px; color: var(--text, #f0f0f0); max-width: 400px; width: 90vw;
  }
  dialog::backdrop { background: rgba(0,0,0,0.6); }
  h3 { font-size: 15px; margin: 0 0 12px; }
  .model-row { display: flex; flex-direction: column; gap: 4px; margin-bottom: 12px; }
  label { font-size: 12px; color: var(--text-secondary, #8a8a8e); }
  .model-info { font-family: "SF Mono", monospace; font-size: 13px; padding: 8px 12px; background: var(--bg-elevated, #1e1e1e); border-radius: 8px; }
  .close-btn { margin-top: 8px; padding: 8px 16px; background: var(--bg-elevated, #1e1e1e); border: 1px solid var(--border, rgba(255,255,255,0.08)); color: var(--text, #f0f0f0); border-radius: 8px; cursor: pointer; font-size: 13px; }
`;

class ChumpModelPicker extends HTMLElement {
  #shadow;
  #status = null;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#shadow.innerHTML = `
      <style>${PICKER_CSS}</style>
      <button class="model-btn" title="Model settings"><span class="dot"></span><span id="label">loading…</span></button>
      <dialog id="modal">
        <h3>Model Configuration</h3>
        <div id="modal-body"></div>
        <button class="close-btn" id="close-btn">Close</button>
      </dialog>
    `;
    this.#shadow.querySelector('.model-btn').addEventListener('click', () => this.#openModal());
    this.#shadow.getElementById('close-btn').addEventListener('click', () => this.#shadow.getElementById('modal').close());
    this.#poll();
  }

  #poll() {
    fetch('/api/stack-status')
      .then((r) => r.json())
      .then((d) => {
        this.#status = d;
        const model = d.openai_model || (d.openai_api_base ? 'custom' : null);
        const ok = !!(d.openai_api_base || d.openai_model);
        this.#shadow.querySelector('.dot').className = `dot ${ok ? 'ok' : 'err'}`;
        this.#shadow.getElementById('label').textContent = model || 'no model';
      })
      .catch(() => {
        this.#shadow.querySelector('.dot').className = 'dot err';
        this.#shadow.getElementById('label').textContent = 'offline';
      });
  }

  #openModal() {
    const body = this.#shadow.getElementById('modal-body');
    const d = this.#status;
    body.innerHTML = d ? `
      <div class="model-row"><label>Active model</label><div class="model-info">${d.openai_model || '(not set)'}</div></div>
      <div class="model-row"><label>API base</label><div class="model-info">${d.openai_api_base || '(not set)'}</div></div>
      <div class="model-row"><label>Provider status</label><div class="model-info">${d.inference?.models_reachable === true ? '✓ reachable' : d.inference?.models_reachable === false ? '✗ unreachable' : '? unknown'}</div></div>
      <div class="model-row"><label>Air-gap mode</label><div class="model-info">${d.air_gap_mode ? 'enabled' : 'disabled'}</div></div>
    ` : '<p>Loading…</p>';
    this.#shadow.getElementById('modal').showModal();
    this.#poll();
  }
}
customElements.define('chump-model-picker', ChumpModelPicker);
