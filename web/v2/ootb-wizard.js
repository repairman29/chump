// Chump v2 — Tauri-only OOTB setup wizard.
// Ported from web/ootb-wizard.js as a Shadow-DOM Web Component (INFRA-250).
// Activates ONLY when isTauriHost() — same gate as v1.

function isTauriHost() {
  try {
    const h = location.hostname;
    return h === 'tauri.localhost' || (typeof h === 'string' && h.endsWith('.tauri.localhost'));
  } catch (_) {
    return false;
  }
}

function tauriInvoke(cmd, args) {
  try {
    const w = window.__TAURI__;
    if (!w) return null;
    if (w.core && typeof w.core.invoke === 'function') {
      return args === undefined ? w.core.invoke(cmd) : w.core.invoke(cmd, args);
    }
    if (typeof w.invoke === 'function') {
      return args === undefined ? w.invoke(cmd) : w.invoke(cmd, args);
    }
  } catch (_) {}
  return null;
}

function getTauriListen() {
  const w = window.__TAURI__;
  if (!w) return null;
  if (w.event && typeof w.event.listen === 'function') return w.event.listen.bind(w.event);
  if (w.core && w.core.event && typeof w.core.event.listen === 'function') {
    return w.core.event.listen.bind(w.core.event);
  }
  return null;
}

const WIZARD_CSS = `
  :host {
    display: none;
    position: fixed;
    inset: 0;
    z-index: 250;
    pointer-events: none;
  }
  :host(.visible) {
    display: block;
    pointer-events: auto;
  }
  .ootb-root {
    display: none;
    visibility: hidden;
    pointer-events: none;
    position: fixed;
    inset: 0;
    z-index: 250;
    background: #030508;
    background-image:
      radial-gradient(ellipse 120% 80% at 50% -20%, rgba(10, 132, 255, 0.22), transparent 55%),
      radial-gradient(ellipse 90% 60% at 100% 60%, rgba(88, 86, 214, 0.12), transparent 50%),
      radial-gradient(ellipse 70% 50% at 0% 80%, rgba(48, 209, 88, 0.06), transparent 45%),
      linear-gradient(165deg, #0a1628 0%, #000 42%, #061018 100%);
    flex-direction: column;
    align-items: center;
    justify-content: flex-start;
    padding: 28px 20px 40px;
    overflow-y: auto;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    font-size: 14px;
    color: #f0f0f0;
    --text-secondary: #8a8a8e;
    --accent: #0a84ff;
    --bg: #0a0a0a;
    --border: rgba(255,255,255,0.08);
  }
  .ootb-root::before {
    content: "";
    position: fixed;
    inset: 0;
    pointer-events: none;
    background: radial-gradient(ellipse at center, transparent 0%, rgba(0,0,0,0.45) 100%);
    z-index: 0;
  }
  .ootb-root > * { position: relative; z-index: 1; }
  .ootb-root.visible {
    display: flex;
    visibility: visible;
    pointer-events: auto;
  }
  @keyframes ootb-card-in {
    from { opacity: 0; transform: translateY(18px) scale(0.97); }
    to   { opacity: 1; transform: none; }
  }
  @keyframes ootb-shimmer {
    0%   { background-position: 200% 0; }
    100% { background-position: -200% 0; }
  }
  @keyframes ootb-success-pop {
    0%   { opacity: 0; transform: scale(0.92); }
    70%  { opacity: 1; transform: scale(1.02); }
    100% { opacity: 1; transform: scale(1); }
  }
  @media (prefers-reduced-motion: no-preference) {
    .ootb-root.visible .ootb-card {
      animation: ootb-card-in 0.45s cubic-bezier(0.22, 1, 0.36, 1) both;
    }
  }
  .ootb-card {
    width: 100%;
    max-width: 520px;
    background: rgba(28, 28, 30, 0.92);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 0.5px solid rgba(255,255,255,0.08);
    border-radius: 18px;
    padding: 26px 24px 24px;
    margin-top: 8px;
    box-shadow:
      0 0 0 1px rgba(0,0,0,0.35),
      0 24px 48px rgba(0,0,0,0.45),
      0 0 80px rgba(10, 132, 255, 0.06);
    box-sizing: border-box;
  }
  .ootb-kicker {
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: rgba(142, 142, 147, 0.95);
    margin-bottom: 6px;
  }
  .ootb-title {
    font-size: clamp(1.35rem, 3vw, 1.85rem);
    font-weight: 700;
    margin-bottom: 4px;
    line-height: 1.2;
    background: linear-gradient(135deg, #fff 0%, #a8c8ff 55%, #7eb6ff 100%);
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
  }
  .ootb-sub {
    color: var(--text-secondary);
    font-size: 14px;
    line-height: 1.5;
    margin-bottom: 16px;
  }
  .ootb-status {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 12px;
    color: #98989d;
    min-height: 2.75em;
    white-space: pre-wrap;
    word-break: break-word;
    margin-bottom: 14px;
    padding: 10px 12px;
    border-radius: 10px;
    background: rgba(0,0,0,0.28);
    border: 0.5px solid rgba(255,255,255,0.06);
    transition: border-color 0.2s ease, color 0.2s ease;
  }
  .ootb-status.ootb-status--ok  { color: #b8f0c8; border-color: rgba(48, 209, 88, 0.25); }
  .ootb-status.ootb-status--err { color: #ffb4ab; border-color: rgba(255, 69, 58, 0.35); }
  .ootb-status.ootb-status--busy { color: #a8e1ff; border-color: rgba(10, 132, 255, 0.25); }
  @media (prefers-reduced-motion: no-preference) {
    .ootb-status.ootb-status--busy {
      background: linear-gradient(
        90deg,
        rgba(0,0,0,0.28) 0%,
        rgba(10,132,255,0.12) 50%,
        rgba(0,0,0,0.28) 100%
      );
      background-size: 200% 100%;
      animation: ootb-shimmer 2.2s ease-in-out infinite;
    }
  }
  .ootb-actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 8px; }
  .ootb-btn {
    padding: 10px 18px;
    border-radius: 10px;
    border: none;
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    background: linear-gradient(180deg, #2a9bff, #0a84ff 40%, #0066d6);
    color: #fff;
    box-shadow: 0 1px 0 rgba(255,255,255,0.12) inset, 0 4px 14px rgba(10,132,255,0.25);
    transition: transform 0.15s ease, box-shadow 0.15s ease, filter 0.15s ease;
    font-family: inherit;
  }
  .ootb-btn:hover:not(:disabled) {
    filter: brightness(1.06);
    box-shadow: 0 1px 0 rgba(255,255,255,0.15) inset, 0 6px 20px rgba(10,132,255,0.32);
  }
  .ootb-btn:active:not(:disabled) { transform: scale(0.98); }
  .ootb-btn:focus-visible {
    outline: none;
    box-shadow: 0 0 0 3px rgba(10, 132, 255, 0.45), 0 4px 14px rgba(10,132,255,0.25);
  }
  .ootb-btn:disabled { opacity: 0.45; cursor: not-allowed; box-shadow: none; }
  .ootb-btn.secondary {
    background: rgba(0,0,0,0.35);
    color: #f0f0f0;
    border: 0.5px solid rgba(255,255,255,0.12);
    box-shadow: none;
  }
  .ootb-btn.secondary:hover:not(:disabled) {
    background: rgba(255,255,255,0.06);
    border-color: rgba(255,255,255,0.18);
  }
  .ootb-btn.secondary:focus-visible { box-shadow: 0 0 0 3px rgba(255,255,255,0.2); }
  .ootb-progress {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    margin-bottom: 4px;
  }
  .ootb-dot {
    width: 8px; height: 8px;
    border-radius: 50%;
    background: rgba(255,255,255,0.12);
    border: 0.5px solid rgba(255,255,255,0.08);
    transition: transform 0.25s ease, background 0.25s ease, box-shadow 0.25s ease;
  }
  .ootb-dot.done {
    background: rgba(48, 209, 88, 0.85);
    border-color: rgba(48, 209, 88, 0.4);
    box-shadow: 0 0 10px rgba(48, 209, 88, 0.35);
  }
  .ootb-dot.active {
    background: #0a84ff;
    border-color: rgba(10, 132, 255, 0.6);
    transform: scale(1.35);
    box-shadow: 0 0 14px rgba(10, 132, 255, 0.45);
  }
  .ootb-step-hint {
    font-size: 11px;
    color: var(--text-secondary);
    margin-bottom: 2px;
    text-align: center;
  }
  .ootb-foot {
    margin-top: 18px;
    font-size: 11px;
    color: rgba(142, 142, 147, 0.75);
    text-align: center;
    line-height: 1.5;
    max-width: 520px;
  }
  .ootb-foot a { color: #64b5ff; text-decoration: none; }
  .ootb-foot a:hover { text-decoration: underline; }
  label.ootb-label { display: block; font-size: 12px; color: var(--text-secondary); margin-bottom: 6px; }
  select.ootb-select {
    width: 100%; padding: 10px 12px; border-radius: 8px;
    border: 0.5px solid var(--border); background: var(--bg);
    color: #f0f0f0; font: inherit; margin-bottom: 12px;
  }
  input.ootb-input {
    width: 100%; padding: 10px 12px; border-radius: 8px;
    border: 0.5px solid var(--border); background: var(--bg);
    color: #f0f0f0; font: inherit; margin-bottom: 10px; font-size: 13px;
    box-sizing: border-box;
  }
  input.ootb-input::placeholder { color: var(--text-secondary); opacity: 0.85; }
  details.ootb-advanced {
    margin: 12px 0 4px;
    border: 0.5px solid var(--border);
    border-radius: 10px;
    padding: 8px 12px;
    background: rgba(0,0,0,0.25);
  }
  details.ootb-advanced summary {
    cursor: pointer; font-size: 13px; color: var(--text-secondary); user-select: none;
  }
  details.ootb-advanced summary:hover { color: #f0f0f0; }
  .ootb-pull-log-wrap { position: relative; margin-top: 10px; }
  .ootb-pull-log-wrap::before {
    content: ""; position: absolute; top: 0; left: 0; right: 0; height: 20px;
    border-radius: 8px 8px 0 0;
    background: linear-gradient(to bottom, rgba(13,13,15,0.95), transparent);
    pointer-events: none; z-index: 1;
  }
  pre.ootb-pull-log {
    max-height: 200px; overflow: auto; font-size: 11px; line-height: 1.45;
    padding: 12px; margin: 0; border-radius: 10px; background: #08090c;
    border: 0.5px solid rgba(255,255,255,0.08); color: #9bdcff;
    white-space: pre-wrap; word-break: break-word;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
  }
  pre.ootb-pull-log:empty::before {
    content: attr(data-placeholder); color: rgba(142,142,147,0.65); font-style: italic;
  }
  .ootb-back-row { margin-top: 14px; padding-top: 12px; border-top: 0.5px solid var(--border); }
  .ootb-reveal-row { margin-bottom: 12px; }
  .ootb-btn--sm { padding: 8px 14px; font-size: 13px; }
  .ootb-path-preview {
    font-size: 12px; color: rgba(142,142,147,0.95);
    margin: -6px 0 14px; line-height: 1.45; word-break: break-word;
  }
  .ootb-pull-toolbar { display: flex; justify-content: flex-end; margin-top: 8px; gap: 8px; }
  .ootb-skip-confirm {
    padding: 14px; border-radius: 12px;
    border: 0.5px solid rgba(255,159,10,0.35);
    background: rgba(255,159,10,0.08); margin-bottom: 4px;
  }
  .ootb-skip-confirm .ootb-sub { margin-bottom: 12px; }
  .ootb-success-overlay {
    position: fixed; inset: 0; z-index: 280; display: none;
    align-items: center; justify-content: center; padding: 24px;
    background: rgba(0,0,0,0.55);
    backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px);
  }
  .ootb-success-overlay.visible { display: flex; }
  .ootb-success-card {
    text-align: center; padding: 36px 40px; border-radius: 20px;
    background: rgba(28,28,30,0.95);
    border: 0.5px solid rgba(48,209,88,0.35);
    box-shadow: 0 20px 60px rgba(0,0,0,0.5), 0 0 40px rgba(48,209,88,0.12);
    max-width: 340px;
  }
  @media (prefers-reduced-motion: no-preference) {
    .ootb-success-overlay.visible .ootb-success-card {
      animation: ootb-success-pop 0.55s cubic-bezier(0.22, 1, 0.36, 1) both;
    }
  }
  .ootb-success-icon {
    width: 56px; height: 56px; margin: 0 auto 14px; border-radius: 50%;
    background: rgba(48,209,88,0.2); border: 2px solid rgba(48,209,88,0.55);
    color: #30d158; font-size: 26px; line-height: 52px; font-weight: 700;
  }
  .ootb-success-title { font-size: 1.35rem; font-weight: 700; color: #fff; margin-bottom: 6px; }
  .ootb-success-sub { font-size: 14px; color: var(--text-secondary); line-height: 1.45; }
  .ootb-success-hint {
    font-size: 12px; color: var(--text-secondary); line-height: 1.45; margin-top: 10px; max-width: 22em;
  }
  kbd {
    font-size: 10px; opacity: 0.85;
    border: 0.5px solid rgba(255,255,255,0.25); border-radius: 3px;
    padding: 1px 4px; background: rgba(255,255,255,0.06);
  }
  code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em; }
`;

const WIZARD_HTML = `
  <div class="ootb-root" id="ootb-root" role="dialog" aria-modal="true"
       aria-labelledby="ootb-step-heading" aria-describedby="ootb-status" aria-hidden="true">
    <div class="ootb-progress" id="ootb-progress-dots" aria-label="Setup progress">
      <span class="ootb-dot" data-ootb-dot="1" title="Welcome"></span>
      <span class="ootb-dot" data-ootb-dot="2" title="Ollama or API"></span>
      <span class="ootb-dot" data-ootb-dot="3" title="Config"></span>
      <span class="ootb-dot" data-ootb-dot="4" title="Model"></span>
      <span class="ootb-dot" data-ootb-dot="5" title="Start"></span>
    </div>
    <div class="ootb-step-hint" id="ootb-step-hint">Step 1 of 5</div>
    <div class="ootb-card">
      <div class="ootb-kicker">First-time setup</div>
      <h2 class="ootb-title" id="ootb-step-heading">Welcome to Chump</h2>
      <div class="ootb-status" id="ootb-status" role="status" aria-live="polite"></div>
      <div class="ootb-reveal-row" id="ootb-reveal-row" style="display:none">
        <button type="button" class="ootb-btn secondary ootb-btn--sm" id="ootb-reveal-folder">Open Chump data folder</button>
      </div>

      <div id="ootb-step-1">
        <div id="ootb-step-1-main">
          <p class="ootb-sub">Set up <strong>local AI</strong> in a few steps: we use <strong>Ollama</strong> by default (private, on your machine). Pick a model size that fits your disk — or point at <strong>LM Studio / MLX / any OpenAI-compatible URL</strong> in the next screen.</p>
          <div class="ootb-actions">
            <button type="button" class="ootb-btn" id="ootb-next-1">Continue</button>
            <button type="button" class="ootb-btn secondary" id="ootb-skip-wizard">Skip — I already have a .env</button>
          </div>
        </div>
        <div id="ootb-skip-confirm" class="ootb-skip-confirm" style="display:none"
             role="region" aria-labelledby="ootb-skip-confirm-title">
          <p class="ootb-sub" id="ootb-skip-confirm-title"><strong>Skip setup?</strong> Cowork expects a working <code>.env</code> and a reachable inference server. Only skip if you have already configured Chump.</p>
          <div class="ootb-actions">
            <button type="button" class="ootb-btn" id="ootb-skip-cancel">Continue setup</button>
            <button type="button" class="ootb-btn secondary" id="ootb-skip-confirm-btn">Skip anyway</button>
          </div>
        </div>
      </div>

      <div id="ootb-step-2" style="display:none">
        <p class="ootb-sub">Install <strong>Ollama</strong> if you want the default path, then verify it's available. Keep the Ollama app or <code>ollama serve</code> running while you chat. (If you use another server only, use the button below.)</p>
        <div class="ootb-actions">
          <button type="button" class="ootb-btn secondary" id="ootb-open-download">Open Ollama download</button>
          <button type="button" class="ootb-btn secondary" id="ootb-check-ollama">Check again</button>
          <button type="button" class="ootb-btn" id="ootb-next-2">Ollama is ready — next</button>
          <button type="button" class="ootb-btn secondary" id="ootb-skip-ollama-path">I use LM Studio, MLX, or remote API only</button>
        </div>
        <div class="ootb-back-row">
          <button type="button" class="ootb-btn secondary" id="ootb-back-2">Back</button>
        </div>
      </div>

      <div id="ootb-step-3" style="display:none">
        <p class="ootb-sub">We'll create Chump's folder under your user <strong>Application Support</strong> (or the equivalent on your OS). Chat sessions and SQLite live there — no git clone required.</p>
        <p class="ootb-path-preview" id="ootb-path-preview" aria-live="polite"></p>
        <label class="ootb-label" for="ootb-model-select">Default model (Ollama tag)</label>
        <select id="ootb-model-select" class="ootb-select" aria-label="Ollama model">
          <option value="llama3.2:3b">llama3.2:3b (~2 GB) — quickest</option>
          <option value="qwen2.5:7b">qwen2.5:7b (~4.5 GB) — balanced (recommended)</option>
          <option value="qwen2.5:14b">qwen2.5:14b (~9 GB) — strongest</option>
        </select>
        <details class="ootb-advanced" id="ootb-advanced-details">
          <summary>Advanced — OpenAI-compatible API base</summary>
          <p class="ootb-sub" style="margin-top:10px;margin-bottom:8px">Leave empty for Ollama at <code>http://127.0.0.1:11434/v1</code>. Otherwise set your server URL (must include <code>/v1</code> if your stack expects it).</p>
          <label class="ootb-label" for="ootb-api-base">API base URL</label>
          <input type="url" class="ootb-input" id="ootb-api-base"
                 placeholder="http://127.0.0.1:1234/v1" autocomplete="off" />
        </details>
        <div class="ootb-actions">
          <button type="button" class="ootb-btn" id="ootb-create-config">Create config</button>
        </div>
        <div class="ootb-back-row">
          <button type="button" class="ootb-btn secondary" id="ootb-back-3">Back</button>
        </div>
      </div>

      <div id="ootb-step-4" style="display:none">
        <div id="ootb-step-4-ollama">
          <p class="ootb-sub">Download the model with Ollama. This is usually the longest step; progress streams below. You can skip if you already ran <code>ollama pull</code> for this tag.</p>
          <div class="ootb-pull-log-wrap">
            <pre class="ootb-pull-log" id="ootb-pull-log" aria-label="Download progress"
                 data-placeholder="Waiting for output from ollama pull…"></pre>
          </div>
          <div class="ootb-pull-toolbar">
            <button type="button" class="ootb-btn secondary ootb-btn--sm" id="ootb-copy-pull-log">Copy log</button>
          </div>
          <div class="ootb-actions">
            <button type="button" class="ootb-btn" id="ootb-pull">Download model</button>
            <button type="button" class="ootb-btn secondary" id="ootb-skip-pull">Skip — I already have it</button>
          </div>
        </div>
        <div id="ootb-step-4-no-ollama" style="display:none">
          <p class="ootb-sub">You're using a custom API base, so there's no Ollama model to pull here. Make sure that server is running before you start Chump.</p>
          <div class="ootb-actions">
            <button type="button" class="ootb-btn" id="ootb-nonollama-next">Continue</button>
          </div>
        </div>
        <div class="ootb-back-row">
          <button type="button" class="ootb-btn secondary" id="ootb-back-4">Back</button>
        </div>
      </div>

      <div id="ootb-step-5" style="display:none">
        <p class="ootb-sub">Start the Chump engine. We wait for a healthy API before closing this screen — you're almost there.</p>
        <div class="ootb-actions">
          <button type="button" class="ootb-btn" id="ootb-start-chump">Start Chump</button>
          <button type="button" class="ootb-btn secondary" id="ootb-retry-engine" style="display:none">Try again</button>
        </div>
        <div class="ootb-back-row">
          <button type="button" class="ootb-btn secondary" id="ootb-back-5">Back</button>
        </div>
      </div>
    </div>

    <p class="ootb-foot" id="ootb-foot-hint">
      <span><kbd>Tab</kbd> cycles focus · <kbd>Esc</kbd> back · Errors are announced</span>
      <span> · <code>docs/PACKAGED_OOTB_DESKTOP.md</code></span>
    </p>

    <div id="ootb-success-overlay" class="ootb-success-overlay" aria-hidden="true">
      <div class="ootb-success-card" role="status" aria-live="polite">
        <div class="ootb-success-icon" aria-hidden="true">✓</div>
        <p class="ootb-success-title">You're in</p>
        <p class="ootb-success-sub">Cowork is online — you can start chatting.</p>
        <p class="ootb-success-hint">If the engine uses <code>CHUMP_WEB_TOKEN</code>, set the bearer token in Settings (⚙). Try <code>/task …</code> or the Tasks tab for durable work.</p>
      </div>
    </div>
  </div>
`;

const DEFAULT_OLLAMA_BASE = 'http://127.0.0.1:11434/v1';
const STEP_HEADINGS = ['', 'Welcome to Chump', 'Connect your LLM', 'Your data & model', 'Pull the model', 'Start the engine'];

class ChumpOotbWizard extends HTMLElement {
  #shadow = null;
  #step = 1;
  #state = { skipOllamaPath: false, apiBaseSnapshot: '', userDataPath: '' };
  #selectedModel = 'qwen2.5:7b';
  #pullUnlisten = null;
  #pullBuf = [];
  #pullRaf = null;

  connectedCallback() {
    if (!isTauriHost()) return;
    this.#shadow = this.attachShadow({ mode: 'open' });
    this.#shadow.innerHTML = `<style>${WIZARD_CSS}</style>${WIZARD_HTML}`;
    void this.#main();
  }

  #q(id) {
    return this.#shadow.getElementById(id);
  }

  #setShellInert(on) {
    for (const id of ['app-header', 'app-body']) {
      const el = document.getElementById(id);
      try { if (el) el.inert = !!on; } catch (_) {}
    }
  }

  #setWindowTitle(active) {
    const p = tauriInvoke('set_main_window_title', {
      title: active ? 'Chump · First-time setup' : 'Chump · Cowork',
    });
    if (p && p.then) p.catch(() => {});
  }

  #show(el, on) {
    if (!el) return;
    el.classList.toggle('visible', !!on);
    el.setAttribute('aria-hidden', on ? 'false' : 'true');
  }

  #setStatus(msg, tone) {
    const s = this.#q('ootb-status');
    if (!s) return;
    s.textContent = msg || '';
    s.setAttribute('aria-live', tone === 'err' ? 'assertive' : 'polite');
    s.classList.remove('ootb-status--ok', 'ootb-status--err', 'ootb-status--busy');
    if (tone === 'ok') s.classList.add('ootb-status--ok');
    else if (tone === 'err') s.classList.add('ootb-status--err');
    else if (tone === 'busy') s.classList.add('ootb-status--busy');
  }

  #apiBaseTrimmed() {
    const inp = this.#q('ootb-api-base');
    return inp ? inp.value.trim() : '';
  }

  #usesOllamaModelPull(skipOllamaPath, baseInput) {
    if (skipOllamaPath) return false;
    const b = (baseInput || '').trim();
    if (!b) return true;
    const n = b.replace(/\/+$/, '').toLowerCase();
    const d = DEFAULT_OLLAMA_BASE.replace(/\/+$/, '').toLowerCase();
    if (n === d) return true;
    return /:(11434)(\b|\/)/.test(n);
  }

  #updateProgressDots(currentStep) {
    for (let i = 1; i <= 5; i++) {
      const d = this.#shadow.querySelector(`[data-ootb-dot="${i}"]`);
      if (!d) continue;
      d.classList.remove('active', 'done');
      if (i < currentStep) d.classList.add('done');
      else if (i === currentStep) d.classList.add('active');
    }
  }

  #updateStepHeading(n) {
    const h = this.#q('ootb-step-heading');
    if (h && STEP_HEADINGS[n]) h.textContent = STEP_HEADINGS[n];
  }

  #updateRevealRow(n) {
    const row = this.#q('ootb-reveal-row');
    if (!row) return;
    row.style.display = this.#state.userDataPath && n >= 4 && n <= 5 ? 'block' : 'none';
  }

  #setStep(n) {
    for (let i = 1; i <= 5; i++) {
      const p = this.#q(`ootb-step-${i}`);
      if (p) p.style.display = i === n ? 'block' : 'none';
    }
    const hint = this.#q('ootb-step-hint');
    if (hint) hint.textContent = `Step ${n} of 5`;
    this.#updateProgressDots(n);
    this.#updateStepHeading(n);
    this.#updateRevealRow(n);

    if (n === 4) {
      const oll = this.#q('ootb-step-4-ollama');
      const no  = this.#q('ootb-step-4-no-ollama');
      const pull = this.#usesOllamaModelPull(this.#state.skipOllamaPath, this.#state.apiBaseSnapshot);
      if (oll) oll.style.display = pull ? 'block' : 'none';
      if (no)  no.style.display  = pull ? 'none'  : 'block';
      if (pull) {
        const log = this.#q('ootb-pull-log');
        if (log && !log.textContent) log.textContent = '';
      }
    }

    if (n !== 5) {
      const rb = this.#q('ootb-retry-engine');
      if (rb) rb.style.display = 'none';
    }

    if (n === 3) void this.#refreshPathPreview();

    const root = this.#q('ootb-root');
    if (root && root.classList.contains('visible')) this.#focusStepPrimary(n);
  }

  #focusStepPrimary(step) {
    requestAnimationFrame(() => {
      const skipC = this.#q('ootb-skip-confirm');
      if (skipC && skipC.style.display !== 'none') {
        const c = this.#q('ootb-skip-cancel');
        if (c) c.focus();
        return;
      }
      let id = null;
      if (step === 1) id = 'ootb-next-1';
      else if (step === 2) id = 'ootb-next-2';
      else if (step === 3) id = 'ootb-create-config';
      else if (step === 4) {
        id = this.#usesOllamaModelPull(this.#state.skipOllamaPath, this.#state.apiBaseSnapshot)
          ? 'ootb-pull' : 'ootb-nonollama-next';
      } else if (step === 5) {
        const retry = this.#q('ootb-retry-engine');
        id = retry && retry.style.display !== 'none' ? 'ootb-retry-engine' : 'ootb-start-chump';
      }
      const el = id ? this.#q(id) : null;
      if (el && typeof el.focus === 'function') el.focus();
    });
  }

  #getWizardFocusables() {
    const root = this.#shadow;
    if (!root) return [];
    const ov = this.#q('ootb-success-overlay');
    if (ov && ov.classList.contains('visible')) return [];
    const sel = 'a[href]:not([disabled]), button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
    const all = root.querySelectorAll(sel);
    const out = [];
    const skipC = this.#q('ootb-skip-confirm');
    const skipVisible = skipC && skipC.style.display !== 'none';
    for (let i = 0; i < all.length; i++) {
      const el = all[i];
      const st0 = window.getComputedStyle(el);
      if (st0.visibility === 'hidden' || st0.display === 'none') continue;
      if (el.offsetParent === null && st0.position !== 'fixed' && st0.position !== 'sticky') continue;
      const stepHost = el.closest('[id^="ootb-step-"]');
      if (stepHost && stepHost.style.display === 'none') continue;
      if (skipVisible) {
        if (el.closest('#ootb-step-1-main')) continue;
      } else {
        if (el.closest('#ootb-skip-confirm')) continue;
      }
      const rr = this.#q('ootb-reveal-row');
      if (rr && rr.style.display === 'none' && el.id === 'ootb-reveal-folder') continue;
      out.push(el);
    }
    return out;
  }

  #friendlyEngineReason(reason) {
    const fallback = 'The engine did not become ready. If you use a release .app, the chump binary must sit next to the desktop executable inside the bundle.';
    if (!reason) return fallback;
    const r = String(reason);
    if (r.includes('chump_binary_not_found_next_to_desktop')) {
      return 'The Chump engine was not found beside this app. From source: build both chump and chump-desktop; for a .app, run scripts/setup/macos-cowork-dock-app.sh so chump is copied into Contents/MacOS/.';
    }
    if (r.includes('spawn_failed')) {
      return 'Could not start the engine: ' + r.replace(/^spawn_failed:\s*/i, '');
    }
    if (r.includes('health_still_unreachable_after_wait')) {
      return 'The process started but /api/health did not respond in time. Check nothing else uses the same port, then try again.';
    }
    return r;
  }

  #friendlyPullError(msg) {
    const s = String(msg);
    if (/spawn ollama/i.test(s) || /No such file|ENOENT/i.test(s)) {
      return 'Could not run ollama — install it and ensure it is on your PATH, then try again.';
    }
    return s;
  }

  async #refreshPathPreview() {
    const el = this.#q('ootb-path-preview');
    if (!el) return;
    try {
      const p = await tauriInvoke('ootb_user_data_dir_path');
      if (p) el.textContent = 'Config and chats will live under: ' + p;
    } catch (_) {
      el.textContent = '';
    }
  }

  async #waitForIpc() {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      const p = tauriInvoke('ootb_wizard_should_show');
      if (p && typeof p.then === 'function') return true;
      await new Promise((r) => setTimeout(r, 40));
    }
    return false;
  }

  async #subscribePullLog(onLine) {
    const listen = getTauriListen();
    if (!listen) return;
    try {
      this.#pullUnlisten = await listen('ootb-pull-line', (e) => {
        const payload = e && e.payload;
        const line = payload && typeof payload === 'object' && payload.line != null
          ? String(payload.line)
          : payload != null ? String(payload) : '';
        if (line) onLine(line);
      });
    } catch (_) {
      this.#pullUnlisten = null;
    }
  }

  #unsubscribePullLog() {
    if (typeof this.#pullUnlisten === 'function') {
      try { this.#pullUnlisten(); } catch (_) {}
    }
    this.#pullUnlisten = null;
  }

  #flushPullBuf() {
    this.#pullRaf = null;
    const log = this.#q('ootb-pull-log');
    if (!log || this.#pullBuf.length === 0) return;
    const chunk = this.#pullBuf.join('\n');
    this.#pullBuf = [];
    let t = log.textContent;
    if (t.length > 24000) t = t.slice(-20000);
    log.textContent = t ? t + '\n' + chunk : chunk;
    log.scrollTop = log.scrollHeight;
  }

  #appendPullLog(line) {
    this.#pullBuf.push(line);
    if (!this.#pullRaf) this.#pullRaf = requestAnimationFrame(() => this.#flushPullBuf());
  }

  #clearPullLog() {
    this.#pullBuf = [];
    if (this.#pullRaf) { cancelAnimationFrame(this.#pullRaf); this.#pullRaf = null; }
    const log = this.#q('ootb-pull-log');
    if (log) log.textContent = '';
  }

  async #main() {
    if (localStorage.getItem('chump_ootb_dismissed') === '1') return;
    const ready = await this.#waitForIpc();
    if (!ready) return;
    let should;
    try {
      should = await tauriInvoke('ootb_wizard_should_show');
    } catch (_) { return; }
    if (!should) return;

    const root = this.#q('ootb-root');
    if (!root) return;
    this.#show(root, true);
    this.#setShellInert(true);
    this.#setWindowTitle(true);

    this.#step = 1;
    this.#setStep(this.#step);

    try {
      const d = await tauriInvoke('ootb_default_model');
      if (d && typeof d === 'string') this.#selectedModel = d;
    } catch (_) {}

    const sel = this.#q('ootb-model-select');
    if (sel) {
      sel.value = this.#selectedModel;
      sel.addEventListener('change', () => { this.#selectedModel = sel.value; });
    }

    const showSkipConfirm = (show) => {
      const main = this.#q('ootb-step-1-main');
      const conf = this.#q('ootb-skip-confirm');
      if (main) main.style.display = show ? 'none' : 'block';
      if (conf) conf.style.display = show ? 'block' : 'none';
      if (show) { const c = this.#q('ootb-skip-cancel'); if (c) c.focus(); }
      else this.#focusStepPrimary(1);
    };

    root.addEventListener('keydown', (ev) => {
      if (ev.key === 'Tab' && root.classList.contains('visible')) {
        const ov = this.#q('ootb-success-overlay');
        if (ov && ov.classList.contains('visible')) return;
        const list = this.#getWizardFocusables();
        if (list.length === 0) return;
        const first = list[0], last = list[list.length - 1];
        if (ev.shiftKey) {
          if (this.#shadow.activeElement === first) { ev.preventDefault(); last.focus(); }
        } else {
          if (this.#shadow.activeElement === last) { ev.preventDefault(); first.focus(); }
        }
      }
      if (ev.key !== 'Escape' || ev.defaultPrevented) return;
      const conf = this.#q('ootb-skip-confirm');
      if (conf && conf.style.display !== 'none') { ev.preventDefault(); showSkipConfirm(false); return; }
      if (this.#step <= 1) return;
      ev.preventDefault();
      if (this.#step === 2) this.#q('ootb-back-2')?.click();
      else if (this.#step === 3) this.#q('ootb-back-3')?.click();
      else if (this.#step === 4) this.#q('ootb-back-4')?.click();
      else if (this.#step === 5) this.#q('ootb-back-5')?.click();
    }, true);

    this.#q('ootb-reveal-folder')?.addEventListener('click', () => {
      const p = tauriInvoke('ootb_reveal_user_data_folder');
      if (p && p.then) p.catch((e) => this.#setStatus(String(e), 'err'));
    });

    this.#q('ootb-copy-pull-log')?.addEventListener('click', () => {
      const log = this.#q('ootb-pull-log');
      if (!log || !log.textContent) { this.#setStatus('Nothing to copy yet.', 'busy'); return; }
      navigator.clipboard.writeText(log.textContent).then(
        () => this.#setStatus('Log copied to clipboard.', 'ok'),
        () => this.#setStatus('Could not copy — select the log and copy manually.', 'err')
      );
    });

    this.#q('ootb-next-1')?.addEventListener('click', () => {
      this.#step = 2; this.#setStep(this.#step); void this.#refreshOllama();
    });

    this.#q('ootb-check-ollama')?.addEventListener('click', () => { void this.#refreshOllama(); });

    this.#q('ootb-open-download')?.addEventListener('click', () => {
      const p = tauriInvoke('ootb_open_ollama_download');
      if (p && p.then) p.catch(() => {});
    });

    this.#q('ootb-skip-wizard')?.addEventListener('click', () => showSkipConfirm(true));
    this.#q('ootb-skip-cancel')?.addEventListener('click', () => showSkipConfirm(false));

    this.#q('ootb-skip-confirm-btn')?.addEventListener('click', () => {
      localStorage.setItem('chump_ootb_dismissed', '1');
      this.#setShellInert(false);
      this.#setWindowTitle(false);
      this.#show(root, false);
      window.dispatchEvent(new Event('chump-ootb-finished'));
      setTimeout(() => window.dispatchEvent(new Event('chump-api-root-ready')), 100);
    });

    this.#q('ootb-skip-ollama-path')?.addEventListener('click', () => {
      this.#state.skipOllamaPath = true;
      this.#step = 3; this.#setStep(this.#step);
      this.#setStatus('Open "Advanced" and paste your API base URL, then create config.', 'busy');
    });

    this.#q('ootb-next-2')?.addEventListener('click', async () => {
      try {
        const j = await tauriInvoke('ootb_detect_ollama');
        if (!j || !j.installed) {
          this.#setStatus('Install Ollama first, or use "LM Studio / MLX…" if you are not using Ollama.', 'err');
          return;
        }
      } catch (e) { this.#setStatus(String(e), 'err'); return; }
      this.#state.skipOllamaPath = false;
      this.#step = 3; this.#setStep(this.#step); this.#setStatus('');
    });

    this.#q('ootb-back-2')?.addEventListener('click', () => {
      this.#step = 1; this.#state.skipOllamaPath = false;
      this.#setStep(this.#step); this.#setStatus('');
    });

    this.#q('ootb-create-config')?.addEventListener('click', async () => {
      const baseInput = this.#apiBaseTrimmed();
      if (this.#state.skipOllamaPath && !baseInput) {
        this.#setStatus('Enter your API base URL under Advanced (or go back and use the Ollama path).', 'err');
        const det = this.#q('ootb-advanced-details');
        if (det) det.open = true;
        this.#q('ootb-api-base')?.focus();
        return;
      }
      this.#setStatus('Writing your config…', 'busy');
      try {
        const payload = { model: this.#selectedModel };
        if (baseInput) payload.openaiApiBase = baseInput;
        const path = await tauriInvoke('ootb_prepare_user_data', payload);
        this.#state.apiBaseSnapshot = baseInput;
        this.#state.userDataPath = path;
        this.#setStatus('Saved — ' + path, 'ok');
        this.#step = 4; this.#setStep(this.#step);
      } catch (e) { this.#setStatus(String(e), 'err'); }
    });

    this.#q('ootb-back-3')?.addEventListener('click', () => {
      this.#step = 2; this.#setStep(this.#step); this.#setStatus('');
      void this.#refreshOllama();
    });

    this.#q('ootb-pull')?.addEventListener('click', async () => {
      this.#clearPullLog();
      this.#setStatus('Downloading — output streams below. Large models can take several minutes.', 'busy');
      const btn = this.#q('ootb-pull');
      if (btn) btn.disabled = true;
      await this.#subscribePullLog((line) => this.#appendPullLog(line));
      try {
        const summary = await tauriInvoke('ootb_pull_model', { model: this.#selectedModel });
        if (summary) this.#appendPullLog(typeof summary === 'string' ? summary : String(summary));
        this.#flushPullBuf();
        const okModel = await tauriInvoke('ootb_model_present', { model: this.#selectedModel });
        if (okModel) this.#setStatus('Model is ready in Ollama. Continue when you are.', 'ok');
        else this.#setStatus('Pull finished — if chat fails, run ollama list and check the tag matches.', 'busy');
        this.#step = 5; this.#setStep(this.#step);
      } catch (e) {
        this.#setStatus(this.#friendlyPullError(e), 'err');
      } finally {
        this.#unsubscribePullLog();
        if (btn) btn.disabled = false;
      }
    });

    this.#q('ootb-skip-pull')?.addEventListener('click', () => {
      this.#setStatus('Skipped download — ensure this exact model tag exists in Ollama before chatting.', 'busy');
      this.#step = 5; this.#setStep(this.#step);
    });

    this.#q('ootb-nonollama-next')?.addEventListener('click', () => {
      this.#step = 5; this.#setStep(this.#step); this.#setStatus('');
    });

    this.#q('ootb-back-4')?.addEventListener('click', () => {
      this.#step = 3; this.#setStep(this.#step); this.#setStatus('');
    });

    this.#q('ootb-start-chump')?.addEventListener('click', () => { void this.#tryStartEngine(); });
    this.#q('ootb-retry-engine')?.addEventListener('click', () => { void this.#tryStartEngine(); });

    this.#q('ootb-back-5')?.addEventListener('click', () => {
      this.#step = 4; this.#setStep(this.#step); this.#setStatus('');
    });

    void this.#refreshOllama();
  }

  async #refreshOllama() {
    this.#setStatus('Checking Ollama…', 'busy');
    try {
      const j = await tauriInvoke('ootb_detect_ollama');
      if (j && j.installed) {
        this.#setStatus('Ollama is ready — ' + (j.version || 'installed').replace(/\s+/g, ' ').trim(), 'ok');
      } else {
        this.#setStatus(
          'Ollama was not found on PATH. Use "Open Ollama download", or choose "LM Studio / MLX…" if you use another server.',
          'err'
        );
      }
    } catch (e) { this.#setStatus(String(e), 'err'); }
  }

  #finishWizardSuccess() {
    const ov = this.#q('ootb-success-overlay');
    let reduced = false;
    try { reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (_) {}
    if (ov) { ov.classList.add('visible'); ov.setAttribute('aria-hidden', 'false'); }
    const delay = reduced ? 280 : 920;
    const root = this.#q('ootb-root');
    window.setTimeout(() => {
      localStorage.setItem('chump_ootb_complete', '1');
      localStorage.removeItem('chump_ootb_dismissed');
      if (ov) { ov.classList.remove('visible'); ov.setAttribute('aria-hidden', 'true'); }
      if (root) { this.#show(root, false); }
      this.#setShellInert(false);
      this.#setWindowTitle(false);
      window.dispatchEvent(new Event('chump-ootb-finished'));
      window.setTimeout(() => window.dispatchEvent(new Event('chump-api-root-ready')), 80);
      this.#setStatus('');
    }, delay);
  }

  async #tryStartEngine() {
    this.#setStatus('Starting Chump and waiting for /api/health…', 'busy');
    const btn = this.#q('ootb-start-chump');
    const retry = this.#q('ootb-retry-engine');
    if (btn) btn.disabled = true;
    if (retry) retry.style.display = 'none';
    let succeeded = false;
    try {
      const inv = tauriInvoke('try_bring_sidecar_online', { force: true });
      const res = inv && inv.then ? await inv : null;
      if (res && res.ok === true && res.health === true) {
        succeeded = true;
        this.#finishWizardSuccess();
      } else {
        const reason = this.#friendlyEngineReason(res && res.reason);
        this.#setStatus(reason, 'err');
        if (retry) { retry.style.display = 'inline-block'; retry.focus(); }
      }
    } catch (err) {
      this.#setStatus(String(err), 'err');
      if (retry) { retry.style.display = 'inline-block'; retry.focus(); }
    } finally {
      if (btn && !succeeded) btn.disabled = false;
    }
  }
}

customElements.define('chump-ootb-wizard', ChumpOotbWizard);
