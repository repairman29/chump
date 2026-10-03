// INFRA-1558: brain graph visualization renderer.
// Cytoscape.js force-directed layout over /api/brain/graph.json, with live
// incremental updates from /api/brain/graph/stream. 2D only, no animations
// beyond the default layout (scope guard, AC6).
//
// The backing store (chump_memory_graph) is a generic entity-relation graph
// — nodes don't carry a stored "type" field. NODE_TYPES below classifies
// each node id heuristically (gap/PR/agent/lesson/ambient_event/other) so
// the filter UI in AC3 has something real to filter on.

const NODE_TYPES = ['gap', 'pr', 'agent', 'lesson', 'ambient_event', 'other'];

const NODE_COLORS = {
  gap: '#0a84ff',
  pr: '#30d158',
  agent: '#bf5af2',
  lesson: '#ff9f0a',
  ambient_event: '#ff453a',
  other: '#5a5a5e',
};

// AC4: edges color-coded by relation kind.
const EDGE_COLORS = [
  [/block/, '#ff453a'],
  [/reference/, '#0a84ff'],
  [/ship/, '#30d158'],
  [/lesson/, '#ff9f0a'],
  [/claim/, '#bf5af2'],
];

function classifyNode(id) {
  const s = String(id || '');
  if (/^[A-Z][A-Z0-9]*-\d+$/.test(s)) return 'gap';
  if (/^#?\d+$/.test(s) || /^pr[-_]?\d+$/i.test(s)) return 'pr';
  if (/lesson/i.test(s)) return 'lesson';
  if (/ambient|_event$/i.test(s)) return 'ambient_event';
  if (/agent|curator|session/i.test(s)) return 'agent';
  return 'other';
}

function edgeColor(relation) {
  const r = String(relation || '').toLowerCase();
  for (const [re, color] of EDGE_COLORS) {
    if (re.test(r)) return color;
  }
  return '#5a5a5e';
}

function nodeElement(n) {
  const type = classifyNode(n.id);
  return { data: { id: n.id, degree: n.degree || 0, type }, classes: `ntype-${type}` };
}

function edgeId(e) {
  return `e:${e.source}->${e.target}:${e.relation}`;
}

function edgeElement(e) {
  return {
    data: {
      id: edgeId(e),
      source: e.source,
      target: e.target,
      relation: e.relation,
      weight: e.weight,
      color: edgeColor(e.relation),
    },
  };
}

async function fetchJson(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url} -> ${r.status}`);
  return r.json();
}

function buildCy(graph) {
  return cytoscape({
    container: document.getElementById('cy-container'),
    elements: {
      nodes: (graph.nodes || []).map(nodeElement),
      edges: (graph.edges || []).map(edgeElement),
    },
    style: [
      {
        selector: 'node',
        style: {
          'background-color': (el) => NODE_COLORS[el.data('type')] || NODE_COLORS.other,
          label: 'data(id)',
          'font-size': 8,
          color: '#f0f0f0',
          width: (el) => 10 + Math.min(30, (el.data('degree') || 0) * 2),
          height: (el) => 10 + Math.min(30, (el.data('degree') || 0) * 2),
        },
      },
      {
        selector: 'edge',
        style: {
          width: 1,
          'line-color': 'data(color)',
          'target-arrow-color': 'data(color)',
          'target-arrow-shape': 'triangle',
          'curve-style': 'bezier',
          opacity: 0.7,
        },
      },
      { selector: '.hidden-type', style: { display: 'none' } },
      { selector: '.focus-dim', style: { opacity: 0.1 } },
    ],
    // Force-directed default layout (AC3). Built into cytoscape core, so
    // the renderer has no extra extension dependency to vendor/CDN-pin.
    layout: { name: 'cose', animate: false },
  });
}

function renderFilters(cy) {
  const root = document.getElementById('brain-filters');
  root.innerHTML = '';
  for (const t of NODE_TYPES) {
    const label = document.createElement('label');
    const cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = true;
    cb.addEventListener('change', () => {
      const sel = `.ntype-${t}`;
      if (cb.checked) cy.elements(sel).removeClass('hidden-type');
      else cy.elements(sel).addClass('hidden-type');
    });
    const dot = document.createElement('span');
    dot.className = 'legend-dot';
    dot.style.background = NODE_COLORS[t];
    label.appendChild(cb);
    label.appendChild(dot);
    label.appendChild(document.createTextNode(t));
    root.appendChild(label);
  }
}

async function showNodeDetail(id) {
  const panel = document.getElementById('node-detail');
  panel.innerHTML = `<h3>${id}</h3><p class="empty">Loading…</p>`;
  try {
    const detail = await fetchJson(`/api/brain/node/${encodeURIComponent(id)}`);
    const rows = (detail.neighbors || [])
      .map(
        (n) =>
          `<div class="neighbor"><span class="relation">${n.direction === 'out' ? '→' : '←'} ${n.relation}</span> ${n.id}</div>`
      )
      .join('');
    panel.innerHTML = `<h3>${detail.id}</h3><p>degree: ${detail.degree}</p>${rows || '<p class="empty">no neighbors</p>'}`;
  } catch {
    panel.innerHTML = `<h3>${id}</h3><p class="empty">No record found.</p>`;
  }
}

// Click node → focus subgraph (dim everything else) + load right-pane record (AC3).
function wireClickFocus(cy) {
  cy.on('tap', 'node', (evt) => {
    const node = evt.target;
    const neighborhood = node.closedNeighborhood();
    cy.elements().addClass('focus-dim');
    neighborhood.removeClass('focus-dim');
    showNodeDetail(node.id());
  });
  cy.on('tap', (evt) => {
    if (evt.target === cy) {
      cy.elements().removeClass('focus-dim');
      document.getElementById('node-detail').innerHTML =
        '<p class="empty">Click a node to inspect its record.</p>';
    }
  });
}

// AC5: SSE live updates — apply incremental add/remove, never a full reload.
function wireLiveStream(cy) {
  const es = new EventSource('/api/brain/graph/stream');
  es.addEventListener('graph_delta', (evt) => {
    let delta;
    try {
      delta = JSON.parse(evt.data);
    } catch {
      return;
    }
    for (const id of delta.removed_nodes || []) {
      const el = cy.getElementById(id);
      if (el.length) cy.remove(el);
    }
    for (const e of delta.removed_edges || []) {
      const el = cy.getElementById(edgeId(e));
      if (el.length) cy.remove(el);
    }
    for (const id of delta.added_nodes || []) {
      if (!cy.getElementById(id).length) {
        cy.add(nodeElement({ id, degree: 0 }));
      }
    }
    for (const e of delta.added_edges || []) {
      if (!cy.getElementById(edgeId(e)).length) {
        cy.add(edgeElement(e));
      }
    }
  });
  // EventSource auto-reconnects on transient drops; nothing else to do here.
}

async function main() {
  const graph = await fetchJson('/api/brain/graph.json');
  const cy = buildCy(graph);
  renderFilters(cy);
  wireClickFocus(cy);
  wireLiveStream(cy);
}

main().catch((err) => {
  document.getElementById('node-detail').innerHTML =
    `<p class="empty">Failed to load brain graph: ${err.message}</p>`;
});
