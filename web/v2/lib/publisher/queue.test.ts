// EFFECTIVE-365: unit tests for the approval queue (stage 2) and the
// end-to-end proof that a real shipped artifact produces approval-ready,
// in-voice, gated drafts (AC 2).
import assert from 'node:assert';
import { test } from 'node:test';
import { draftLaunchPosts, type ShippedArtifact } from './draft.ts';
import { parseStyleRules } from './style.ts';
import { ApprovalQueue } from './queue.ts';

const RULES = parseStyleRules(`
## Banned phrases (growth-hack tone)

- game changer
- 10x
- unlock
`);

test('enqueue starts a draft pending_approval; nothing is sendable yet', () => {
  const queue = new ApprovalQueue();
  const [draft] = draftLaunchPosts(
    { title: 'x', summary: 'I did a thing. See https://example.com/pr/1', receiptUrl: 'https://example.com/pr/1' },
    RULES,
  );
  const queued = queue.enqueue('x', draft);
  assert.strictEqual(queued.status, 'pending_approval');
  assert.deepStrictEqual(queue.sendable(), []);
});

test('approve moves a draft to sendable; reject does not', () => {
  const queue = new ApprovalQueue();
  const [a, b] = draftLaunchPosts(
    { title: 'x', summary: 'I did a thing. See https://example.com/pr/1', receiptUrl: 'https://example.com/pr/1' },
    RULES,
  );
  const approved = queue.enqueue('x', a);
  const rejected = queue.enqueue('x', b);

  queue.approve(approved.id);
  queue.reject(rejected.id, 'wrong framing for this platform');

  const sendable = queue.sendable();
  assert.strictEqual(sendable.length, 1);
  assert.strictEqual(sendable[0].id, approved.id);
});

test('approve/reject refuse to re-decide an already-decided draft', () => {
  const queue = new ApprovalQueue();
  const [draft] = draftLaunchPosts(
    { title: 'x', summary: 'I did a thing. See https://example.com/pr/1', receiptUrl: 'https://example.com/pr/1' },
    RULES,
  );
  const queued = queue.enqueue('x', draft);
  queue.approve(queued.id);
  assert.throws(() => queue.approve(queued.id), /already approved/);
  assert.throws(() => queue.reject(queued.id, 'why not'), /already approved/);
});

test('approve can carry Jeff\'s edited body without changing the drafted original', () => {
  const queue = new ApprovalQueue();
  const [draft] = draftLaunchPosts(
    { title: 'x', summary: 'I did a thing. See https://example.com/pr/1', receiptUrl: 'https://example.com/pr/1' },
    RULES,
  );
  const queued = queue.enqueue('x', draft);
  const approved = queue.approve(queued.id, 'Edited: I did a much better thing. https://example.com/pr/1');
  assert.strictEqual(approved.approvedBody, 'Edited: I did a much better thing. https://example.com/pr/1');
  assert.notStrictEqual(approved.approvedBody, draft.body);
});

// --- End-to-end proof (AC 2): a real shipped artifact -> approval-ready
// launch drafts across Show HN / Reddit / LinkedIn, gated on explicit
// approval, never auto-sent. ---
test('proof: a shipped artifact yields approval-ready, in-voice, gated drafts on Show HN / Reddit / LinkedIn', () => {
  const artifact: ShippedArtifact = {
    title: "Publisher co-pilot: platform rules + Jeff's-voice style loader",
    summary:
      'I shipped the first two slices of the publisher co-pilot: typed platform ' +
      'rules and a style loader that enforces first-person voice and strips ' +
      'growth-hack phrases from drafts.',
    receiptUrl: 'https://github.com/repairman29/chump/pull/4382',
  };

  const queue = new ApprovalQueue();
  const drafts = draftLaunchPosts(artifact, RULES);
  const queued = drafts.map((d) => queue.enqueue(artifact.title, d));

  // Nothing is sendable before Jeff acts — the gate holds by default.
  assert.deepStrictEqual(queue.sendable(), []);

  for (const platformId of ['show_hn', 'reddit', 'linkedin']) {
    const item = queued.find((q) => q.platformId === platformId);
    assert.ok(item, `expected a queued draft for ${platformId}`);
    assert.strictEqual(item.status, 'pending_approval');
    assert.strictEqual(item.firstPerson, true, `${platformId} draft must be first-person`);
    assert.strictEqual(item.honestReceipts, true, `${platformId} draft must carry a receipt`);
    assert.strictEqual(item.noGrowthHackTone, true, `${platformId} draft must be growth-hack-free`);
  }

  // Jeff blesses only the Show HN and Reddit drafts; LinkedIn stays parked.
  const showHn = queued.find((q) => q.platformId === 'show_hn')!;
  const reddit = queued.find((q) => q.platformId === 'reddit')!;
  queue.approve(showHn.id);
  queue.approve(reddit.id);

  const sendable = queue.sendable().map((q) => q.platformId).sort();
  assert.deepStrictEqual(sendable, ['reddit', 'show_hn']);
});
