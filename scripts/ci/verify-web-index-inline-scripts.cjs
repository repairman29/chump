#!/usr/bin/env node
/**
 * Fail CI if web/index.html inline <script> bodies contain a JavaScript syntax error.
 * A single parse error prevents the entire bundle from running (dead menus, inputs, etc.).
 */
const fs = require('fs');
const path = require('path');

const indexPath = path.join(__dirname, '..', '..', 'web', 'index.html');
const html = fs.readFileSync(indexPath, 'utf8');

function extractInlineScripts(html) {
  const out = [];
  const re = /<script(\s[^>]*)?>/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    const attrs = m[1] || '';
    if (/\bsrc=/i.test(attrs)) continue;
    if (/\btype\s*=\s*["']?module/i.test(attrs)) continue;
    const start = re.lastIndex;
    const end = html.indexOf('</script>', start);
    if (end === -1) break;
    out.push({ attrs: attrs.trim(), body: html.slice(start, end).trim() });
    re.lastIndex = end + '</script>'.length;
  }
  return out;
}

const blocks = extractInlineScripts(html);
if (blocks.length === 0) {
  console.error('No inline <script> blocks found in web/index.html');
  process.exit(1);
}

let n = 0;
for (const { attrs, body } of blocks) {
  try {
    new Function(body);
  } catch (e) {
    console.error('SyntaxError in web/index.html inline script:', e.message);
    if (attrs) console.error('Script tag attrs:', attrs);
    process.exit(1);
  }
  n += 1;
}
console.log(`OK: ${n} inline script block(s) in web/index.html parse as JavaScript`);
