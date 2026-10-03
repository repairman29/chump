// INFRA-1558 — brain graph visualization renderer.
// Cytoscape.js force-directed (fcose) layout over /api/brain/graph.json.
// Scope guard: 2D only, no animations beyond the default layout, <800 LOC.

(function () {
  'use strict';

  // The underlying graph (`chump_memory_graph` subject/relation/object rows,
  // see src/memory_graph_viz.rs) carries no explicit node-type column, so
  // type is inferred from id shape. This is a best-effort heuristic, not a
  // guarantee — unknown shapes fall back to "agent".
  const NODE_TYPES = ['gap', 'pr', 'agent', 'lesson', 'ambient_event'];

  const NODE_TYPE_COLOR = {
    gap: '#5e9cff',
    pr: '#30d158',
    agent: '#ff9f0a',
    lesson: '#bf5af2',
    ambient_event: '#8a8a8e',
  };

  const RELATION_COLOR = {
    blocks: '#ff453a',
    references: '#5e9cff',
    ships: '#30d158',
    applies_lesson: '#bf5af2',
    claims: '#ff9f0a',
  };
  const RELATION_DEFAULT_COLOR = '#5a5a5e';

  function inferNodeType(id) {
    const s = String(id);
    if (/^[A-Z][A-Z0-9_]*-\d+$/.test(s)) return 'gap';
    if (/^(pr|PR)[-#_]?\d+$/.test(s) || /^#\d+$/.test(s)) return 'pr';
    if (/^lesson[-_]/i.test(s)) return 'lesson';
    if (/^ambient[-_]/i.test(s) || /_event$/i.test(s)) return 'ambient_event';
    return 'agent';
  }

  function relationColor(relation) {
    return RELATION_COLOR[relation] || RELATION_DEFAULT_COLOR;
  }

  function toCyElements(graph) {
    const nodes = (graph.nodes || []).map((n) => ({
      data: { id: n.id, degree: n.degree, nodeType: inferNodeType(n.id) },
    }));
    const edges = (graph.edges || []).map((e, i) => ({
      data: {
        id: `e${i}:${e.source}->${e.target}:${e.relation}`,
        source: e.source,
        target: e.target,
        relation: e.relation,
        weight: e.weight,
      },
    }));
    return { nodes, edges };
  }

  function buildFilterUi(container, onChange) {
    container.innerHTML = '<div style="font-weight:600;margin-bottom:6px">Node type</div>';
    NODE_TYPES.forEach((t) => {
      const label = document.createElement('label');
      const cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = true;
      cb.dataset.nodeType = t;
      cb.addEventListener('change', onChange);
      const dot = document.createElement('span');
      dot.className = 'brain-legend-dot';
      dot.style.background = NODE_TYPE_COLOR[t];
      label.appendChild(cb);
      label.appendChild(dot);
      label.appendChild(document.createTextNode(t));
      container.appendChild(label);
    });
  }

  function activeTypes(container) {
    const active = new Set();
    container.querySelectorAll('input[data-node-type]').forEach((cb) => {
      if (cb.checked) active.add(cb.dataset.nodeType);
    });
    return active;
  }

  function renderDetail(sidebar, record) {
    if (!record || !record.id) {
      sidebar.innerHTML = '<div id="brain-detail-empty">No record found for this node.</div>';
      return;
    }
    const rows = (record.edges || [])
      .map((e) => {
        const dir = e.source === record.id ? `→ ${e.target}` : `← ${e.source}`;
        return `<div class="brain-edge-row"><span style="color:${relationColor(e.relation)}">${esc(e.relation)}</span> ${esc(dir)} <span style="opacity:.6">(w=${e.weight})</span></div>`;
      })
      .join('');
    sidebar.innerHTML = `
      <div style="font-weight:700;font-size:15px;margin-bottom:4px">${esc(record.id)}</div>
      <div style="color:var(--text-secondary);font-size:12px;margin-bottom:10px">degree ${record.degree}</div>
      ${rows || '<div id="brain-detail-empty">No edges recorded.</div>'}
    `;
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  async function fetchNodeRecord(id) {
    const r = await fetch(`/api/brain/node/${encodeURIComponent(id)}`);
    if (!r.ok) throw new Error(`node fetch failed: ${r.status}`);
    return r.json();
  }

  function focusSubgraph(cy, nodeId) {
    const node = cy.getElementById(nodeId);
    if (!node || node.empty()) return;
    const neighborhood = node.closedNeighborhood();
    cy.elements().removeClass('brain-dim');
    cy.elements().not(neighborhood).addClass('brain-dim');
  }

  // Diffs a fresh graph snapshot against the live Cytoscape elements and
  // applies add/remove incrementally (SSE live-update path) — no destroy
  // + full rebuild on every tick.
  function applySnapshotDiff(cy, graph) {
    const { nodes, edges } = toCyElements(graph);
    const nextNodeIds = new Set(nodes.map((n) => n.data.id));
    const nextEdgeIds = new Set(edges.map((e) => e.data.id));

    cy.nodes().forEach((n) => {
      if (!nextNodeIds.has(n.id())) cy.remove(n);
    });
    cy.edges().forEach((e) => {
      if (!nextEdgeIds.has(e.id())) cy.remove(e);
    });

    const toAddNodes = nodes.filter((n) => cy.getElementById(n.data.id).empty());
    const toAddEdges = edges.filter((e) => cy.getElementById(e.data.id).empty());
    if (toAddNodes.length) cy.add(toAddNodes);
    if (toAddEdges.length) cy.add(toAddEdges);

    // Keep degree labels fresh on nodes that survived.
    nodes.forEach((n) => {
      const el = cy.getElementById(n.data.id);
      if (!el.empty()) el.data('degree', n.data.degree);
    });

    if (toAddNodes.length || toAddEdges.length) {
      cy.layout({ name: 'fcose', animate: false, randomize: false }).run();
    }
  }

  async function init() {
    const status = document.getElementById('brain-status');
    const filters = document.getElementById('brain-filters');
    const sidebar = document.getElementById('brain-detail');

    let graph;
    try {
      const r = await fetch('/api/brain/graph.json');
      if (!r.ok) throw new Error(`graph fetch failed: ${r.status}`);
      graph = await r.json();
    } catch (e) {
      status.textContent = `brain graph unavailable: ${e.message}`;
      return;
    }

    const cy = cytoscape({
      container: document.getElementById('cy-container'),
      elements: toCyElements(graph),
      style: [
        {
          selector: 'node',
          style: {
            'background-color': (el) => NODE_TYPE_COLOR[el.data('nodeType')] || '#5a5a5e',
            label: 'data(id)',
            color: '#f0f0f0',
            'font-size': 9,
            width: (el) => 8 + Math.min(24, el.data('degree') || 0),
            height: (el) => 8 + Math.min(24, el.data('degree') || 0),
          },
        },
        {
          selector: 'edge',
          style: {
            width: 1.5,
            'line-color': (el) => relationColor(el.data('relation')),
            'target-arrow-color': (el) => relationColor(el.data('relation')),
            'target-arrow-shape': 'triangle',
            'curve-style': 'bezier',
            opacity: 0.8,
          },
        },
        { selector: '.brain-dim', style: { opacity: 0.12 } },
      ],
      layout: { name: 'fcose', animate: false },
    });

    status.textContent = `${graph.nodes.length} nodes · ${graph.edges.length} edges`;

    buildFilterUi(filters, () => {
      const active = activeTypes(filters);
      cy.nodes().forEach((n) => {
        const visible = active.has(n.data('nodeType'));
        n.style('display', visible ? 'element' : 'none');
      });
      cy.edges().forEach((e) => {
        const visible = e.source().style('display') !== 'none' && e.target().style('display') !== 'none';
        e.style('display', visible ? 'element' : 'none');
      });
    });

    cy.on('tap', 'node', async (evt) => {
      const id = evt.target.id();
      focusSubgraph(cy, id);
      try {
        const record = await fetchNodeRecord(id);
        renderDetail(sidebar, record);
      } catch (e) {
        sidebar.innerHTML = `<div id="brain-detail-empty">Failed to load record: ${esc(e.message)}</div>`;
      }
    });

    cy.on('tap', (evt) => {
      if (evt.target === cy) {
        cy.elements().removeClass('brain-dim');
      }
    });

    // Live updates (SSE) — INFRA-1558 AC5. Falls back silently if the
    // browser/environment doesn't support EventSource.
    if (typeof EventSource !== 'undefined') {
      const es = new EventSource('/api/brain/graph/stream');
      es.addEventListener('graph', (evt) => {
        try {
          const snapshot = JSON.parse(evt.data);
          applySnapshotDiff(cy, snapshot);
          status.textContent = `${cy.nodes().length} nodes · ${cy.edges().length} edges (live)`;
        } catch (_e) {
          // Malformed snapshot — skip this tick, keep the current view.
        }
      });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
