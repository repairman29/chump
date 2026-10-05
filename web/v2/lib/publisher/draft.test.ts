// EFFECTIVE-365: unit tests for the draft generator (stage 1).
import assert from 'node:assert';
import { test } from 'node:test';
import { draftLaunchPost, draftLaunchPosts, type ShippedArtifact } from './draft.ts';
import { parseStyleRules } from './style.ts';

const RULES = parseStyleRules(`
## Banned phrases (growth-hack tone)

- game changer
- 10x
- unlock
`);

// A real shipped artifact — EFFECTIVE-483/484 landed the platform + style
// modules this draft generator now builds on (PR #4250, #4382).
const ARTIFACT: ShippedArtifact = {
  title: 'Publisher co-pilot: platform rules + Jeff\'s-voice style loader',
  summary:
    "I shipped the first two slices of the publisher co-pilot: typed platform " +
    'rules (which platforms allow drafting vs. driving) and a style loader that ' +
    "enforces first-person voice and strips growth-hack phrases from drafts.",
  receiptUrl: 'https://github.com/repairman29/chump/pull/4382',
};

test('draftLaunchPost produces an in-voice, receipted draft for Show HN', () => {
  const draft = draftLaunchPost(ARTIFACT, 'show_hn', RULES);
  assert.strictEqual(draft.platformId, 'show_hn');
  assert.ok(draft.title?.startsWith('Show HN: '));
  assert.strictEqual(draft.firstPerson, true);
  assert.strictEqual(draft.honestReceipts, true);
  assert.strictEqual(draft.noGrowthHackTone, true);
  assert.deepStrictEqual(draft.violations, []);
  assert.ok(draft.body.includes(ARTIFACT.receiptUrl));
});

test('draftLaunchPost strips growth-hack phrases and still reports the violation', () => {
  const hyped: ShippedArtifact = {
    ...ARTIFACT,
    summary: 'I shipped a game changer today.',
  };
  const draft = draftLaunchPost(hyped, 'linkedin', RULES);
  assert.deepStrictEqual(draft.violations, ['game changer']);
  assert.ok(!/game changer/i.test(draft.body));
});

test('draftLaunchPost throws on an unknown platform (no silent fallback)', () => {
  assert.throws(() => draftLaunchPost(ARTIFACT, 'myspace', RULES), /unknown publisher platform/);
});

test('draftLaunchPosts drafts every platform PUBLISHER_PLATFORMS knows about', () => {
  const drafts = draftLaunchPosts(ARTIFACT, RULES);
  const ids = drafts.map((d) => d.platformId).sort();
  assert.deepStrictEqual(ids, [
    'jeffadkins.dev',
    'linkedin',
    'reddit',
    'show_hn',
    'substack',
    'upshiftai.dev',
  ]);
  for (const draft of drafts) {
    assert.strictEqual(draft.firstPerson, true, `${draft.platformId} draft should be first-person`);
    assert.strictEqual(draft.honestReceipts, true, `${draft.platformId} draft should carry a receipt`);
  }
});
