#!/usr/bin/env node
/**
 * Run the same UI self-tests as the PWA Settings button (SSE parser, etc.).
 */
const path = require('path');
const root = path.join(__dirname, '..');
require(path.join(root, 'web', 'sse-event-parser.js'));
const { runChumpUiSelfTests } = require(path.join(root, 'web', 'ui-selftests.js'));
const result = runChumpUiSelfTests();
for (const line of result.lines) console.log(line);
if (!result.ok) {
  console.error('UI self-tests failed:', result.failed);
  process.exit(1);
}
console.log('UI self-tests: all passed (' + result.lines.length + ' checks)');
