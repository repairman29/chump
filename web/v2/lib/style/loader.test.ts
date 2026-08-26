// EFFECTIVE-484: unit tests for the STYLE.md loader + applyStyle transform.
import assert from 'node:assert';
import { test } from 'node:test';
import {
  parseStyleGuide,
  applyStyle,
  assertFirstPerson,
  assertNoGrowthHackTone,
  assertHonestReceipts,
  loadStyleGuide,
} from './loader.ts';

const SAMPLE_STYLE_MD = `# STYLE.md sample

## No growth-hack tone

| Banned word / phrase |
|---|
| synergy |
| revolutionary |

## First-person substitutions

| From | To |
|---|---|
| we | I |
| our | my |
`;

test('parseStyleGuide extracts banned words and substitutions from markdown tables', () => {
  const rules = parseStyleGuide(SAMPLE_STYLE_MD);
  assert.deepStrictEqual([...rules.bannedWords], ['synergy', 'revolutionary']);
  assert.strictEqual(rules.substitutions.get('we'), 'I');
  assert.strictEqual(rules.substitutions.get('our'), 'my');
});

test('applyStyle rewrites company pronouns to first person', () => {
  const rules = parseStyleGuide(SAMPLE_STYLE_MD);
  const out = applyStyle('We shipped our best release yet.', rules);
  assert.strictEqual(out, "I shipped my best release yet.");
});

test('applyStyle strips growth-hack ban-list words', () => {
  const rules = parseStyleGuide(SAMPLE_STYLE_MD);
  const out = applyStyle('This is a revolutionary synergy of ideas.', rules);
  assert.ok(!/revolutionary/i.test(out));
  assert.ok(!/synergy/i.test(out));
});

test('transformed text passes first-person, no-growth-hack assertions', () => {
  const rules = parseStyleGuide(SAMPLE_STYLE_MD);
  const draft = 'We built a revolutionary tool with our own hands. See PR #4252.';
  const out = applyStyle(draft, rules);
  assert.doesNotThrow(() => assertFirstPerson(out));
  assert.doesNotThrow(() => assertNoGrowthHackTone(out, rules));
  assert.doesNotThrow(() => assertHonestReceipts(out));
});

test('assertFirstPerson throws on untransformed company voice', () => {
  assert.throws(() => assertFirstPerson('We shipped this together.'), /not in first person/);
});

test('assertNoGrowthHackTone throws when a banned word survives', () => {
  const rules = parseStyleGuide(SAMPLE_STYLE_MD);
  assert.throws(
    () => assertNoGrowthHackTone('A truly revolutionary release.', rules),
    /growth-hack tone/,
  );
});

test('assertHonestReceipts throws when no checkable receipt is present', () => {
  assert.throws(() => assertHonestReceipts('I shipped something great soon.'), /no checkable receipt/);
  assert.doesNotThrow(() => assertHonestReceipts('I shipped it, see PR #4252.'));
});

test('loadStyleGuide reads the real content/STYLE.md and parses non-empty rules', () => {
  const rules = loadStyleGuide('../../../../content/STYLE.md');
  assert.ok(rules.bannedWords.length > 0);
  assert.ok(rules.substitutions.size > 0);
});
