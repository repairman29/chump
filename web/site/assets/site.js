/* ==========================================================================
   Chump Product Suite — Shared Web Components, Live Daemon Hydrator & Canvas
   Zero external runtime dependencies. Strict CSS token discipline (0 literals).
   ========================================================================== */

(function () {
  const THEME_KEY = "chump_site_theme";
  let probed = false;
  let daemonHealth = null;

  function applySavedTheme() {
    try {
      const saved = localStorage.getItem(THEME_KEY);
      if (saved === "dark" || saved === "light") {
        if (saved === "dark") {
          document.documentElement.setAttribute("data-theme", "dark");
        } else {
          document.documentElement.removeAttribute("data-theme");
        }
      }
    } catch (_) {
      /* storage unavailable in sandboxed context */
    }
  }

  applySavedTheme();

  function currentTheme() {
    return document.documentElement.getAttribute("data-theme") === "dark" ? "dark" : "light";
  }

  function toggleTheme() {
    const next = currentTheme() === "dark" ? "light" : "dark";
    if (next === "dark") {
      document.documentElement.setAttribute("data-theme", "dark");
    } else {
      document.documentElement.removeAttribute("data-theme");
    }
    try {
      localStorage.setItem(THEME_KEY, next);
    } catch (_) {}
    document.querySelectorAll("[data-theme-label]").forEach((el) => {
      el.textContent = next === "dark" ? "Theme: Stone" : "Theme: Charcoal";
    });
    window.dispatchEvent(new CustomEvent("chump-theme-change", { detail: { theme: next } }));
  }

  function normalizeBase(raw) {
    const trimmed = (raw || ".").trim();
    if (!trimmed || trimmed === ".") return ".";
    return trimmed.replace(/\/+$/, "");
  }

  function copyText(text, btnEl) {
    try {
      if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
        navigator.clipboard.writeText(text).catch(() => {});
      } else {
        const ta = document.createElement("textarea");
        ta.value = text;
        document.body.appendChild(ta);
        ta.select();
        try {
          document.execCommand("copy");
        } catch (_) {}
        ta.remove();
      }
    } catch (_) {}
    if (btnEl) {
      if (!btnEl.dataset.origLabel) {
        btnEl.dataset.origLabel = btnEl.textContent;
      }
      btnEl.textContent = "Copied ✓";
      btnEl.setAttribute("data-copied", "true");
      clearTimeout(btnEl._copyTimer);
      btnEl._copyTimer = setTimeout(() => {
        btnEl.textContent = btnEl.dataset.origLabel || "Copy";
        btnEl.removeAttribute("data-copied");
      }, 1800);
    }
  }

  window.ChumpSite = {
    copyText,
    toggleTheme,
    openInstallModal() {
      const modal = document.querySelector("chump-install-modal .modal-backdrop");
      if (modal) modal.setAttribute("data-open", "true");
    },
    closeInstallModal() {
      const modal = document.querySelector("chump-install-modal .modal-backdrop");
      if (modal) modal.setAttribute("data-open", "false");
    },
    token(name) {
      return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    },
  };

  /* ── <chump-site-header> ───────────────────────────────────────────────── */

  class ChumpSiteHeader extends HTMLElement {
    connectedCallback() {
      const pillar = this.getAttribute("pillar") || "overview";
      const page = this.getAttribute("page") || "overview";
      const prefix = normalizeBase(this.getAttribute("base"));
      const themeText = currentTheme() === "dark" ? "Theme: Stone" : "Theme: Charcoal";

      this.innerHTML = `
        <header class="site-header-wrap">
          <div class="utility-bar">
            <div class="utility-inner">
              <nav class="pillar-tabs" aria-label="Chump product suites">
                <a class="pillar-tab" href="${prefix}/" aria-current="${pillar === "overview" ? "true" : "false"}">Overview</a>
                <a class="pillar-tab" href="${prefix}/fleet/" aria-current="${pillar === "fleet" ? "true" : "false"}">File Leases &amp; Fleet</a>
                <a class="pillar-tab" href="${prefix}/cascade/" aria-current="${pillar === "cascade" ? "true" : "false"}">Model Failover</a>
                <a class="pillar-tab" href="${prefix}/tools/fleet-simulator/" aria-current="${pillar === "tools" ? "true" : "false"}">Free Tools</a>
                <a class="pillar-tab" href="${prefix}/docs/">Docs</a>
              </nav>
              <div class="utility-right">
                <span class="live-daemon-pill" data-live="false" data-daemon-badge>
                  <span class="live-daemon-dot"></span>
                  <span data-daemon-text>Open-Source Rust v1.0 · Self-host in 60s</span>
                </span>
                <button type="button" class="theme-btn" data-theme-toggle data-theme-label aria-label="Toggle color theme">${themeText}</button>
              </div>
            </div>
          </div>
          <div class="nav-bar">
            <a class="brand-mark" href="${prefix}/">
              <span class="brand-glyph" aria-hidden="true"></span>
              <span>Chump</span>
            </a>
            <nav class="nav-links" aria-label="Primary navigation">
              <a class="nav-link" href="${prefix}/fleet/" ${page === "fleet" ? 'aria-current="page"' : ""}>Fleet Coordinator</a>
              <a class="nav-link" href="${prefix}/cascade/" ${page === "cascade" ? 'aria-current="page"' : ""}>Model Cascade</a>
              <a class="nav-link" href="${prefix}/tools/fleet-simulator/" ${page === "simulator" ? 'aria-current="page"' : ""}>
                <span>Fleet Simulator</span>
                <span class="nav-badge">Tool</span>
              </a>
              <a class="nav-link" href="${prefix}/tools/config-doctor/" ${page === "doctor" ? 'aria-current="page"' : ""}>
                <span>Config Doctor</span>
                <span class="nav-badge">Tool</span>
              </a>
              <a class="nav-link" href="${prefix}/pricing/" ${page === "pricing" ? 'aria-current="page"' : ""}>Pricing &amp; TCO</a>
              <a class="nav-link" href="${prefix}/docs/">Docs</a>
            </nav>
            <div class="nav-actions">
              <a class="btn btn-stone btn-sm" href="https://github.com/repairman29/chump" target="_blank" rel="noopener" data-cockpit-cta>GitHub ↗</a>
              <button type="button" class="btn btn-dark btn-sm" data-open-install>Quick Install</button>
              <button type="button" class="mobile-menu-btn" data-mobile-toggle aria-expanded="false" aria-label="Toggle navigation menu">Menu ☰</button>
            </div>
          </div>
          <nav class="mobile-nav-drawer" data-open="false" aria-label="Mobile navigation">
            <a href="${prefix}/">Product Overview</a>
            <a href="${prefix}/fleet/">Fleet Coordinator &amp; Leases</a>
            <a href="${prefix}/cascade/">Model Cascade &amp; Failover</a>
            <a href="${prefix}/tools/fleet-simulator/">Fleet Simulator (Tool)</a>
            <a href="${prefix}/tools/config-doctor/">Config Doctor (Tool)</a>
            <a href="${prefix}/pricing/">Pricing &amp; TCO Calculator</a>
            <a href="${prefix}/docs/">Operator Documentation</a>
            <a href="https://github.com/repairman29/chump" target="_blank" rel="noopener" data-cockpit-cta>GitHub Source ↗</a>
          </nav>
        </header>
      `;

      const toggleBtn = this.querySelector("[data-theme-toggle]");
      if (toggleBtn) toggleBtn.addEventListener("click", toggleTheme);

      const installBtn = this.querySelector("[data-open-install]");
      if (installBtn) {
        installBtn.addEventListener("click", () => window.ChumpSite.openInstallModal());
      }

      const mobileBtn = this.querySelector("[data-mobile-toggle]");
      const drawer = this.querySelector(".mobile-nav-drawer");
      if (mobileBtn && drawer) {
        mobileBtn.addEventListener("click", () => {
          const nextOpen = drawer.getAttribute("data-open") !== "true";
          drawer.setAttribute("data-open", nextOpen ? "true" : "false");
          mobileBtn.setAttribute("aria-expanded", nextOpen ? "true" : "false");
          mobileBtn.textContent = nextOpen ? "Close ✕" : "Menu ☰";
        });
      }

      if (daemonHealth) {
        applyDaemonOnline(daemonHealth);
      } else {
        probeLocalDaemon();
      }
    }
  }

  /* ── <chump-site-footer> ───────────────────────────────────────────────── */

  class ChumpSiteFooter extends HTMLElement {
    connectedCallback() {
      const prefix = normalizeBase(this.getAttribute("base"));
      this.innerHTML = `
        <footer class="site-footer">
          <div class="shell">
            <div class="footer-grid">
              <div class="footer-col">
                <div class="brand-mark" style="margin-bottom:12px;">
                  <span class="brand-glyph" aria-hidden="true"></span>
                  <span>Chump</span>
                </div>
                <p style="font-size:13.5px; color:var(--stone-on-dark-muted); margin:0 0 16px; max-width:28ch;">
                  Local-first Rust coordinator, pre-commit file-lease firewall, and 40-slot model failover router for parallel coding agents.
                </p>
                <div class="mono" style="font-size:11.5px; color:var(--stone-bronze-bright);" data-footer-version>
                  Runtime v1.0.0 · Universal (macOS · Linux · Windows)
                </div>
              </div>
              <div class="footer-col">
                <h4>Chump Fleet</h4>
                <ul>
                  <li><a href="${prefix}/fleet/">Coordinator Overview</a></li>
                  <li><a href="${prefix}/fleet/#firewall-sandbox">Pre-Commit Lease Firewall</a></li>
                  <li><a href="${prefix}/fleet/#lineage-explorer">5-Stage Task Pipeline</a></li>
                  <li><a href="${prefix}/fleet/#gate-guard">Workflow Auto-Merge Guard</a></li>
                  <li><a href="${prefix}/docs/" data-cockpit-cta>Operator Documentation →</a></li>
                </ul>
              </div>
              <div class="footer-col">
                <h4>Chump Cascade</h4>
                <ul>
                  <li><a href="${prefix}/cascade/">40-Slot Failover Router</a></li>
                  <li><a href="${prefix}/cascade/#bandit-lab">Live HTTP 429 Failover Lab</a></li>
                  <li><a href="${prefix}/cascade/#daemon-builder">3-OS Service &amp; TOML Builder</a></li>
                  <li><a href="${prefix}/cascade/#byo-harnesses">Claude / Codex / OpenCode / Aider</a></li>
                </ul>
              </div>
              <div class="footer-col">
                <h4>Interactive Tools</h4>
                <ul>
                  <li><a href="${prefix}/tools/fleet-simulator/">Fleet Throughput &amp; Cost Simulator</a></li>
                  <li><a href="${prefix}/tools/config-doctor/">Config &amp; Failover Doctor</a></li>
                  <li><a href="${prefix}/#intent-router">CLI Task Router</a></li>
                  <li><a href="${prefix}/pricing/#tco-comparator">Cloud-Agent TCO Calculator</a></li>
                </ul>
              </div>
              <div class="footer-col">
                <h4>Open Core &amp; Source</h4>
                <ul>
                  <li><a href="${prefix}/pricing/">Pricing &amp; Licensing</a></li>
                  <li><a href="${prefix}/docs/">Documentation Hub</a></li>
                  <li><a href="https://github.com/repairman29/chump" target="_blank" rel="noopener">GitHub (repairman29/chump) ↗</a></li>
                  <li><a href="https://crates.io/search?q=chump" target="_blank" rel="noopener">Apache-2.0 Crates on crates.io ↗</a></li>
                </ul>
              </div>
            </div>
            <div class="footer-trust-bar">
              <div class="trust-badges">
                <span class="trust-badge">AGPL-3.0 Coordinator</span>
                <span class="trust-badge">13 Apache-2.0 Workspace Crates</span>
                <span class="trust-badge">macOS · Linux · Windows</span>
                <span class="trust-badge">Zero Cloud Telemetry</span>
                <span class="trust-badge">Offline Ready (Ollama / vLLM)</span>
              </div>
              <div>Built in Rust · Runs on hardware you own</div>
            </div>
          </div>
        </footer>
      `;
      if (daemonHealth) applyDaemonOnline(daemonHealth);
    }
  }

  /* ── <chump-install-modal> ─────────────────────────────────────────────── */

  class ChumpInstallModal extends HTMLElement {
    connectedCallback() {
      const prefix = normalizeBase(this.getAttribute("base"));
      const commands = {
        brew: "brew tap repairman29/chump && brew install chump && chump config init",
        linux: "curl --proto '=https' --tlsv1.2 -LsSf https://github.com/repairman29/chump/releases/latest/download/chump-installer.sh | sh",
        windows: "cargo install --git https://github.com/repairman29/chump chump --locked",
        cargo: "cargo install --git https://github.com/repairman29/chump chump --locked",
      };

      this.innerHTML = `
        <div class="modal-backdrop" data-open="false" role="dialog" aria-modal="true" aria-labelledby="install-modal-title">
          <div class="modal-card">
            <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:10px;">
              <span class="eyebrow" style="margin:0;"><span class="eyebrow-dot"></span>60-Second Local Setup</span>
              <button type="button" class="copy-chip" data-close-modal>ESC ✕</button>
            </div>
            <h3 id="install-modal-title" class="display-h3" style="margin-bottom:8px;">Install Chump on your machine</h3>
            <p style="font-size:14px; color:var(--stone-muted); margin:0 0 18px;">
              No account signup, no seat fee, and no proxy middleman around your keys. Works immediately with Claude Code, Codex CLI, OpenCode, Aider, or local Ollama.
            </p>
            <div class="install-box" style="max-width:none; margin-bottom:18px;">
              <div class="install-tabs" role="tablist">
                <button type="button" class="install-tab" role="tab" data-os="brew" aria-selected="true">macOS (Homebrew)</button>
                <button type="button" class="install-tab" role="tab" data-os="linux" aria-selected="false">Linux</button>
                <button type="button" class="install-tab" role="tab" data-os="windows" aria-selected="false">Windows</button>
                <button type="button" class="install-tab" role="tab" data-os="cargo" aria-selected="false">Cargo Source</button>
              </div>
              <div class="install-cmd-row">
                <div style="overflow-x:auto;"><span class="install-prompt">$</span><code data-modal-cmd>${commands.brew}</code></div>
                <button type="button" class="copy-chip" data-modal-copy>Copy</button>
              </div>
            </div>
            <div class="trace-card" style="margin-bottom:18px;">
              <div class="mono" style="font-size:11.5px; color:var(--stone-muted); margin-bottom:6px;">Start small or go autonomous in any git repository:</div>
              <pre style="margin:0; font-size:12px; line-height:1.65; overflow-x:auto;"><code># Step 1: Add &lt;2ms pre-commit file-lease &amp; secret protection
chump hook install

# Step 2: Generate &amp; validate ~/.chump/config.toml
chump config init &amp;&amp; chump config validate

# Step 3: Start background supervisor + local web cockpit
chump service install &amp;&amp; chump up
chump --web --port 3847</code></pre>
            </div>
            <div style="display:flex; justify-content:space-between; align-items:center; gap:12px; flex-wrap:wrap;">
              <a class="btn btn-stone btn-sm" href="${prefix}/tools/config-doctor/">Audit Existing .env →</a>
              <a class="btn btn-dark btn-sm" href="${prefix}/docs/" data-cockpit-cta>Read Quickstart Docs →</a>
            </div>
          </div>
        </div>
      `;

      const backdrop = this.querySelector(".modal-backdrop");
      const cmdEl = this.querySelector("[data-modal-cmd]");
      const copyBtn = this.querySelector("[data-modal-copy]");
      const closeBtn = this.querySelector("[data-close-modal]");

      this.querySelectorAll("[data-os]").forEach((tab) => {
        tab.addEventListener("click", () => {
          const os = tab.getAttribute("data-os");
          this.querySelectorAll("[data-os]").forEach((t) =>
            t.setAttribute("aria-selected", t === tab ? "true" : "false")
          );
          if (cmdEl && commands[os]) cmdEl.textContent = commands[os];
        });
      });

      if (copyBtn && cmdEl) {
        copyBtn.addEventListener("click", () => copyText(cmdEl.textContent, copyBtn));
      }
      if (closeBtn) {
        closeBtn.addEventListener("click", () => window.ChumpSite.closeInstallModal());
      }
      if (backdrop) {
        backdrop.addEventListener("click", (e) => {
          if (e.target === backdrop) window.ChumpSite.closeInstallModal();
        });
      }
      document.addEventListener("keydown", (e) => {
        if (e.key === "Escape") window.ChumpSite.closeInstallModal();
      });

      if (daemonHealth) applyDaemonOnline(daemonHealth);
    }
  }

  if (!customElements.get("chump-site-header")) {
    customElements.define("chump-site-header", ChumpSiteHeader);
  }
  if (!customElements.get("chump-site-footer")) {
    customElements.define("chump-site-footer", ChumpSiteFooter);
  }
  if (!customElements.get("chump-install-modal")) {
    customElements.define("chump-install-modal", ChumpInstallModal);
  }

  /* ── Live /api/health Probe (When Served via `chump --web`) ────────────── */

  function applyDaemonOnline(data) {
    const ver = data.binary_version || "1.0.0";
    const sha = data.build_sha ? ` (${String(data.build_sha).slice(0, 8)})` : "";
    const mode = data.cascade_mode ? ` · ${data.cascade_mode}` : "";
    document.querySelectorAll("[data-daemon-badge]").forEach((pill) => {
      pill.setAttribute("data-live", "true");
    });
    document.querySelectorAll("[data-daemon-text]").forEach((txt) => {
      txt.textContent = `Local chumpd live · v${ver}${mode}`;
    });
    document.querySelectorAll("[data-footer-version]").forEach((el) => {
      el.textContent = `Connected to local chump-web v${ver}${sha}${mode}`;
    });
    document.querySelectorAll("[data-cockpit-cta]").forEach((link) => {
      link.setAttribute("href", "/v2/");
      link.removeAttribute("target");
      link.removeAttribute("rel");
      link.textContent = "Live Cockpit ↗";
    });
  }

  async function probeLocalDaemon() {
    if (probed) return;
    probed = true;
    const host = window.location.hostname;
    const isLocalDaemonPath =
      (host === "127.0.0.1" || host === "localhost") &&
      window.location.pathname.startsWith("/site");
    if (!isLocalDaemonPath) return;
    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 900);
      const res = await fetch("/api/health", { signal: ctrl.signal });
      clearTimeout(timer);
      if (!res.ok) return;
      const data = await res.json();
      if (data && data.status === "ok") {
        daemonHealth = data;
        applyDaemonOnline(data);
        window.dispatchEvent(new CustomEvent("chump-daemon-health", { detail: data }));
      }
    } catch (_) {
      /* Static hosting / offline — keep graceful static Docs/GitHub CTAs */
    }
  }

  /* ── 3D Sovereign Fleet Lattice Canvas (Token-Driven, Zero Raw Colors) ─── */

  window.initChumpLattice = function initChumpLattice(canvasId) {
    const canvas = document.getElementById(canvasId);
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const nodes = [];
    const rings = 7;
    for (let r = 1; r <= rings; r++) {
      const phi = (Math.PI * r) / (rings + 1);
      const count = Math.max(6, Math.round(Math.sin(phi) * 22));
      for (let i = 0; i < count; i++) {
        const theta = (2 * Math.PI * i) / count;
        nodes.push({
          x: Math.sin(phi) * Math.cos(theta),
          y: Math.cos(phi),
          z: Math.sin(phi) * Math.sin(theta),
          leased: (r + i) % 7 === 0,
          sage: (r * 3 + i) % 11 === 0,
        });
      }
    }

    let angleY = 0.4;
    let angleX = 0.22;
    let targetX = 0.22;
    let targetY = 0;

    canvas.addEventListener("pointermove", (e) => {
      const rect = canvas.getBoundingClientRect();
      const nx = (e.clientX - rect.left) / rect.width - 0.5;
      const ny = (e.clientY - rect.top) / rect.height - 0.5;
      targetY = nx * 0.65;
      targetX = 0.22 + ny * 0.45;
    });

    function resize() {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const rect = canvas.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) return;
      canvas.width = Math.round(rect.width * dpr);
      canvas.height = Math.round(rect.height * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }

    resize();
    window.addEventListener("resize", resize);

    let colors = readPalette();
    function readPalette() {
      const s = getComputedStyle(document.documentElement);
      return {
        ink: s.getPropertyValue("--stone-ink").trim(),
        faint: s.getPropertyValue("--stone-rule-strong").trim(),
        bronze: s.getPropertyValue("--stone-bronze").trim(),
        sage: s.getPropertyValue("--stone-sage").trim(),
      };
    }
    window.addEventListener("chump-theme-change", () => {
      colors = readPalette();
    });

    function frame() {
      if (document.hidden) {
        requestAnimationFrame(frame);
        return;
      }
      const rect = canvas.getBoundingClientRect();
      const w = rect.width;
      const h = rect.height;
      if (w > 0 && h > 0) {
        ctx.clearRect(0, 0, w, h);
        angleY += 0.0038;
        const ry = angleY + targetY;
        const rx = angleX + (targetX - angleX) * 0.08;
        angleX = rx;

        const radius = Math.min(w, h) * 0.34;
        const cx = w * 0.5;
        const cy = h * 0.5;

        const projected = nodes.map((n) => {
          const x1 = n.x * Math.cos(ry) - n.z * Math.sin(ry);
          const z1 = n.x * Math.sin(ry) + n.z * Math.cos(ry);
          const y2 = n.y * Math.cos(rx) - z1 * Math.sin(rx);
          const z2 = n.y * Math.sin(rx) + z1 * Math.cos(rx);
          const depth = (z2 + 1.6) / 2.6;
          return {
            sx: cx + x1 * radius,
            sy: cy + y2 * radius,
            z: z2,
            depth,
            leased: n.leased,
            sage: n.sage,
          };
        });

        ctx.lineWidth = 0.85;
        ctx.strokeStyle = colors.faint;
        for (let i = 0; i < projected.length; i++) {
          const a = projected[i];
          if (a.z < -0.25) continue;
          for (let j = i + 1; j < projected.length; j++) {
            const b = projected[j];
            if (b.z < -0.25) continue;
            const dx = a.sx - b.sx;
            const dy = a.sy - b.sy;
            const distSq = dx * dx + dy * dy;
            if (distSq < (radius * 0.36) * (radius * 0.36)) {
              ctx.globalAlpha = Math.min(0.45, a.depth * 0.35);
              ctx.beginPath();
              ctx.moveTo(a.sx, a.sy);
              ctx.lineTo(b.sx, b.sy);
              ctx.stroke();
            }
          }
        }

        projected.sort((a, b) => a.z - b.z);
        for (const p of projected) {
          ctx.globalAlpha = Math.max(0.18, Math.min(0.96, p.depth));
          ctx.beginPath();
          const r = p.leased || p.sage ? 3.8 * p.depth + 1.2 : 2.1 * p.depth + 0.7;
          ctx.arc(p.sx, p.sy, r, 0, Math.PI * 2);
          ctx.fillStyle = p.leased ? colors.bronze : p.sage ? colors.sage : colors.ink;
          ctx.fill();
        }
        ctx.globalAlpha = 1;
      }
      requestAnimationFrame(frame);
    }

    requestAnimationFrame(frame);
  };
})();
