// EFFECTIVE-365: unit tests for the launch tracker (stage 4).
import assert from 'node:assert';
import { test } from 'node:test';
import { draftLaunchPost, type ShippedArtifact } from './draft.ts';
import { driveApprovedDraft } from './drive.ts';
import { ApprovalQueue } from './queue.ts';
import { parseStyleRules } from './style.ts';
import { LaunchTracker } from './track.ts';

const RULES = parseStyleRules('## Banned phrases (growth-hack tone)\n');
const ARTIFACT: ShippedArtifact = {
  title: 'Publisher co-pilot',
  summary: 'I shipped the publisher co-pilot end to end.',
  receiptUrl: 'https://github.com/repairman29/chump/pull/9999',
};

test('LaunchTracker.record logs what/where/when for a driven result', () => {
  const queue = new ApprovalQueue();
  const draft = draftLaunchPost(ARTIFACT, 'substack', RULES);
  const queued = queue.enqueue(ARTIFACT.title, draft);
  queue.approve(queued.id);
  const result = driveApprovedDraft(queued, true);

  const tracker = new LaunchTracker();
  tracker.record(result, '2026-09-08T00:00:00Z');

  const report = tracker.launchReport();
  assert.strictEqual(report.length, 1);
  assert.strictEqual(report[0].platformId, 'substack');
  assert.strictEqual(report[0].posted, true);
  assert.strictEqual(report[0].trackedAt, '2026-09-08T00:00:00Z');
});

test('LaunchTracker surfaces replies as pending until Jeff answers them himself', () => {
  const tracker = new LaunchTracker();
  tracker.surfaceReply({
    draftId: 'launch-1',
    platformId: 'show_hn',
    author: 'someuser',
    body: 'how does this compare to X?',
    receivedAt: '2026-09-08T01:00:00Z',
  });

  assert.strictEqual(tracker.pendingReplies().length, 1);

  tracker.markAnswered('launch-1', 'someuser');
  assert.strictEqual(tracker.pendingReplies().length, 0);
});

test('LaunchTracker.markAnswered throws when there is no matching pending reply', () => {
  const tracker = new LaunchTracker();
  assert.throws(() => tracker.markAnswered('launch-404', 'nobody'), /no pending reply/);
});
