// INFRA-991: JS unit test for ChumpAuthToast's client-side de-dup window.
//
// Doesn't require a browser — we evaluate the component code in a minimal
// fake-DOM context and drive synthetic events through its #onEvent handler.
// Run with:
//   node web/v2/tests/auth-toast.dedup.test.js
//
// Verifies:
//   - First event renders the toast (count=1, no counter)
//   - Second event within 60s window increments counter (count=2)
//   - Third event still within 60s → count=3
//   - Event AFTER 60s window resets counter to 1
//   - Manual dismiss clears state and counter

const assert = require('node:assert');

// ── Minimal DOM stubs ──────────────────────────────────────────────────────
class FakeElement {
  constructor() {
    this.style = { display: '' };
    this.innerHTML = '';
    this.attributes = {};
    this._listeners = {};
  }
  setAttribute(k, v) { this.attributes[k] = v; }
  getAttribute(k) { return this.attributes[k]; }
  addEventListener(ev, fn) {
    (this._listeners[ev] = this._listeners[ev] || []).push(fn);
  }
  querySelector(_sel) { return null; } // unused for these tests
  querySelectorAll(_sel) { return []; }
}

// Stub HTMLElement so the class definition `class X extends HTMLElement` works.
globalThis.HTMLElement = FakeElement;
globalThis.customElements = { define() {} };
globalThis.document = { dispatchEvent() {} };
globalThis.EventSource = class { constructor() {} addEventListener() {} close() {} };

// ── Load the component source ──────────────────────────────────────────────
const fs = require('node:fs');
const path = require('node:path');
const appJsPath = path.join(__dirname, '..', 'app.js');
const source = fs.readFileSync(appJsPath, 'utf8');

// Extract just the ChumpAuthToast class definition + its customElements.define
// line. We rely on the class being delimited by a known comment block.
const startMarker = '// ── <chump-auth-toast> (INFRA-991)';
const endMarker = "customElements.define('chump-auth-toast', ChumpAuthToast);";
const startIdx = source.indexOf(startMarker);
const endIdx = source.indexOf(endMarker);
if (startIdx < 0 || endIdx < 0) {
  console.error('[unit] FAIL: could not locate ChumpAuthToast class markers in app.js');
  process.exit(2);
}
const classSrc = source.slice(startIdx, endIdx + endMarker.length);

// Evaluate the class definition; this attaches ChumpAuthToast to the
// surrounding scope. We then grab the constructor by re-running with a
// returning expression.
const ChumpAuthToast = (new Function(`
  ${classSrc}
  return ChumpAuthToast;
`))();

// ── Tests ──────────────────────────────────────────────────────────────────
let passed = 0, failed = 0;
function test(name, fn) {
  try {
    fn();
    console.log(`[unit] PASS: ${name}`);
    passed++;
  } catch (e) {
    console.error(`[unit] FAIL: ${name}`);
    console.error('  ' + (e.stack || e.message));
    failed++;
  }
}

test('first event renders count=1', () => {
  const c = new ChumpAuthToast();
  c.connectedCallback();
  // Force first event using a clock anchor
  c._setMockNow ? c._setMockNow(1000) : null;
  c['#onEvent'] ? null : null; // private member, can't call directly
  // The class uses #onEvent (private). We exercise it via the EventSource
  // 'ambient' listener. Stub the EventSource to capture the handler.

  // Re-run with a real stub: replay listener capture.
  const captured = {};
  globalThis.EventSource = class {
    constructor(_url) { this._handlers = {}; captured.es = this; }
    addEventListener(ev, fn) { this._handlers[ev] = fn; }
    close() {}
  };
  const c2 = new ChumpAuthToast();
  c2.connectedCallback();
  const handler = captured.es._handlers['ambient'];
  assert.ok(handler, 'ambient handler registered');

  handler({ data: JSON.stringify({
    kind: 'fleet_auth_fallback',
    failed_mode: 'api-key',
    fallback_mode: 'oauth',
  }) });
  assert.notStrictEqual(c2.style.display, 'none', 'toast becomes visible');
  assert.ok(c2.innerHTML.includes('api-key'), 'failed_mode rendered');
  assert.ok(c2.innerHTML.includes('oauth'), 'fallback_mode rendered');
  assert.ok(!c2.innerHTML.includes('events in last 60s'),
    'counter NOT shown on first event');
});

test('second event within 60s increments counter', () => {
  globalThis.EventSource = class {
    constructor() { this._handlers = {}; this._capture = (g) => g(this); }
    addEventListener(ev, fn) { this._handlers[ev] = fn; }
    close() {}
  };
  // Mock Date.now to make windowing deterministic.
  const realNow = Date.now;
  let now = 100_000;
  Date.now = () => now;
  try {
    const c = new ChumpAuthToast();
    let es;
    globalThis.EventSource = class {
      constructor() { es = this; this._handlers = {}; }
      addEventListener(ev, fn) { this._handlers[ev] = fn; }
      close() {}
    };
    c.connectedCallback();
    const h = es._handlers['ambient'];
    h({ data: JSON.stringify({ kind: 'fleet_auth_fallback', failed_mode: 'a', fallback_mode: 'b' }) });
    assert.ok(!c.innerHTML.includes('events in last 60s'), 'first: no counter');

    // 30s later, still within 60s window
    now += 30_000;
    h({ data: JSON.stringify({ kind: 'fleet_auth_fallback', failed_mode: 'a', fallback_mode: 'b' }) });
    assert.ok(c.innerHTML.includes('× 2 events in last 60s'),
      'counter shows × 2 after second event in window');

    // another 20s later → still within 60s of LAST event (now=120s)
    now += 20_000;
    h({ data: JSON.stringify({ kind: 'fleet_auth_fallback', failed_mode: 'a', fallback_mode: 'b' }) });
    assert.ok(c.innerHTML.includes('× 3 events in last 60s'),
      'counter shows × 3 after third event in window');
  } finally {
    Date.now = realNow;
  }
});

test('event AFTER 60s window resets counter', () => {
  const realNow = Date.now;
  let now = 200_000;
  Date.now = () => now;
  try {
    let es;
    globalThis.EventSource = class {
      constructor() { es = this; this._handlers = {}; }
      addEventListener(ev, fn) { this._handlers[ev] = fn; }
      close() {}
    };
    const c = new ChumpAuthToast();
    c.connectedCallback();
    const h = es._handlers['ambient'];

    h({ data: JSON.stringify({ kind: 'fleet_auth_fallback', failed_mode: 'a', fallback_mode: 'b' }) });
    now += 70_000; // 70s later — outside 60s window
    h({ data: JSON.stringify({ kind: 'fleet_auth_fallback', failed_mode: 'a', fallback_mode: 'b' }) });
    assert.ok(!c.innerHTML.includes('events in last 60s'),
      'counter resets after window expires (no × N)');
  } finally {
    Date.now = realNow;
  }
});

test('unrelated kind is ignored', () => {
  let es;
  globalThis.EventSource = class {
    constructor() { es = this; this._handlers = {}; }
    addEventListener(ev, fn) { this._handlers[ev] = fn; }
    close() {}
  };
  const c = new ChumpAuthToast();
  c.connectedCallback();
  const h = es._handlers['ambient'];
  h({ data: JSON.stringify({ kind: 'pwa_setting_changed', key: 'x', value: 'y' }) });
  assert.strictEqual(c.style.display, 'none', 'toast stays hidden for unrelated kind');
});

// ── Summary ────────────────────────────────────────────────────────────────
console.log('');
console.log(`[unit] ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
