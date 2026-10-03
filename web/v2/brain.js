// INFRA-1558: brain graph visualization — Cytoscape.js force-directed layout
// over /api/brain/graph.json. Dev-debugging tool for the gap↔PR↔agent↔lesson
// relationship mesh. See acceptance criteria in docs/gaps/INFRA-1558.yaml.
//
// Vendored (not CDN) per the PWA's air-gap-capable design: web/v2/lib/vendor/
// {layout-base,cose-base,cytoscape-fcose,cytoscape.min}.js, loaded as classic
// (non-module) <script> tags by index.html before this module runs.

const RELATION_COLORS = {
  blocks: '#e85d5d',
  references: '#5d9ee8',
  ships: '#5de89a',
  applies_lesson: '#e8c75d',
  claims: '#c75de8',
};
const DEFAULT_EDGE_COLOR = '#888';

// Cytoscape's style engine takes literal color strings, not CSS var()
// references — resolve the PWA's design tokens once at init so canvas-drawn
// elements (node text, borders) stay on the token system (INFRA-1590).
function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

// Node "type" is inferred from id shape — the graph store has no explicit
// type column, so this is a best-effort client-side heuristic for filtering.
function inferNodeType(id) {
  const s = String(id);
  if (/^(INFRA|PRODUCT|CREDIBLE|RESILIENT|MISSION|META|DOC|EFFECTIVE)-\d+$/i.test(s)) return 'gap';
  if (/^pr[:#-]?\d+$/i.test(s) || /^#\d+$/.test(s)) return 'pr';
  if (/^(agent|curator|session)[:_-]/i.test(s)) return 'agent';
  if (/^lesson[:_-]/i.test(s)) return 'lesson';
  if (/^(ambient|event)[:_-]/i.test(s)) return 'ambient_event';
  return 'other';
}

const TYPE_COLORS = {
  gap: '#5d9ee8',
  pr: '#5de89a',
  agent: '#e8c75d',
  lesson: '#c75de8',
  ambient_event: '#e8955d',
  other: '#999',
};

class ChumpViewBrain extends HTMLElement {
  #cy = null;
  #es = null;
  #filters = new Set(['gap', 'pr', 'agent', 'lesson', 'ambient_event', 'other']);

  connectedCallback() {
    this.innerHTML = `
      <div class="view-panel chump-brain-view">
        <h2 class="view-title">Brain Graph</h2>
        <p class="view-subtitle">Gap ↔ PR ↔ agent ↔ lesson relationship mesh (live)</p>
        <div class="chump-brain-toolbar" id="brain-filters"></div>
        <div class="chump-brain-body">
          <div id="cy-container" style="width:100%;height:560px;border:1px solid var(--border);background:var(--bg);"></div>
          <div id="brain-detail" class="chump-brain-detail">
            <p class="chump-brain-detail-empty">Click a node to see its full record.</p>
          </div>
        </div>
      </div>`;
    this.#renderFilters();
    this.#initCytoscape();
    this.#loadGraph();
    this.#subscribeStream();
  }

  disconnectedCallback() {
    this.#es?.close();
    this.#es = null;
    this.#cy?.destroy();
    this.#cy = null;
  }

  #renderFilters() {
    const bar = this.querySelector('#brain-filters');
    const types = ['gap', 'pr', 'agent', 'lesson', 'ambient_event', 'other'];
    bar.innerHTML = types
      .map(
        (t) => `<label class="chump-brain-filter">
          <input type="checkbox" data-type="${t}" checked> ${t}
        </label>`
      )
      .join('');
    bar.querySelectorAll('input[data-type]').forEach((cb) => {
      cb.addEventListener('change', () => {
        const t = cb.getAttribute('data-type');
        if (cb.checked) this.#filters.add(t);
        else this.#filters.delete(t);
        this.#applyFilters();
      });
    });
  }

  #initCytoscape() {
    if (typeof cytoscape === 'undefined') {
      this.querySelector('#cy-container').textContent = 'Cytoscape failed to load.';
      return;
    }
    if (typeof cytoscapeFcose !== 'undefined' && !cytoscape.prototype.__fcoseRegistered) {
      cytoscape.use(cytoscapeFcose);
      cytoscape.prototype.__fcoseRegistered = true;
    }
    this.#cy = cytoscape({
      container: this.querySelector('#cy-container'),
      style: [
        {
          selector: 'node',
          style: {
            'background-color': (n) => TYPE_COLORS[n.data('type')] || TYPE_COLORS.other,
            label: 'data(id)',
            'font-size': 9,
            color: cssVar('--text'),
            'text-outline-width': 1,
            'text-outline-color': cssVar('--bg'),
          },
        },
        {
          selector: 'edge',
          style: {
            width: 1.5,
            'line-color': (e) => RELATION_COLORS[e.data('relation')] || DEFAULT_EDGE_COLOR,
            'target-arrow-color': (e) => RELATION_COLORS[e.data('relation')] || DEFAULT_EDGE_COLOR,
            'target-arrow-shape': 'triangle',
            'curve-style': 'bezier',
            label: 'data(relation)',
            'font-size': 7,
            color: cssVar('--text-secondary'),
          },
        },
        {
          selector: 'node.chump-brain-focused',
          style: { 'border-width': 3, 'border-color': cssVar('--accent') },
        },
      ],
      layout: { name: 'grid' },
    });
    this.#cy.on('tap', 'node', (evt) => this.#focusNode(evt.target.id()));
  }

  async #loadGraph() {
    try {
      const r = await fetch('/api/brain/graph.json');
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const graph = await r.json();
      this.#render(graph);
    } catch (e) {
      this.querySelector('#cy-container').textContent = `Failed to load graph: ${e.message}`;
    }
  }

  #render(graph) {
    if (!this.#cy) return;
    const elements = [
      ...graph.nodes.map((n) => ({ data: { id: n.id, degree: n.degree, type: inferNodeType(n.id) } })),
      ...graph.edges.map((e, i) => ({
        data: {
          id: `e${i}`,
          source: e.source,
          target: e.target,
          relation: e.relation,
          weight: e.weight,
        },
      })),
    ];
    this.#cy.elements().remove();
    this.#cy.add(elements);
    const layoutName = typeof cytoscapeFcose !== 'undefined' ? 'fcose' : 'grid';
    this.#cy.layout({ name: layoutName, animate: false, randomize: true }).run();
    this.#applyFilters();
  }

  #applyFilters() {
    if (!this.#cy) return;
    this.#cy.nodes().forEach((n) => {
      const visible = this.#filters.has(n.data('type'));
      n.style('display', visible ? 'element' : 'none');
    });
    this.#cy.edges().forEach((e) => {
      const show = e.source().style('display') !== 'none' && e.target().style('display') !== 'none';
      e.style('display', show ? 'element' : 'none');
    });
  }

  // SSE live updates (INFRA-1558 AC5): each tick re-pushes the full graph
  // snapshot; diff against what's rendered and add/remove incrementally
  // instead of a full teardown+rebuild (which would reset the layout).
  #subscribeStream() {
    if (typeof EventSource === 'undefined') return;
    this.#es = new EventSource('/api/brain/graph/stream');
    this.#es.addEventListener('graph', (ev) => {
      try {
        const graph = JSON.parse(ev.data);
        this.#applyIncremental(graph);
      } catch {
        /* malformed snapshot — skip this tick */
      }
    });
    this.#es.onerror = () => {
      /* EventSource auto-reconnects; nothing to do here */
    };
  }

  #applyIncremental(graph) {
    if (!this.#cy) return;
    const cy = this.#cy;
    const wantNodeIds = new Set(graph.nodes.map((n) => n.id));
    const wantEdgeIds = new Set(
      graph.edges.map((e) => `${e.source} ${e.relation} ${e.target}`)
    );

    cy.nodes().forEach((n) => {
      if (!wantNodeIds.has(n.id())) cy.remove(n);
    });
    graph.nodes.forEach((n) => {
      if (cy.getElementById(n.id).empty()) {
        cy.add({ data: { id: n.id, degree: n.degree, type: inferNodeType(n.id) } });
      } else {
        cy.getElementById(n.id).data('degree', n.degree);
      }
    });

    const existingEdgeKey = (e) => `${e.data('source')} ${e.data('relation')} ${e.data('target')}`;
    cy.edges().forEach((e) => {
      if (!wantEdgeIds.has(existingEdgeKey(e))) cy.remove(e);
    });
    const existingKeys = new Set(cy.edges().map(existingEdgeKey));
    graph.edges.forEach((e, i) => {
      const key = `${e.source} ${e.relation} ${e.target}`;
      if (!existingKeys.has(key)) {
        cy.add({
          data: { id: `live-e${i}-${Date.now()}`, source: e.source, target: e.target, relation: e.relation, weight: e.weight },
        });
      }
    });
    this.#applyFilters();
  }

  async #focusNode(id) {
    this.#cy.nodes().removeClass('chump-brain-focused');
    const node = this.#cy.getElementById(id);
    node.addClass('chump-brain-focused');
    const neighborhood = node.closedNeighborhood();
    this.#cy.elements().not(neighborhood).style('opacity', 0.15);
    neighborhood.style('opacity', 1);

    const panel = this.querySelector('#brain-detail');
    panel.innerHTML = '<p>Loading…</p>';
    try {
      const r = await fetch(`/api/brain/node/${encodeURIComponent(id)}`);
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const detail = await r.json();
      panel.innerHTML = `
        <h3>${this.#esc(detail.id)}</h3>
        <p>Degree: ${detail.degree}</p>
        <ul class="chump-brain-edge-list">
          ${detail.edges
            .map(
              (e) =>
                `<li><code>${this.#esc(e.source)}</code> —<em>${this.#esc(e.relation)}</em>→ <code>${this.#esc(e.target)}</code></li>`
            )
            .join('')}
        </ul>`;
    } catch (e) {
      panel.innerHTML = `<p>Failed to load node: ${this.#esc(e.message)}</p>`;
    }
  }

  #esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
}
customElements.define('chump-view-brain', ChumpViewBrain);
