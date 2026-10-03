// ── <chump-view-brain> — INFRA-1558 ─────────────────────────────────────────
// Cytoscape.js force-directed renderer over /api/brain/graph.json. Dev-debug
// tool: shows the relationship mesh (gap↔PR↔agent↔lesson↔ambient_event) that
// today is only readable as raw JSON. See acceptance criteria on INFRA-1558.
//
// SCOPE GUARD: 2D only, no 3D, no animations beyond the default fcose layout.
// Keep this file under 800 LOC.

const NODE_TYPES = ['gap', 'pr', 'agent', 'lesson', 'ambient_event', 'other'];

// Heuristic node-type classifier. The backend's entity graph (chump_memory_graph)
// stores freeform subject/object strings, not a typed node table — so type is
// inferred from the id's shape rather than read from a column.
function classifyNode(id) {
  const s = String(id);
  if (/^[a-z]+-\d+$/i.test(s)) return 'gap';
  if (/^(pr|#)\s*-?\d+$/i.test(s) || /\bpull request\b/i.test(s)) return 'pr';
  if (/^agent[:_-]|curator-|session-/i.test(s)) return 'agent';
  if (/^lesson[:_-]/i.test(s)) return 'lesson';
  if (/^(kind=|ambient[:_-])/i.test(s)) return 'ambient_event';
  return 'other';
}

const NODE_COLOR = {
  gap: '#4c8bf5',
  pr: '#38b36b',
  agent: '#f5a623',
  lesson: '#b05ce8',
  ambient_event: '#e85d75',
  other: '#8a8f98',
};

// AC #4: edges color-coded by relation kind.
const EDGE_COLOR = {
  blocks: '#e85d75',
  references: '#8a8f98',
  ships: '#38b36b',
  applies_lesson: '#b05ce8',
  claims: '#f5a623',
};
const EDGE_COLOR_DEFAULT = '#5a6472';

function edgeColor(relation) {
  const key = String(relation || '').toLowerCase();
  return EDGE_COLOR[key] ?? EDGE_COLOR_DEFAULT;
}

class ChumpViewBrain extends HTMLElement {
  #cy = null;
  #es = null;
  #activeTypes = new Set(NODE_TYPES);

  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Brain graph</h2>
        <p class="view-subtitle">Relationship mesh — gaps, PRs, agents, lessons, ambient events</p>
      </section>
      <section class="brain-toolbar" id="brain-toolbar">
        ${NODE_TYPES.map((t) => `
          <label class="brain-filter">
            <input type="checkbox" data-node-type="${t}" checked>
            <span style="color:${NODE_COLOR[t]}">${t}</span>
          </label>
        `).join('')}
        <span class="brain-status" id="brain-status">loading…</span>
      </section>
      <section class="brain-layout">
        <div id="cy-container" style="width:100%;height:600px;border:1px solid var(--border);"></div>
        <aside class="brain-detail" id="brain-detail">
          <p class="placeholder">Click a node for details.</p>
        </aside>
      </section>
    `;
    this.#wireFilters();
    this.#loadLibsThenInit();
  }

  disconnectedCallback() {
    this.#es?.close();
    this.#es = null;
  }

  #wireFilters() {
    this.querySelectorAll('[data-node-type]').forEach((cb) => {
      cb.addEventListener('change', () => {
        const t = cb.dataset.nodeType;
        if (cb.checked) this.#activeTypes.add(t);
        else this.#activeTypes.delete(t);
        this.#applyFilter();
      });
    });
  }

  #applyFilter() {
    if (!this.#cy) return;
    this.#cy.nodes().forEach((n) => {
      const visible = this.#activeTypes.has(n.data('nodeType'));
      n.style('display', visible ? 'element' : 'none');
    });
    this.#cy.edges().forEach((e) => {
      const visible = e.source().style('display') === 'element' && e.target().style('display') === 'element';
      e.style('display', visible ? 'element' : 'none');
    });
  }

  // Cytoscape + fcose are vendored locally under web/v2/lib/cytoscape/ (no CDN
  // dependency — this PWA must work air-gapped). Load order matters: fcose
  // depends on cose-base which depends on layout-base (plain UMD globals).
  #loadLibsThenInit() {
    if (window.cytoscape) {
      this.#init();
      return;
    }
    const scripts = [
      'lib/cytoscape/layout-base.js',
      'lib/cytoscape/cose-base.js',
      'lib/cytoscape/cytoscape-fcose.js',
      'lib/cytoscape/cytoscape.min.js',
    ];
    const loadNext = (i) => {
      if (i >= scripts.length) {
        if (window.cytoscape && window.cytoscapeFcose) {
          window.cytoscape.use(window.cytoscapeFcose);
        }
        this.#init();
        return;
      }
      const el = document.createElement('script');
      el.src = scripts[i];
      el.onload = () => loadNext(i + 1);
      el.onerror = () => {
        const status = this.querySelector('#brain-status');
        if (status) status.textContent = 'renderer failed to load';
      };
      document.head.appendChild(el);
    };
    loadNext(0);
  }

  #init() {
    const container = this.querySelector('#cy-container');
    if (!container || !window.cytoscape) return;
    this.#cy = window.cytoscape({
      container,
      elements: [],
      style: [
        {
          selector: 'node',
          style: {
            'background-color': 'data(color)',
            'label': 'data(id)',
            'font-size': 9,
            'width': 'mapData(degree, 0, 20, 12, 40)',
            'height': 'mapData(degree, 0, 20, 12, 40)',
            'color': '#ddd',
            'text-valign': 'bottom',
          },
        },
        {
          selector: 'edge',
          style: {
            'width': 1.5,
            'line-color': 'data(color)',
            'target-arrow-color': 'data(color)',
            'target-arrow-shape': 'triangle',
            'curve-style': 'bezier',
            'opacity': 0.8,
          },
        },
        {
          selector: '.brain-focus',
          style: { 'border-width': 3, 'border-color': '#fff' },
        },
      ],
      layout: { name: 'preset' },
    });

    this.#cy.on('tap', 'node', (evt) => this.#focusNode(evt.target.id()));

    this.#loadSnapshot();
    this.#subscribeStream();
  }

  #runLayout() {
    if (!this.#cy) return;
    const name = window.cytoscapeFcose ? 'fcose' : 'cose';
    this.#cy.layout({ name, animate: false, randomize: false }).run();
  }

  #toElements(graph) {
    const nodes = (graph.nodes ?? []).map((n) => ({
      data: { id: n.id, degree: n.degree ?? 0, nodeType: classifyNode(n.id), color: NODE_COLOR[classifyNode(n.id)] },
    }));
    const edges = (graph.edges ?? []).map((e, i) => ({
      data: {
        id: `e${i}-${e.source}-${e.target}`,
        source: e.source,
        target: e.target,
        relation: e.relation,
        color: edgeColor(e.relation),
      },
    }));
    return [...nodes, ...edges];
  }

  #loadSnapshot() {
    const status = this.querySelector('#brain-status');
    fetch('/api/brain/graph.json')
      .then((r) => r.json())
      .then((graph) => {
        this.#cy.elements().remove();
        this.#cy.add(this.#toElements(graph));
        this.#runLayout();
        this.#applyFilter();
        if (status) status.textContent = `${graph.nodes?.length ?? 0} nodes, ${graph.edges?.length ?? 0} edges`;
      })
      .catch(() => {
        if (status) status.textContent = 'graph unavailable';
      });
  }

  // AC #5: live updates via SSE — incremental cytoscape add/remove, no full reload.
  #subscribeStream() {
    try {
      this.#es = new EventSource('/api/brain/graph/stream');
    } catch {
      return;
    }
    this.#es.addEventListener('snapshot', (evt) => {
      try {
        const graph = JSON.parse(evt.data);
        this.#cy.elements().remove();
        this.#cy.add(this.#toElements(graph));
        this.#runLayout();
        this.#applyFilter();
      } catch { /* ignore malformed snapshot */ }
    });
    this.#es.addEventListener('delta', (evt) => {
      try {
        const delta = JSON.parse(evt.data);
        this.#applyDelta(delta);
      } catch { /* ignore malformed delta */ }
    });
    this.#es.onerror = () => { /* EventSource auto-reconnects */ };
  }

  #applyDelta(delta) {
    if (!this.#cy) return;
    let changed = false;
    for (const e of delta.removed_edges ?? []) {
      this.#cy.edges(`[source = "${e.source}"][target = "${e.target}"]`).remove();
      changed = true;
    }
    for (const e of delta.added_edges ?? []) {
      for (const [id, isSource] of [[e.source, true], [e.target, false]]) {
        if (this.#cy.getElementById(id).empty()) {
          const t = classifyNode(id);
          this.#cy.add({ data: { id, degree: 1, nodeType: t, color: NODE_COLOR[t] } });
          changed = true;
        }
      }
      this.#cy.add({
        data: {
          id: `e-${e.source}-${e.target}-${Date.now()}-${Math.random()}`,
          source: e.source,
          target: e.target,
          relation: e.relation,
          color: edgeColor(e.relation),
        },
      });
      changed = true;
    }
    if (changed) {
      this.#applyFilter();
    }
  }

  #focusNode(id) {
    const detail = this.querySelector('#brain-detail');
    if (!detail) return;
    this.#cy.elements().removeClass('brain-focus');
    const node = this.#cy.getElementById(id);
    if (node.empty()) return;
    const neighborhood = node.closedNeighborhood();
    neighborhood.addClass('brain-focus');
    detail.innerHTML = '<p class="placeholder">Loading node…</p>';
    fetch(`/api/brain/node/${encodeURIComponent(id)}`)
      .then((r) => { if (!r.ok) throw new Error('not found'); return r.json(); })
      .then((rec) => {
        const rows = (list, label) => (list.length === 0 ? '' : `
          <h4>${label}</h4>
          <ul>${list.map((e) => `<li>${e.source} <em>${e.relation}</em> ${e.target}</li>`).join('')}</ul>
        `);
        detail.innerHTML = `
          <h3>${rec.id}</h3>
          <p>degree: ${rec.degree}</p>
          ${rows(rec.outgoing ?? [], 'Outgoing')}
          ${rows(rec.incoming ?? [], 'Incoming')}
        `;
      })
      .catch(() => {
        detail.innerHTML = `<p class="placeholder">No record for "${id}".</p>`;
      });
  }
}
customElements.define('chump-view-brain', ChumpViewBrain);
