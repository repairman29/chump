// EFFECTIVE-365: unit tests for the drive step (stage 3).
import assert from 'node:assert';
import { test } from 'node:test';
import { draftLaunchPost, type ShippedArtifact } from './draft.ts';
import { driveApprovedDraft, driveApprovedDrafts } from './drive.ts';
import { ApprovalQueue } from './queue.ts';
import { parseStyleRules } from './style.ts';

const RULES = parseStyleRules(`
## Banned phrases (growth-hack tone)

- game changer
`);

const ARTIFACT: ShippedArtifact = {
  title: 'Publisher co-pilot',
  summary: 'I shipped the publisher co-pilot end to end.',
  receiptUrl: 'https://github.com/repairman29/chump/pull/9999',
};

test('driveApprovedDraft on an owned platform stays unposted without explicit go', () => {
  const queue = new ApprovalQueue();
  const draft = draftLaunchPost(ARTIFACT, 'substack', RULES);
  const queued = queue.enqueue(ARTIFACT.title, draft);
  queue.approve(queued.id);

  const result = driveApprovedDraft(queued);
  assert.strictEqual(result.mode, 'drive');
  assert.strictEqual(result.posted, false);
});

test('driveApprovedDraft on an owned platform posts only with explicit go', () => {
  const queue = new ApprovalQueue();
  const draft = draftLaunchPost(ARTIFACT, 'jeffadkins.dev', RULES);
  const queued = queue.enqueue(ARTIFACT.title, draft);
  queue.approve(queued.id);

  const result = driveApprovedDraft(queued, true);
  assert.strictEqual(result.mode, 'drive');
  assert.strictEqual(result.posted, true);
});

test('driveApprovedDraft on a foreign platform always fills-and-stops, never posts', () => {
  const queue = new ApprovalQueue();
  const draft = draftLaunchPost(ARTIFACT, 'linkedin', RULES);
  const queued = queue.enqueue(ARTIFACT.title, draft);
  queue.approve(queued.id);

  const result = driveApprovedDraft(queued, true);
  assert.strictEqual(result.mode, 'fill_and_stop');
  assert.strictEqual(result.posted, false);
});

test('driveApprovedDraft throws on a not-yet-approved draft', () => {
  const queue = new ApprovalQueue();
  const draft = draftLaunchPost(ARTIFACT, 'show_hn', RULES);
  const queued = queue.enqueue(ARTIFACT.title, draft);

  assert.throws(() => driveApprovedDraft(queued), /not approved/);
});

test('driveApprovedDrafts drives every sendable draft in the queue', () => {
  const queue = new ApprovalQueue();
  for (const platformId of ['show_hn', 'substack']) {
    const draft = draftLaunchPost(ARTIFACT, platformId, RULES);
    const queued = queue.enqueue(ARTIFACT.title, draft);
    queue.approve(queued.id);
  }

  const results = driveApprovedDrafts(queue.sendable(), true);
  const byPlatform = Object.fromEntries(results.map((r) => [r.platformId, r]));
  assert.strictEqual(byPlatform.show_hn.mode, 'fill_and_stop');
  assert.strictEqual(byPlatform.show_hn.posted, false);
  assert.strictEqual(byPlatform.substack.mode, 'drive');
  assert.strictEqual(byPlatform.substack.posted, true);
});
