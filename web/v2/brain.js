// web/v2/brain.js — INFRA-1558: Cytoscape.js renderer for /api/brain/graph.json.
// Force-directed (fcose) layout, node-type filters, relation-colored edges, click-to-focus
// subgraph + right-pane detail via /api/brain/node/{id}, incremental SSE updates from
// /api/brain/graph/stream. 2D only, no animation beyond the default layout (scope guard).

const RELATION_COLORS = {
  blocks: '#ff453a',
  references: '#4aa3ff',
  ships: '#30d158',
  applies_lesson: '#ffd60a',
  claims: '#c08fff',
};
const DEFAULT_EDGE_COLOR = '#5a6472';

// Heuristic node-type classifier — the underlying memory-graph table stores plain
// subject/object strings with no type column, so type is inferred from id shape.
function nodeType(id) {
  const s = String(id);
  if (/^[A-Z][A-Z0-9_-]*-\d+$/.test(s)) return 'gap';
  if (/^#?\d+$/.test(s) || /^pr[:#-]/i.test(s)) return 'pr';
  if (/^agent[:\-]/i.test(s)) return 'agent';
  if (/^lesson[:\-]/i.test(s)) return 'lesson';
  if (/^ambient[:\-]/i.test(s)) return 'ambient_event';
  return 'other';
}

const TYPE_COLORS = {
  gap: '#4aa3ff',
  pr: '#30d158',
  agent: '#c08fff',
  lesson: '#ffd60a',
  ambient_event: '#ff9f0a',
  other: '#5a6472',
};

function edgeColor(relation) {
  return RELATION_COLORS[relation] || DEFAULT_EDGE_COLOR;
}

function edgeId(source, target, relation) {
  return `e:${source}>${relation}>${target}`;
}

let cy = null;
const activeTypeFilters = new Set(Object.keys(TYPE_COLORS));

function buildElements(graph) {
  const nodeIds = new Set();
  const elements = [];
  for (const e of graph.edges || []) {
    nodeIds.add(e.source);
    nodeIds.add(e.target);
  }
  for (const id of nodeIds) {
    elements.push({ data: { id, type: nodeType(id) }, group: 'nodes' });
  }
  for (const e of graph.edges || []) {
    elements.push({
      data: {
        id: edgeId(e.source, e.target, e.relation),
        source: e.source,
        target: e.target,
        relation: e.relation,
      },
      group: 'edges',
    });
  }
  return elements;
}

function applyFilters() {
  if (!cy) return;
  cy.nodes().forEach((n) => {
    const visible = activeTypeFilters.has(n.data('type'));
    n.style('display', visible ? 'element' : 'none');
  });
  cy.edges().forEach((e) => {
    const visible = e.source().style('display') !== 'none' && e.target().style('display') !== 'none';
    e.style('display', visible ? 'element' : 'none');
  });
}

async function showNodeDetail(id) {
  const panel = document.getElementById('brain-detail');
  panel.textContent = 'Loading…';
  try {
    const r = await fetch(`/api/brain/node/${encodeURIComponent(id)}`);
    if (!r.ok) { panel.textContent = `No record for ${id}`; return; }
    const rec = await r.json();
    panel.innerHTML = `<div style="font-weight:600;margin-bottom:6px;">${rec.id}</div>` +
      `<div style="color:#9aa4b2;margin-bottom:8px;">degree ${rec.degree}</div>` +
      rec.neighbors.map((n) =>
        `<div class="neighbor">${n.direction === 'out' ? '→' : '←'} <b>${n.relation}</b> ${n.other}</div>`
      ).join('');
  } catch {
    panel.textContent = `Failed to load ${id}`;
  }
}

function focusSubgraph(id) {
  if (!cy) return;
  const node = cy.getElementById(id);
  if (!node || node.empty()) return;
  const neighborhood = node.closedNeighborhood();
  cy.elements().not(neighborhood).style('opacity', 0.12);
  neighborhood.style('opacity', 1);
}

function buildFilterBar() {
  const bar = document.createElement('div');
  bar.id = 'brain-filters';
  bar.innerHTML = '<div style="margin-bottom:4px;color:#9aa4b2;">Node type</div>' +
    Object.keys(TYPE_COLORS).map((t) =>
      `<label><input type="checkbox" data-type="${t}" checked> ${t}</label>`
    ).join('');
  bar.addEventListener('change', (ev) => {
    const t = ev.target.getAttribute('data-type');
    if (!t) return;
    if (ev.target.checked) activeTypeFilters.add(t); else activeTypeFilters.delete(t);
    applyFilters();
  });
  document.getElementById('brain-root').appendChild(bar);

  const legend = document.createElement('div');
  legend.id = 'brain-legend';
  legend.innerHTML = Object.entries(RELATION_COLORS).map(([rel, color]) =>
    `<span><span class="dot" style="background:${color}"></span>${rel}</span>`
  ).join('');
  document.getElementById('brain-root').appendChild(legend);
}

function initCytoscape(elements) {
  cy = cytoscape({
    container: document.getElementById('cy-container'),
    elements,
    style: [
      { selector: 'node', style: {
        'background-color': (n) => TYPE_COLORS[n.data('type')] || DEFAULT_EDGE_COLOR,
        'label': 'data(id)',
        'font-size': 8,
        'color': '#e6e8ec',
        'width': 18,
        'height': 18,
      } },
      { selector: 'edge', style: {
        'width': 1.5,
        'line-color': (e) => edgeColor(e.data('relation')),
        'target-arrow-color': (e) => edgeColor(e.data('relation')),
        'target-arrow-shape': 'triangle',
        'curve-style': 'bezier',
        'opacity': 0.8,
      } },
    ],
    layout: { name: 'fcose', animate: false, quality: 'default' },
  });
  cy.on('tap', 'node', (ev) => {
    const id = ev.target.id();
    focusSubgraph(id);
    showNodeDetail(id);
  });
  cy.on('tap', (ev) => {
    if (ev.target === cy) cy.elements().style('opacity', 1); // tap background clears focus
  });
}

function applyIncrementalUpdate(graph) {
  if (!cy) return;
  const wantEdgeIds = new Set();
  const wantNodeIds = new Set();
  for (const e of graph.edges || []) {
    wantNodeIds.add(e.source);
    wantNodeIds.add(e.target);
    wantEdgeIds.add(edgeId(e.source, e.target, e.relation));
  }
  // Remove edges/nodes no longer present.
  cy.edges().forEach((e) => { if (!wantEdgeIds.has(e.id())) e.remove(); });
  cy.nodes().forEach((n) => { if (!wantNodeIds.has(n.id())) n.remove(); });
  // Add new nodes/edges.
  for (const id of wantNodeIds) {
    if (cy.getElementById(id).empty()) {
      cy.add({ data: { id, type: nodeType(id) }, group: 'nodes' });
    }
  }
  for (const e of graph.edges || []) {
    const eid = edgeId(e.source, e.target, e.relation);
    if (cy.getElementById(eid).empty()) {
      cy.add({ data: { id: eid, source: e.source, target: e.target, relation: e.relation }, group: 'edges' });
    }
  }
  applyFilters();
}

function subscribeToStream() {
  const es = new EventSource('/api/brain/graph/stream');
  es.addEventListener('update', (ev) => {
    try { applyIncrementalUpdate(JSON.parse(ev.data)); } catch { /* ignore malformed frame */ }
  });
  es.onerror = () => { /* browser auto-reconnects EventSource */ };
}

async function boot() {
  buildFilterBar();
  let graph = { nodes: [], edges: [] };
  try {
    const r = await fetch('/api/brain/graph.json');
    if (r.ok) graph = await r.json();
  } catch { /* render empty graph on fetch failure */ }
  initCytoscape(buildElements(graph));
  subscribeToStream();
}

if (typeof cytoscape !== 'undefined' && cytoscape.use && typeof cytoscapeFcose !== 'undefined') {
  cytoscape.use(cytoscapeFcose);
}
window.addEventListener('DOMContentLoaded', boot);
