// EFFECTIVE-1512: proves the Draft stage is wired into the EFFECTIVE-364
// approval queue — saving a draft enqueues it, the response carries the
// draft id/platform/status, and enqueue succeeds with a 200.
import assert from 'node:assert';
import { test } from 'node:test';
import { draftLaunchPost } from './draft.ts';
import { saveDraft } from './api.ts';
import { ApprovalQueue } from './queue.ts';
import { parseStyleRules } from './style.ts';

const RULES = parseStyleRules('## Banned phrases (growth-hack tone)\n\n- 10x\n');

const ARTIFACT = {
  title: 'Chump ships EFFECTIVE-1512',
  summary: 'Draft stage now enqueues into the approval queue.',
  receiptUrl: 'https://github.com/repairman29/chump/pull/9999',
};

test('saving a draft enqueues it in the EFFECTIVE-364 approval queue', () => {
  const queue = new ApprovalQueue();
  const draft = draftLaunchPost(ARTIFACT, 'show_hn', RULES);

  const response = saveDraft(queue, ARTIFACT.title, draft);

  // AC3: queue API returns 200 OK on successful enqueue.
  assert.strictEqual(response.status, 200);

  // AC2: queue entry carries draft id, platform, and current status.
  assert.ok(response.draft.id, 'response must carry a draft id');
  assert.strictEqual(response.draft.platformId, 'show_hn');
  assert.strictEqual(response.draft.status, 'pending_approval');

  // AC1: the draft is actually enqueued in the EFFECTIVE-364 queue, not
  // just echoed back — list() must find it by the returned id.
  const [queued] = queue.list();
  assert.strictEqual(queued.id, response.draft.id);
  assert.strictEqual(queued.platformId, 'show_hn');
  assert.strictEqual(queued.status, 'pending_approval');
  assert.strictEqual(queued.artifactTitle, ARTIFACT.title);
});

test('each saved draft gets a distinct queue entry', () => {
  const queue = new ApprovalQueue();
  const showHn = draftLaunchPost(ARTIFACT, 'show_hn', RULES);
  const reddit = draftLaunchPost(ARTIFACT, 'reddit', RULES);

  const r1 = saveDraft(queue, ARTIFACT.title, showHn);
  const r2 = saveDraft(queue, ARTIFACT.title, reddit);

  assert.notStrictEqual(r1.draft.id, r2.draft.id);
  assert.strictEqual(queue.list().length, 2);
});
