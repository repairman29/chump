// EFFECTIVE-484: unit tests for the STYLE.md loader + style checker.
import assert from 'node:assert';
import { test } from 'node:test';
import {
  parseStyleRules,
  checkStyle,
  checkStyleAgainstFile,
  loadStyleRules,
} from './loader.ts';

const SAMPLE_STYLE_MD = `# STYLE.md — sample

## Rules

- **first_person** — write as "I" / "we", not a brand voice.
- **honest_receipts** — every results claim ships with a receipt.
- **no_growth_hack** — no growth-hack tone.

## Why

Prose that the parser should ignore.
`;

test('parseStyleRules extracts all three rules from the sample STYLE.md', () => {
  const rules = parseStyleRules(SAMPLE_STYLE_MD);
  assert.strictEqual(rules.length, 3);
  assert.deepStrictEqual(
    rules.map((r) => r.id),
    ['first_person', 'honest_receipts', 'no_growth_hack'],
  );
});

test('loadStyleRules reads and parses the real content/STYLE.md', () => {
  const rules = loadStyleRules('../../../../content/STYLE.md');
  assert.ok(rules.length >= 3);
  assert.ok(rules.some((r) => r.id === 'first_person'));
  assert.ok(rules.some((r) => r.id === 'honest_receipts'));
  assert.ok(rules.some((r) => r.id === 'no_growth_hack'));
});

test('checkStyle passes first-person text with a receipt and no growth-hack phrases', () => {
  const rules = parseStyleRules(SAMPLE_STYLE_MD);
  const text = 'I shipped the publisher chair today — see PR #4250 for the diff.';
  const result = checkStyle(text, rules);
  assert.strictEqual(result.passed, true);
  assert.deepStrictEqual(result.violations, []);
});

test('checkStyle flags third-person brand voice', () => {
  const rules = parseStyleRules(SAMPLE_STYLE_MD);
  const text = 'The team shipped the publisher chair today — see PR #4250.';
  const result = checkStyle(text, rules);
  assert.strictEqual(result.passed, false);
  assert.ok(result.violations.some((v) => v.rule === 'first_person'));
});

test('checkStyle flags a results claim with no receipt', () => {
  const rules = parseStyleRules(SAMPLE_STYLE_MD);
  const text = 'I grew signups massively this week.';
  const result = checkStyle(text, rules);
  assert.strictEqual(result.passed, false);
  assert.ok(result.violations.some((v) => v.rule === 'honest_receipts'));
});

test('checkStyle flags growth-hack phrases', () => {
  const rules = parseStyleRules(SAMPLE_STYLE_MD);
  const text = 'I shipped a game-changing, revolutionary 10x feature — see #4250.';
  const result = checkStyle(text, rules);
  assert.strictEqual(result.passed, false);
  assert.ok(result.violations.some((v) => v.rule === 'no_growth_hack'));
});

test('checkStyle can report multiple violations in one pass', () => {
  const rules = parseStyleRules(SAMPLE_STYLE_MD);
  const text = 'The team crushed it with a revolutionary launch.';
  const result = checkStyle(text, rules);
  assert.strictEqual(result.passed, false);
  assert.ok(result.violations.length >= 2);
});

test('checkStyleAgainstFile applies the real content/STYLE.md end to end', () => {
  const clean = checkStyleAgainstFile(
    'I shipped the style loader — see PR #4252 for the diff.',
    '../../../../content/STYLE.md',
  );
  assert.strictEqual(clean.passed, true);

  const dirty = checkStyleAgainstFile(
    'Our revolutionary team is thrilled to announce a game-changing update.',
    '../../../../content/STYLE.md',
  );
  assert.strictEqual(dirty.passed, false);
});
