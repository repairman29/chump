// INFRA-1558: brain graph visualization renderer.
// Cytoscape.js force-directed (fcose) layout over /api/brain/graph.json.
// Scope guard: 2D only, no 3D, no animation beyond the default layout.
// Filters by node-type, edge color by relation kind, live SSE updates,
// click-to-focus with a right-pane record fetched from /api/brain/node/{id}.

const NODE_TYPES = ['gap', 'pr', 'agent', 'lesson', 'ambient_event', 'other'];
const RELATION_KINDS = ['blocks', 'references', 'ships', 'applies_lesson', 'claims'];

function authHeaders() {
  return { Authorization: `Bearer ${window.CHUMP_TOKEN || ''}` };
}

function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function edgeColor(relation) {
  const varName = RELATION_KINDS.includes(relation)
    ? `--edge-${relation}`
    : '--edge-default';
  return cssVar(varName) || cssVar('--edge-default');
}

function buildElements(graph) {
  const nodes = (graph.nodes || []).map((n) => ({
    data: { id: n.id, degree: n.degree, node_type: n.node_type || 'other' },
  }));
  const edges = (graph.edges || []).map((e) => ({
    data: {
      id: `${e.source}__${e.relation}__${e.target}`,
      source: e.source,
      target: e.target,
      relation: e.relation,
      weight: e.weight,
    },
  }));
  return [...nodes, ...edges];
}

async function fetchGraph() {
  const res = await fetch('/api/brain/graph.json', { headers: authHeaders() });
  if (!res.ok) throw new Error(`graph fetch failed: ${res.status}`);
  return res.json();
}

async function fetchNode(id) {
  const res = await fetch(`/api/brain/node/${encodeURIComponent(id)}`, { headers: authHeaders() });
  if (!res.ok) return null;
  return res.json();
}

function renderDetail(record) {
  const pane = document.getElementById('brain-detail');
  if (!record) {
    pane.classList.add('hidden');
    pane.innerHTML = '';
    return;
  }
  const neighbors = (record.neighbors || [])
    .map(
      (n) =>
        `<div class="neighbor">${n.direction === 'outgoing' ? '→' : '←'} <b>${n.relation}</b> ${n.id}</div>`
    )
    .join('');
  pane.innerHTML = `
    <h2>${record.id}</h2>
    <div>type: <b>${record.node_type}</b></div>
    <div>degree: ${record.degree}</div>
    <h3>Connections</h3>
    ${neighbors || '<div>(none)</div>'}
  `;
  pane.classList.remove('hidden');
}

function renderFilters(cy) {
  const box = document.getElementById('brain-filters');
  NODE_TYPES.forEach((t) => {
    const label = document.createElement('label');
    label.className = 'brain-filter';
    const cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = true;
    cb.addEventListener('change', () => {
      const sel = cy.nodes(`[node_type = "${t}"]`);
      if (cb.checked) sel.style('display', 'element');
      else sel.style('display', 'none');
    });
    label.appendChild(cb);
    label.append(` ${t}`);
    box.appendChild(label);
  });
}

function cytoscapeStyle() {
  const base = [
    {
      selector: 'node',
      style: {
        label: 'data(id)',
        'font-size': 8,
        color: cssVar('--text'),
        'background-color': cssVar('--accent'),
        width: 'mapData(degree, 0, 20, 10, 40)',
        height: 'mapData(degree, 0, 20, 10, 40)',
      },
    },
    {
      selector: 'node:selected',
      style: { 'border-width': 3, 'border-color': cssVar('--success') },
    },
    {
      selector: 'edge',
      style: {
        width: 1.5,
        'curve-style': 'bezier',
        'target-arrow-shape': 'triangle',
        'line-color': (ele) => edgeColor(ele.data('relation')),
        'target-arrow-color': (ele) => edgeColor(ele.data('relation')),
      },
    },
  ];
  return base;
}

function applyIncremental(cy, kind, detail) {
  if (kind === 'node_added' && cy.getElementById(detail.id).empty()) {
    cy.add({ data: { id: detail.id, degree: 0, node_type: 'other' } });
  } else if (kind === 'node_removed') {
    cy.getElementById(detail.id).remove();
  } else if (kind === 'edge_added') {
    const id = `${detail.source}__${detail.relation}__${detail.target}`;
    if (cy.getElementById(id).empty()) {
      cy.add({ data: { id, source: detail.source, target: detail.target, relation: detail.relation } });
    }
  } else if (kind === 'edge_removed') {
    const id = `${detail.source}__${detail.relation}__${detail.target}`;
    cy.getElementById(id).remove();
  }
}

function wireLiveStream(cy) {
  const status = document.getElementById('brain-status');
  const es = new EventSource('/api/brain/graph/stream');
  es.addEventListener('open', () => {
    status.textContent = 'live';
  });
  ['node_added', 'node_removed', 'edge_added', 'edge_removed'].forEach((kind) => {
    es.addEventListener(kind, (ev) => {
      try {
        applyIncremental(cy, kind, JSON.parse(ev.data));
      } catch {
        // malformed event — skip, next tick will self-correct
      }
    });
  });
  es.onerror = () => {
    status.textContent = 'reconnecting…';
  };
}

async function initBrainGraph() {
  if (typeof cytoscapeFcose !== 'undefined' && typeof window.cytoscape?.use === 'function') {
    window.cytoscape.use(cytoscapeFcose);
  }
  const graph = await fetchGraph();
  const cy = window.cytoscape({
    container: document.getElementById('cy-container'),
    elements: buildElements(graph),
    style: cytoscapeStyle(),
    layout: { name: typeof cytoscapeFcose !== 'undefined' ? 'fcose' : 'cose' },
  });

  cy.on('tap', 'node', async (evt) => {
    const id = evt.target.id();
    cy.elements().unselect();
    evt.target.select();
    const record = await fetchNode(id);
    renderDetail(record);
  });
  cy.on('tap', (evt) => {
    if (evt.target === cy) renderDetail(null);
  });

  renderFilters(cy);
  wireLiveStream(cy);
}

if (typeof document !== 'undefined') {
  document.addEventListener('DOMContentLoaded', () => {
    initBrainGraph().catch((err) => {
      const status = document.getElementById('brain-status');
      if (status) status.textContent = `error: ${err.message}`;
    });
  });
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { buildElements, applyIncremental };
}
