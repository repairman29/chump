// Chump v2 — first-run welcome modal (PRODUCT-082).
//
// Activates when localStorage.chump_first_visit is unset, OR when the
// query param ?welcome=force is present.
//
// localStorage keys:
//   chump_first_visit          — set to "seen" on first display; presence suppresses future shows
//   chump_first_visit_completed — set to "1" on finish OR skip

const FIRST_VISIT_KEY = 'chump_first_visit';
const COMPLETED_KEY   = 'chump_first_visit_completed';

function shouldShowWelcome() {
  const params = new URLSearchParams(location.search);
  if (params.get('welcome') === 'force') return true;
  return !localStorage.getItem(FIRST_VISIT_KEY);
}

class ChumpWelcome extends HTMLElement {
  #shadow = null;
  #step = 1;
  #claimedGapId = null;

  connectedCallback() {
    if (!shouldShowWelcome()) return;
    localStorage.setItem(FIRST_VISIT_KEY, 'seen');

    this.#shadow = this.attachShadow({ mode: 'open' });
    this.#shadow.innerHTML = this.#css() + this.#html();
    this.#bindEvents();
    this.#loadPickableGaps();
    this.#detectRepo();
  }

  // ── layout ─────────────────────────────────────────────────────────────────

  #css() {
    return `<style>
:host { display: contents; }
.overlay {
  position: fixed; inset: 0;
  background: rgba(0,0,0,.55);
  z-index: 9000;
  display: flex; align-items: center; justify-content: center;
}
.modal {
  background: var(--bg-primary, #1e1e2e);
  border: 1px solid var(--border-color, #3a3a5c);
  border-radius: 12px;
  padding: 32px;
  max-width: 560px; width: 94vw;
  max-height: 85vh; overflow-y: auto;
  color: var(--text-primary, #e0e0f0);
  font-family: system-ui, sans-serif;
  box-shadow: 0 16px 64px rgba(0,0,0,.6);
}
h2 { margin: 0 0 8px; font-size: 1.4rem; }
.subtitle { color: var(--text-secondary, #999); margin: 0 0 24px; font-size: .9rem; }
.steps { display: flex; gap: 8px; margin-bottom: 24px; }
.step-dot {
  flex: 1; height: 4px; border-radius: 2px;
  background: var(--border-color, #3a3a5c);
  transition: background .3s;
}
.step-dot.active, .step-dot.done { background: var(--accent, #7c83fd); }
.step-content { min-height: 140px; }
.step-panel { display: none; }
.step-panel.visible { display: block; }
p { margin: 0 0 12px; font-size: .9rem; line-height: 1.5; }
a { color: var(--accent, #7c83fd); }
.repo-row { display: flex; gap: 8px; align-items: center; margin-bottom: 12px; }
input[type=text] {
  flex: 1; padding: 8px 10px; border-radius: 6px;
  border: 1px solid var(--border-color, #3a3a5c);
  background: var(--bg-secondary, #2a2a3e); color: var(--text-primary, #e0e0f0);
  font-size: .88rem;
}
.gap-list { list-style: none; padding: 0; margin: 0 0 12px; }
.gap-item {
  padding: 10px 12px; border: 1px solid var(--border-color, #3a3a5c);
  border-radius: 6px; margin-bottom: 6px; cursor: pointer;
  transition: border-color .2s;
}
.gap-item:hover { border-color: var(--accent, #7c83fd); }
.gap-item.claimed { border-color: #4caf50; opacity: .7; pointer-events: none; }
.gap-id { font-size: .8rem; opacity: .7; margin-bottom: 2px; }
.gap-title { font-size: .88rem; }
.footer { display: flex; justify-content: space-between; align-items: center; margin-top: 24px; }
button {
  padding: 9px 18px; border-radius: 6px; border: none; cursor: pointer;
  font-size: .88rem; font-weight: 500;
}
.btn-primary { background: var(--accent, #7c83fd); color: #fff; }
.btn-primary:disabled { opacity: .5; cursor: not-allowed; }
.btn-ghost {
  background: transparent; color: var(--text-secondary, #999);
  border: 1px solid var(--border-color, #3a3a5c);
}
.status-msg { font-size: .8rem; color: var(--text-secondary, #999); }
</style>`;
  }

  #html() {
    return `
<div class="overlay" id="overlay">
  <div class="modal" role="dialog" aria-modal="true" aria-labelledby="welcome-title">
    <h2 id="welcome-title">Welcome to Chump</h2>
    <p class="subtitle">Coordination platform for solo devs — not a chat bot.</p>

    <div class="steps">
      <div class="step-dot active" id="dot-1"></div>
      <div class="step-dot" id="dot-2"></div>
      <div class="step-dot" id="dot-3"></div>
    </div>

    <div class="step-content">
      <!-- Step 1: What is Chump + set repo -->
      <div class="step-panel visible" id="step-1">
        <p>Chump routes a <em>gap queue</em> — discrete, atomic work items — to autonomous Claude
        agents that claim, implement, and ship them as GitHub PRs while you sleep.</p>
        <p>Step 1: confirm where your repo lives.</p>
        <div class="repo-row">
          <input type="text" id="repo-input" placeholder="Detecting…" aria-label="Repo path" />
          <button class="btn-ghost" id="repo-set-btn">Set</button>
        </div>
        <p style="font-size:.8rem;color:var(--text-secondary,#999)">
          Sourced from <code>CHUMP_REPO</code> env var, or the server's working directory.
        </p>
        <p style="font-size:.8rem">
          New to Chump? Read the <a href="/docs/process/CHUMP_FIRST_DOCTRINE.md" target="_blank">First Doctrine</a>.
        </p>
      </div>

      <!-- Step 2: pick a gap -->
      <div class="step-panel" id="step-2">
        <p>Pick one gap to start. Chump will claim it and dispatch an agent.</p>
        <ul class="gap-list" id="gap-list"><li><span class="status-msg">Loading gaps…</span></li></ul>
        <p id="gap-status" class="status-msg"></p>
      </div>

      <!-- Step 3: watch it ship -->
      <div class="step-panel" id="step-3">
        <p>Your gap is claimed. The agent is running.</p>
        <p>The <strong>Agents</strong> view shows real-time progress — tool calls, commits, and the PR link once it ships.</p>
        <p id="claimed-gap-note" class="status-msg"></p>
      </div>
    </div>

    <div class="footer">
      <button class="btn-ghost" id="skip-btn">I've used Chump before</button>
      <button class="btn-primary" id="next-btn">Next →</button>
    </div>
  </div>
</div>`;
  }

  // ── events ──────────────────────────────────────────────────────────────────

  #bindEvents() {
    const sh = this.#shadow;
    sh.getElementById('skip-btn').addEventListener('click', () => this.#finish());
    sh.getElementById('next-btn').addEventListener('click', () => this.#advance());
    sh.getElementById('repo-set-btn').addEventListener('click', () => this.#setRepo());
    sh.getElementById('overlay').addEventListener('click', (e) => {
      if (e.target === sh.getElementById('overlay')) this.#finish();
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') this.#finish();
    }, { once: true });
  }

  // ── step navigation ─────────────────────────────────────────────────────────

  #advance() {
    if (this.#step === 3) { this.#finish(); return; }
    this.#shadow.getElementById(`step-${this.#step}`).classList.remove('visible');
    this.#shadow.getElementById(`dot-${this.#step}`).classList.replace('active', 'done');
    this.#step++;
    this.#shadow.getElementById(`step-${this.#step}`).classList.add('visible');
    this.#shadow.getElementById(`dot-${this.#step}`).classList.add('active');

    const nextBtn = this.#shadow.getElementById('next-btn');
    if (this.#step === 2) {
      nextBtn.textContent = 'Skip to agents board';
    } else if (this.#step === 3) {
      nextBtn.textContent = 'Open agents board →';
    }
  }

  #finish() {
    localStorage.setItem(COMPLETED_KEY, '1');
    const overlay = this.#shadow.getElementById('overlay');
    if (overlay) overlay.remove();
    if (this.#step === 3 || this.#claimedGapId) {
      // Navigate to agents view.
      window.dispatchEvent(new CustomEvent('chump:nav', { detail: { view: 'agents' } }));
    }
  }

  // ── repo detection ──────────────────────────────────────────────────────────

  #detectRepo() {
    fetch('/api/health')
      .then((r) => r.json())
      .then((d) => {
        const repo = d.repo_root ?? d.repo ?? '';
        if (repo) {
          const inp = this.#shadow.getElementById('repo-input');
          if (inp) inp.value = repo;
        }
      })
      .catch(() => {});
  }

  #setRepo() {
    const inp = this.#shadow.getElementById('repo-input');
    const val = (inp?.value ?? '').trim();
    if (!val) return;
    fetch('/api/settings/repo', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ repo_root: val }),
    }).catch(() => {});
  }

  // ── gap loading + claiming ──────────────────────────────────────────────────

  #loadPickableGaps() {
    fetch('/api/gap-queue?status=open&limit=8')
      .then((r) => r.json())
      .then((data) => {
        const gaps = (Array.isArray(data) ? data : data.items ?? [])
          .filter((g) => g.acceptance_criteria && g.effort && ['xs', 's'].includes(g.effort))
          .slice(0, 3);
        this.#renderGaps(gaps);
      })
      .catch(() => {
        const list = this.#shadow.getElementById('gap-list');
        if (list) list.innerHTML = '<li><span class="status-msg">Could not load gaps (server offline?).</span></li>';
      });
  }

  #renderGaps(gaps) {
    const list = this.#shadow.getElementById('gap-list');
    if (!list) return;
    if (gaps.length === 0) {
      list.innerHTML = '<li><span class="status-msg">No pickable gaps found — check the Gaps view to add some.</span></li>';
      return;
    }
    list.innerHTML = gaps.map((g) => `
      <li class="gap-item" data-id="${g.id}" tabindex="0" role="button" aria-label="Claim ${g.id}">
        <div class="gap-id">${g.id} · ${g.priority ?? ''} · ${g.effort ?? ''}</div>
        <div class="gap-title">${g.title ?? ''}</div>
      </li>
    `).join('');
    list.querySelectorAll('.gap-item').forEach((el) => {
      el.addEventListener('click', () => this.#claimGap(el.dataset.id, el));
      el.addEventListener('keydown', (e) => { if (e.key === 'Enter') this.#claimGap(el.dataset.id, el); });
    });
  }

  #claimGap(gapId, el) {
    const status = this.#shadow.getElementById('gap-status');
    if (status) status.textContent = `Claiming ${gapId}…`;
    el.classList.add('claimed');
    fetch(`/api/gap/${gapId}/claim`, { method: 'POST' })
      .then((r) => r.json())
      .then(() => {
        this.#claimedGapId = gapId;
        if (status) status.textContent = `${gapId} claimed — moving to step 3.`;
        const note = this.#shadow.getElementById('claimed-gap-note');
        if (note) note.textContent = `Claimed: ${gapId}`;
        setTimeout(() => this.#advance(), 800);
      })
      .catch(() => {
        el.classList.remove('claimed');
        if (status) status.textContent = 'Claim failed — you can claim manually from the Gaps view.';
      });
  }
}

customElements.define('chump-welcome', ChumpWelcome);
