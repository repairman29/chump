// INFRA-1558: brain graph visualization renderer.
// Cytoscape.js force-directed layout over /api/brain/graph.json. Dev-debugging
// tool for the gap↔PR↔agent↔lesson relationship mesh. 2D only, no animations
// beyond the default layout (scope guard, see gap AC item 6).
(function () {
  'use strict';

  const RELATION_COLORS = {
    blocks: '#ff453a',
    references: '#0a84ff',
    ships: '#30d158',
    applies_lesson: '#bf5af2',
    claims: '#ff9f0a',
  };
  const DEFAULT_EDGE_COLOR = '#5a5a5e';

  const TYPE_RULES = [
    { type: 'gap', test: (id) => /^[A-Z][A-Z0-9_-]*-\d+$/.test(id) },
    { type: 'pr', test: (id) => /^#?\d+$/.test(id) || /\bpr\b/i.test(id) },
    { type: 'agent', test: (id) => /agent|curator|worker|session/i.test(id) },
    { type: 'lesson', test: (id) => /lesson/i.test(id) },
    { type: 'ambient_event', test: (id) => /ambient|event/i.test(id) },
  ];

  function inferType(id) {
    for (const rule of TYPE_RULES) {
      if (rule.test(id)) return rule.type;
    }
    return 'entity';
  }

  function edgeColor(relation) {
    return RELATION_COLORS[relation] || DEFAULT_EDGE_COLOR;
  }

  function edgeId(e) {
    return `${e.source}::${e.relation}::${e.target}`;
  }

  function toElements(graph) {
    const nodes = (graph.nodes || []).map((n) => ({
      data: { id: n.id, label: n.id, degree: n.degree, type: inferType(n.id) },
    }));
    const edges = (graph.edges || []).map((e) => ({
      data: {
        id: edgeId(e),
        source: e.source,
        target: e.target,
        relation: e.relation,
        weight: e.weight,
      },
    }));
    return nodes.concat(edges);
  }

  function pickLayout() {
    if (typeof window.cytoscapeCoseBilkent === 'function' && window.__cyRegisteredBilkent) {
      return { name: 'cose-bilkent', animate: false, randomize: false };
    }
    return { name: 'cose', animate: false };
  }

  function setStatus(text) {
    const el = document.getElementById('brain-status');
    if (el) el.textContent = text;
  }

  function renderDetail(detail) {
    const el = document.getElementById('brain-detail');
    if (!el) return;
    if (!detail) {
      el.innerHTML = '<p style="color:var(--muted)">No record found for this node.</p>';
      return;
    }
    const safe = (s) => String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
    const edgeLines = (detail.edges || [])
      .map((e) => `${safe(e.source)} —${safe(e.relation)}→ ${safe(e.target)} (w=${e.weight})`)
      .join('\n');
    el.innerHTML = `<h2>${safe(detail.id)}</h2><p>degree: ${detail.degree}</p><pre>${safe(edgeLines)}</pre>`;
  }

  async function fetchNodeDetail(id) {
    try {
      const resp = await fetch(`/api/brain/node/${encodeURIComponent(id)}`);
      if (!resp.ok) return null;
      return await resp.json();
    } catch (_e) {
      return null;
    }
  }

  function focusNode(cy, id) {
    const node = cy.getElementById(id);
    if (!node || node.empty()) return;
    const sub = node.closedNeighborhood();
    cy.elements().addClass('brain-faded');
    sub.removeClass('brain-faded');
    fetchNodeDetail(id).then(renderDetail);
  }

  function wireFilters(cy) {
    document.querySelectorAll('.brain-filter-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        const type = btn.getAttribute('data-type');
        const pressed = btn.getAttribute('aria-pressed') === 'true';
        btn.setAttribute('aria-pressed', String(!pressed));
        const nodes = cy.nodes(`[type = "${type}"]`);
        if (pressed) {
          nodes.addClass('brain-hidden');
        } else {
          nodes.removeClass('brain-hidden');
        }
      });
    });
  }

  function wireStream(cy) {
    if (typeof window.EventSource !== 'function') return;
    let es;
    try {
      es = new EventSource('/api/brain/graph/stream');
    } catch (_e) {
      return;
    }
    function ensureNode(id) {
      if (cy.getElementById(id).empty()) {
        cy.add({ data: { id, label: id, degree: 0, type: inferType(id) } });
      }
    }
    es.addEventListener('edge_add', (ev) => {
      try {
        const e = JSON.parse(ev.data);
        ensureNode(e.subject);
        ensureNode(e.object);
        const id = edgeId({ source: e.subject, relation: e.relation, target: e.object });
        if (cy.getElementById(id).empty()) {
          cy.add({ data: { id, source: e.subject, target: e.object, relation: e.relation, weight: 1 } });
        }
      } catch (_err) {
        /* malformed event — skip */
      }
    });
    es.addEventListener('edge_remove', (ev) => {
      try {
        const e = JSON.parse(ev.data);
        const id = edgeId({ source: e.subject, relation: e.relation, target: e.object });
        cy.remove(cy.getElementById(id));
      } catch (_err) {
        /* malformed event — skip */
      }
    });
  }

  async function init() {
    if (typeof window.cytoscape !== 'function') {
      setStatus('cytoscape failed to load');
      return;
    }
    if (typeof window.cytoscapeCoseBilkent === 'function') {
      try {
        window.cytoscape.use(window.cytoscapeCoseBilkent);
        window.__cyRegisteredBilkent = true;
      } catch (_e) {
        window.__cyRegisteredBilkent = false;
      }
    }

    let graph = { nodes: [], edges: [] };
    try {
      const resp = await fetch('/api/brain/graph.json');
      if (resp.ok) graph = await resp.json();
    } catch (_e) {
      // offline / no graph yet — render an empty canvas rather than erroring out.
    }

    const rootStyle = getComputedStyle(document.documentElement);
    const textColor = rootStyle.getPropertyValue('--text').trim();
    const accentColor = rootStyle.getPropertyValue('--accent').trim();

    const cy = window.cytoscape({
      container: document.getElementById('cy-container'),
      elements: toElements(graph),
      style: [
        {
          selector: 'node',
          style: {
            label: 'data(label)',
            'font-size': 9,
            color: textColor,
            'background-color': accentColor,
            width: 'mapData(degree, 0, 20, 10, 40)',
            height: 'mapData(degree, 0, 20, 10, 40)',
          },
        },
        {
          selector: 'edge',
          style: {
            width: 1.5,
            'line-color': (e) => edgeColor(e.data('relation')),
            'target-arrow-color': (e) => edgeColor(e.data('relation')),
            'target-arrow-shape': 'triangle',
            'curve-style': 'bezier',
            opacity: 0.8,
          },
        },
        { selector: '.brain-faded', style: { opacity: 0.15 } },
        { selector: '.brain-hidden', style: { display: 'none' } },
      ],
      layout: pickLayout(),
    });

    cy.on('tap', 'node', (ev) => focusNode(cy, ev.target.id()));
    cy.on('tap', (ev) => {
      if (ev.target === cy) {
        cy.elements().removeClass('brain-faded');
      }
    });

    wireFilters(cy);
    wireStream(cy);
    setStatus(`${graph.nodes.length} nodes · ${graph.edges.length} edges`);
    window.__chumpBrainCy = cy; // smoke-test / console inspection hook
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
