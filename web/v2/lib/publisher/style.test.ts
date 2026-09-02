// EFFECTIVE-484: unit tests for the STYLE.md loader + draft-text transform.
import assert from 'node:assert';
import { test } from 'node:test';
import { applyStyle, parseStyleRules, stripBannedPhrases } from './style.ts';

const SAMPLE_STYLE_MD = `# STYLE.md — sample

## Rules

- First person.
- Honest receipts.
- No growth-hack tone.

## Banned phrases (growth-hack tone)

- game changer
- 10x
- unlock

## Not a rules section

- this bullet should not be picked up
`;

test('parseStyleRules extracts only the Banned phrases bullet list', () => {
  const rules = parseStyleRules(SAMPLE_STYLE_MD);
  assert.deepStrictEqual(rules.bannedPhrases, ['game changer', '10x', 'unlock']);
});

test('stripBannedPhrases removes matches case-insensitively and reports violations', () => {
  const rules = parseStyleRules(SAMPLE_STYLE_MD);
  const { text, violations } = stripBannedPhrases(
    'This is a GAME CHANGER that will unlock 10x growth.',
    rules,
  );
  assert.deepStrictEqual(violations, ['game changer', '10x', 'unlock']);
  assert.ok(!/game changer/i.test(text));
  assert.ok(!/unlock/i.test(text));
  assert.ok(!/10x/i.test(text));
});

test('applyStyle passes first person, honest receipts, and no-growth-hack-tone on a clean draft', () => {
  const rules = parseStyleRules(SAMPLE_STYLE_MD);
  const draft =
    "I shipped PR #484 today. It's a small change, but it closes the gap " +
    'described in EFFECTIVE-365 — see the commit for the diff.';

  const result = applyStyle(draft, rules);

  assert.strictEqual(result.firstPerson, true);
  assert.strictEqual(result.honestReceipts, true);
  assert.strictEqual(result.noGrowthHackTone, true);
  assert.deepStrictEqual(result.violations, []);
});

test('applyStyle strips growth-hack phrases from a draft and still reports the violation', () => {
  const rules = parseStyleRules(SAMPLE_STYLE_MD);
  const draft = 'I shipped a game changer today — see PR #484 for the receipts.';

  const result = applyStyle(draft, rules);

  assert.strictEqual(result.firstPerson, true);
  assert.strictEqual(result.honestReceipts, true);
  assert.strictEqual(result.noGrowthHackTone, true);
  assert.deepStrictEqual(result.violations, ['game changer']);
  assert.ok(!/game changer/i.test(result.text));
});

test('applyStyle flags a draft with no first-person voice and no receipts', () => {
  const rules = parseStyleRules(SAMPLE_STYLE_MD);
  const draft = 'The team shipped a revolutionary new feature this week.';

  const result = applyStyle(draft, rules);

  assert.strictEqual(result.firstPerson, false);
  assert.strictEqual(result.honestReceipts, false);
});
