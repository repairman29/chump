// INFRA-1559: JS unit test for the SSE filter-pill UI (ChumpAmbientViewer) and
// the bandit regret panel (ChumpBanditRegretPanel). Runs without a browser via
// minimal DOM/EventSource stubs, same pattern as ambient-viewer.test.js.
//
// Verifies:
//   - Adding a "kind=X" filter pill renders a pill tag in the DOM
//   - Adding a pill emits kind=sse_filter_applied telemetry via sendBeacon
//   - Synthetic routing_decision + routing_outcome events feed the regret
//     panel and produce a monotonically non-decreasing cumulative regret
//     series per arm

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

// ── Minimal DOM stubs (mirrors ambient-viewer.test.js) ──────────────────────
class FakeElement {
  constructor(tag = 'div') {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.firstChild = null;
    this.attributes = {};
    this.dataset = {};
    this.style = { display: '' };
    this._innerHTML = '';
    this._listeners = {};
    this.scrollTop = 0;
    this.clientHeight = 0;
    this.scrollHeight = 0;
    this.hidden = false;
    this.textContent = '';
    this.parent = null;
    this.className = '';
    this.title = '';
    this.value = '';
    this.classList = {
      _set: new Set(),
      toggle: (cls, on) => { if (on) this.classList._set.add(cls); else this.classList._set.delete(cls); },
      add: (cls) => this.classList._set.add(cls),
      contains: (cls) => this.classList._set.has(cls),
    };
  }
  set innerHTML(v) {
    this._innerHTML = v;
    this.children = parseChildren(v, this);
    this.firstChild = this.children[0] || null;
  }
  get innerHTML() { return this._innerHTML; }
  setAttribute(k, v) { this.attributes[k] = v; }
  getAttribute(k)    { return this.attributes[k]; }
  addEventListener(ev, fn) { (this._listeners[ev] = this._listeners[ev] || []).push(fn); }
  appendChild(c)     { c.parent = this; this.children.push(c); this.firstChild = this.children[0]; return c; }
  removeChild(c)     { this.children = this.children.filter(x => x !== c); this.firstChild = this.children[0] || null; }
  querySelector(sel) { return findFirst(this, sel); }
  querySelectorAll(sel) { const out = []; walk(this, (n) => { if (matchesSelector(n, sel)) out.push(n); }); return out; }
  dispatch(name, evt) { (this._listeners[name] || []).forEach(fn => fn(evt)); }
}

function matchesSelector(node, sel) {
  if (!node || !sel) return false;
  if (sel.startsWith('.')) {
    const cls = sel.slice(1);
    return (node.className && node.className.split(/\s+/).includes(cls)) || node.classList?.contains(cls);
  }
  return node.tagName === sel.toUpperCase();
}

function findFirst(root, sel) { let hit = null; walk(root, (n) => { if (!hit && matchesSelector(n, sel)) hit = n; }); return hit; }
function walk(node, fn) { fn(node); (node.children || []).forEach(c => walk(c, fn)); }

function parseChildren(html, parent) {
  const out = [];
  const tagRe = /<(\w+)([^>]*)>/g;
  let m;
  while ((m = tagRe.exec(html))) {
    const tag = m[1];
    const attrs = m[2];
    const el = new FakeElement(tag);
    el.parent = parent;
    const clsM = /class="([^"]+)"/.exec(attrs);
    if (clsM) el.className = clsM[1];
    const dataIdxM = /data-idx="([^"]+)"/.exec(attrs);
    if (dataIdxM) el.dataset.idx = dataIdxM[1];
    out.push(el);
  }
  return out;
}

// ── Global stubs ──
globalThis.HTMLElement = FakeElement;
globalThis.customElements = { define() {} };
globalThis.document = { createElement(tag) { return new FakeElement(tag); }, dispatchEvent() {} };
globalThis.window = {
  chumpPrefs: {
    _store: {},
    get(key, fallback) { return Object.prototype.hasOwnProperty.call(this._store, key) ? this._store[key] : fallback; },
    set(key, value) { this._store[key] = value; return true; },
  },
};
// Node 21+ ships a built-in read-only `navigator` global — patch sendBeacon
// onto it rather than reassigning (reassignment silently no-ops).
const beacons = [];
try {
  Object.defineProperty(globalThis.navigator, 'sendBeacon', {
    value: (url, body) => { beacons.push({ url, body }); return true; },
    configurable: true,
  });
} catch {
  globalThis.navigator = { sendBeacon: (url, body) => { beacons.push({ url, body }); return true; } };
}

const esRegistry = [];
class FakeEventSource {
  constructor(url) { this.url = url; this._handlers = {}; this.closed = false; esRegistry.push(this); }
  addEventListener(ev, fn) { this._handlers[ev] = fn; }
  close() { this.closed = true; }
  fire(ev, payload) {
    const fn = this._handlers[ev];
    if (fn) fn({ data: typeof payload === 'string' ? payload : JSON.stringify(payload) });
  }
}
globalThis.EventSource = FakeEventSource;

// ── Load component classes from app.js ──
function loadClass(appJs, startMarker, endMarker) {
  const startIdx = appJs.indexOf(startMarker);
  const endIdx = appJs.indexOf(endMarker);
  if (startIdx < 0 || endIdx < 0) {
    throw new Error(`could not locate class markers: ${startMarker}`);
  }
  const classSrc = appJs.slice(startIdx, endIdx + endMarker.length);
  const className = endMarker.match(/customElements\.define\('[^']+',\s*(\w+)\)/)[1];
  return (new Function(`${classSrc}\nreturn ${className};`))();
}

const appJs = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
const ChumpAmbientViewer = loadClass(
  appJs,
  '// ── <chump-ambient-viewer> (INFRA-1198)',
  "customElements.define('chump-ambient-viewer', ChumpAmbientViewer);"
);
const ChumpBanditRegretPanel = loadClass(
  appJs,
  '// ── <chump-bandit-regret-panel> (INFRA-1559)',
  "customElements.define('chump-bandit-regret-panel', ChumpBanditRegretPanel);"
);

// ── Tests ──
let passed = 0, failed = 0;
function test(name, fn) {
  try { fn(); console.log(`[unit] PASS: ${name}`); passed++; }
  catch (e) { console.error(`[unit] FAIL: ${name}\n  ${e.stack || e.message}`); failed++; }
}

test('adding a kind= filter pill renders a pill tag', () => {
  window.chumpPrefs._store = {};
  const c = new ChumpAmbientViewer();
  c.connectedCallback();
  const input = c.querySelector('.amb-pill-input');
  assert.ok(input, 'pill input exists');
  input.value = 'kind=pr_stuck';
  input.dispatch('keydown', { key: 'Enter', target: input });
  const pills = c.querySelectorAll('.amb-tag');
  assert.strictEqual(pills.length, 1, 'one pill rendered');
});

test('adding a filter pill emits kind=sse_filter_applied telemetry', () => {
  window.chumpPrefs._store = {};
  beacons.length = 0;
  const c = new ChumpAmbientViewer();
  c.connectedCallback();
  const input = c.querySelector('.amb-pill-input');
  input.value = 'gap=INFRA-1559';
  input.dispatch('keydown', { key: 'Enter', target: input });
  const hit = beacons.find(b => b.url === '/api/ambient/emit' && JSON.parse(b.body).kind === 'sse_filter_applied');
  assert.ok(hit, 'sse_filter_applied telemetry emitted');
  const parsed = JSON.parse(hit.body);
  assert.ok('filter_spec' in parsed && 'results_count' in parsed, 'telemetry carries filter_spec + results_count');
});

test('severity pill filters out non-matching kinds client-side', () => {
  window.chumpPrefs._store = {};
  const c = new ChumpAmbientViewer();
  c.connectedCallback();
  const input = c.querySelector('.amb-pill-input');
  input.value = 'severity=error';
  input.dispatch('keydown', { key: 'Enter', target: input });
  const es = esRegistry[esRegistry.length - 1];
  es.fire('ambient', { ts: '2026-08-27T00:00:00Z', kind: 'pwa_pref_changed' }); // -> severity info
  es.fire('ambient', { ts: '2026-08-27T00:00:01Z', kind: 'fleet_wedge' });      // -> severity error
  const list = c.querySelector('.amb-list');
  assert.strictEqual(list.children.length, 1, 'only the error-severity event rendered');
});

test('bandit regret panel: cumulative regret per arm is monotonically non-decreasing', () => {
  esRegistry.length = 0;
  const panel = new ChumpBanditRegretPanel();
  panel.connectedCallback();
  const es = esRegistry[esRegistry.length - 1];
  assert.ok(es.url.includes('kinds=routing_decision,routing_outcome'), 'subscribes to both routing kinds');

  es.fire('ambient', { ts: '2026-08-27T00:00:00Z', kind: 'routing_decision', gap_id: 'INFRA-1', arm: 'sonnet' });
  es.fire('ambient', { ts: '2026-08-27T00:00:01Z', kind: 'routing_outcome', gap_id: 'INFRA-1', arm: 'sonnet', reward: 0.6, optimal_reward: 1.0 });
  es.fire('ambient', { ts: '2026-08-27T00:00:02Z', kind: 'routing_decision', gap_id: 'INFRA-2', arm: 'haiku' });
  es.fire('ambient', { ts: '2026-08-27T00:00:03Z', kind: 'routing_outcome', gap_id: 'INFRA-2', arm: 'haiku', reward: 0.9, optimal_reward: 1.0 });
  es.fire('ambient', { ts: '2026-08-27T00:00:04Z', kind: 'routing_outcome', gap_id: 'INFRA-1', arm: 'sonnet', reward: 1.0, optimal_reward: 1.0 });

  const series = panel.regretSeries();
  assert.ok(series.sonnet && series.haiku, 'both arms present in the series');
  for (const arm of Object.keys(series)) {
    const values = series[arm];
    for (let i = 1; i < values.length; i++) {
      assert.ok(values[i] >= values[i - 1], `${arm} cumulative regret is non-decreasing (${values})`);
    }
  }
  assert.ok(series.sonnet[series.sonnet.length - 1] > 0, 'sonnet accrued nonzero regret from its first sub-optimal outcome');
});

console.log('');
console.log(`[unit] ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
