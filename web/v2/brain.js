// INFRA-1558: brain graph visualization — Cytoscape.js force-directed layout
// over /api/brain/graph.json. Dev-debugging tool (relationship mesh), not
// customer-facing. 2D only, no build step: Cytoscape + fcose load lazily
// from CDN the first time this view mounts.

const CY_CDN = 'https://cdn.jsdelivr.net/npm/cytoscape@3.30.2/dist/cytoscape.min.js';
const LAYOUT_BASE_CDN = 'https://cdn.jsdelivr.net/npm/layout-base@2.0.1/layout-base.js';
const COSE_BASE_CDN = 'https://cdn.jsdelivr.net/npm/cose-base@2.2.0/cose-base.js';
const FCOSE_CDN = 'https://cdn.jsdelivr.net/npm/cytoscape-fcose@2.2.0/cytoscape-fcose.js';

const NODE_TYPES = [
  { id: 'gap', label: 'Gap', test: (id) => /^[A-Z][A-Z-]*-\d+$/.test(id) },
  { id: 'pr', label: 'PR', test: (id) => /^(pr[\s#-]?\d+|#\d+)/i.test(id) },
  { id: 'agent', label: 'Agent', test: (id) => /agent|curator|opus|sonnet|haiku/i.test(id) },
  { id: 'lesson', label: 'Lesson', test: (id) => /lesson/i.test(id) },
  { id: 'ambient_event', label: 'Ambient event', test: (id) => /ambient|kind=/i.test(id) },
];

function classifyNode(id) {
  const hit = NODE_TYPES.find((t) => t.test(id));
  return hit ? hit.id : 'other';
}

// Small fixed palette; a relation string always hashes to the same color
// within one session so the legend stays stable while the graph updates.
const EDGE_PALETTE = ['#0a84ff', '#30d158', '#ff9f0a', '#ff453a', '#bf5af2', '#64d2ff', '#ffd60a'];
function colorForRelation(relation) {
  let h = 0;
  for (let i = 0; i < relation.length; i++) h = (h * 31 + relation.charCodeAt(i)) | 0;
  return EDGE_PALETTE[Math.abs(h) % EDGE_PALETTE.length];
}

function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || 'gray';
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    if (document.querySelector(`script[src="${src}"]`)) return resolve();
    const s = document.createElement('script');
    s.src = src;
    s.onload = () => resolve();
    s.onerror = () => reject(new Error(`failed to load ${src}`));
    document.head.appendChild(s);
  });
}

class ChumpViewBrain extends HTMLElement {
  #cy = null;
  #es = null;
  #activeTypes = new Set();
  #knownRelations = new Set();

  connectedCallback() {
    this.innerHTML = `
      <div class="view-panel brain-view">
        <h2 class="view-title">Brain Graph</h2>
        <p class="view-subtitle">gap ↔ PR ↔ agent ↔ lesson relationship mesh — dev debugging tool</p>
        <div class="brain-toolbar" id="brain-filters"></div>
        <div class="brain-body">
          <div id="cy-container"></div>
          <div id="brain-detail" class="brain-detail">
            <p class="brain-detail-empty">Click a node to inspect its record.</p>
          </div>
        </div>
        <div class="brain-legend" id="brain-legend"></div>
        <p id="brain-status" class="brain-status"></p>
      </div>`;
    this.#boot();
  }

  disconnectedCallback() {
    this.#es?.close();
    this.#es = null;
  }

  _authHeaders() {
    try {
      const t = window.chumpPrefs && window.chumpPrefs.get ? window.chumpPrefs.get('webToken') : null;
      if (t) return { 'X-Chump-Auth': t };
    } catch (_e) {}
    return {};
  }

  #setStatus(msg) {
    const el = this.querySelector('#brain-status');
    if (el) el.textContent = msg;
  }

  async #boot() {
    try {
      await this.#loadCytoscapeLibs();
    } catch (e) {
      this.#setStatus('Cytoscape.js failed to load (offline?) — brain graph unavailable.');
      return;
    }
    try {
      await this.#loadGraph();
    } catch (e) {
      this.#setStatus('Could not load /api/brain/graph.json.');
      return;
    }
    this.#wireStream();
  }

  async #loadCytoscapeLibs() {
    if (!window.cytoscape) await loadScript(CY_CDN);
    if (!window.cytoscapeFcose) {
      await loadScript(LAYOUT_BASE_CDN);
      await loadScript(COSE_BASE_CDN);
      await loadScript(FCOSE_CDN);
    }
    if (window.cytoscape && window.cytoscapeFcose && !window.cytoscape.__chumpFcoseRegistered) {
      window.cytoscape.use(window.cytoscapeFcose);
      window.cytoscape.__chumpFcoseRegistered = true;
    }
  }

  async #loadGraph() {
    const r = await fetch('/api/brain/graph.json', { headers: this._authHeaders() });
    if (!r.ok) throw new Error(String(r.status));
    const data = await r.json();
    this.#renderGraph(data);
  }

  #renderGraph(data) {
    const nodes = (data.nodes || []).map((n) => ({
      data: { id: n.id, degree: n.degree, ntype: classifyNode(n.id) },
    }));
    const edges = (data.edges || []).map((e) => {
      this.#knownRelations.add(e.relation);
      return {
        data: {
          id: `e-${e.source}-${e.relation}-${e.target}`,
          source: e.source,
          target: e.target,
          relation: e.relation,
          weight: e.weight,
        },
      };
    });

    const container = this.querySelector('#cy-container');
    this.#cy = window.cytoscape({
      container,
      elements: { nodes, edges },
      style: [
        {
          selector: 'node',
          style: {
            label: 'data(id)',
            'font-size': 8,
            width: 'mapData(degree, 0, 20, 8, 40)',
            height: 'mapData(degree, 0, 20, 8, 40)',
            'background-color': cssVar('--accent'),
            color: cssVar('--text'),
            'text-valign': 'bottom',
            'text-wrap': 'ellipsis',
            'text-max-width': '80px',
          },
        },
        {
          selector: 'edge',
          style: {
            width: 1.5,
            'line-color': (ele) => colorForRelation(ele.data('relation')),
            'target-arrow-color': (ele) => colorForRelation(ele.data('relation')),
            'target-arrow-shape': 'triangle',
            'curve-style': 'bezier',
            opacity: 0.85,
          },
        },
        { selector: '.brain-dim', style: { opacity: 0.12 } },
        { selector: '.brain-focus', style: { opacity: 1, 'border-width': 2, 'border-color': cssVar('--warn') } },
      ],
      layout: { name: window.cytoscapeFcose ? 'fcose' : 'cose', animate: false },
      wheelSensitivity: 0.2,
    });

    this.#cy.on('tap', 'node', (evt) => this.#focusNode(evt.target.id()));
    this.#cy.on('tap', (evt) => {
      if (evt.target === this.#cy) this.#clearFocus();
    });

    this.#renderFilters();
    this.#renderLegend();
    this.#setStatus(`${nodes.length} nodes · ${edges.length} edges`);
  }

  #renderFilters() {
    const el = this.querySelector('#brain-filters');
    if (!el) return;
    el.innerHTML = NODE_TYPES.concat([{ id: 'other', label: 'Other' }])
      .map(
        (t) => `<button class="brain-filter-chip" data-ntype="${t.id}" aria-pressed="false">${t.label}</button>`
      )
      .join('');
    el.querySelectorAll('.brain-filter-chip').forEach((btn) => {
      btn.addEventListener('click', () => {
        const nt = btn.dataset.ntype;
        if (this.#activeTypes.has(nt)) {
          this.#activeTypes.delete(nt);
          btn.setAttribute('aria-pressed', 'false');
        } else {
          this.#activeTypes.add(nt);
          btn.setAttribute('aria-pressed', 'true');
        }
        this.#applyFilter();
      });
    });
  }

  #applyFilter() {
    if (!this.#cy) return;
    if (this.#activeTypes.size === 0) {
      this.#cy.elements().style('display', 'element');
      return;
    }
    this.#cy.nodes().forEach((n) => {
      const show = this.#activeTypes.has(n.data('ntype'));
      n.style('display', show ? 'element' : 'none');
    });
    this.#cy.edges().forEach((e) => {
      const show = e.source().style('display') !== 'none' && e.target().style('display') !== 'none';
      e.style('display', show ? 'element' : 'none');
    });
  }

  #renderLegend() {
    const el = this.querySelector('#brain-legend');
    if (!el) return;
    el.innerHTML = Array.from(this.#knownRelations)
      .sort()
      .map(
        (rel) =>
          `<span class="brain-legend-item"><span class="brain-legend-swatch" style="background:${colorForRelation(rel)}"></span>${rel}</span>`
      )
      .join('');
  }

  #clearFocus() {
    if (!this.#cy) return;
    this.#cy.elements().removeClass('brain-dim brain-focus');
  }

  async #focusNode(id) {
    if (!this.#cy) return;
    const node = this.#cy.getElementById(id);
    if (!node || node.empty()) return;
    const neighborhood = node.closedNeighborhood();
    this.#cy.elements().addClass('brain-dim').removeClass('brain-focus');
    neighborhood.removeClass('brain-dim').addClass('brain-focus');

    const detail = this.querySelector('#brain-detail');
    if (detail) detail.innerHTML = '<p>Loading…</p>';
    try {
      const r = await fetch(`/api/brain/node/${encodeURIComponent(id)}`, { headers: this._authHeaders() });
      if (!r.ok) throw new Error(String(r.status));
      const rec = await r.json();
      if (detail) {
        detail.innerHTML = `
          <h3>${this.#esc(rec.id)}</h3>
          <p>degree: ${rec.degree}</p>
          <ul class="brain-detail-edges">
            ${rec.edges
              .map(
                (e) =>
                  `<li><span style="color:${colorForRelation(e.relation)}">${this.#esc(e.relation)}</span>: ${this.#esc(e.source)} → ${this.#esc(e.target)}</li>`
              )
              .join('')}
          </ul>`;
      }
    } catch (e) {
      if (detail) detail.innerHTML = `<p>${this.#esc(id)}: record unavailable.</p>`;
    }
  }

  #esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  #wireStream() {
    if (!this.#cy) return;
    try {
      this.#es = new EventSource('/api/brain/graph/stream');
    } catch (_e) {
      return;
    }
    this.#es.addEventListener('snapshot', () => {
      // Initial state already rendered from /api/brain/graph.json; the
      // stream's own snapshot is only a resync marker, not a full reload.
    });
    this.#es.addEventListener('node_added', (evt) => {
      const { id } = JSON.parse(evt.data);
      if (this.#cy.getElementById(id).empty()) {
        this.#cy.add({ data: { id, degree: 0, ntype: classifyNode(id) } });
      }
    });
    this.#es.addEventListener('node_removed', (evt) => {
      const { id } = JSON.parse(evt.data);
      this.#cy.getElementById(id).remove();
    });
    this.#es.addEventListener('edge_added', (evt) => {
      const e = JSON.parse(evt.data);
      this.#knownRelations.add(e.relation);
      const eid = `e-${e.source}-${e.relation}-${e.target}`;
      if (this.#cy.getElementById(eid).empty()) {
        this.#cy.add({ data: { id: eid, source: e.source, target: e.target, relation: e.relation, weight: 1 } });
        this.#renderLegend();
      }
    });
    this.#es.addEventListener('edge_removed', (evt) => {
      const e = JSON.parse(evt.data);
      const eid = `e-${e.source}-${e.relation}-${e.target}`;
      this.#cy.getElementById(eid).remove();
    });
    this.#es.onerror = () => {
      // Best-effort live updates; EventSource auto-retries on its own.
    };
  }
}
customElements.define('chump-view-brain', ChumpViewBrain);
