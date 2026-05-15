// <chump-ambient-viewer> — TOMBSTONE (INFRA-1332)
//
// This standalone file was the original PRODUCT-091 implementation.
// The component was reimplemented in app.js (INFRA-1198) with a richer
// feature set (connection indicator, drillable JSON, "↓ N new" pill,
// XSS-safe escaping). The duplicate customElements.define() call here
// caused a NotSupportedError on every cockpit/ambient view load.
//
// Fix (INFRA-1332): removed <script src="ambient-viewer.js"> from index.html
// and retired this file. Canonical definition: app.js ~line 4409.
//
// Unit tests: web/v2/tests/ambient-viewer.test.js (loads from app.js directly).
