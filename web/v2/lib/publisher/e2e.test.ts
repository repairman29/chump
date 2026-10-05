// EFFECTIVE-365: end-to-end proof of AC #2 — a shipped artifact walked
// through all four PUBLISHER.md stages (Draft -> Approve -> Drive ->
// Track) without ever auto-posting to a foreign platform or bypassing
// Jeff's explicit approval/go.
import assert from 'node:assert';
import { test } from 'node:test';
import { draftLaunchPosts, type ShippedArtifact } from './draft.ts';
import { driveApprovedDrafts } from './drive.ts';
import { ApprovalQueue } from './queue.ts';
import { parseStyleRules } from './style.ts';
import { LaunchTracker } from './track.ts';

const RULES = parseStyleRules(`
## Banned phrases (growth-hack tone)

- game changer
- 10x
- unlock
`);

// A real shipped artifact: a giveaway/product launch.
const GIVEAWAY: ShippedArtifact = {
  title: 'Free week of the Chump fleet for the first 10 sign-ups',
  summary:
    "I'm giving away a free week of the Chump fleet to the first 10 people who " +
    'sign up — no strings, just want honest feedback on whether it holds up outside my own repos.',
  receiptUrl: 'https://github.com/repairman29/chump/pull/4600',
};

test('a shipped giveaway gets approval-ready, in-voice launch drafts gated on Jeffs explicit send', () => {
  // Stage 1: Draft.
  const drafts = draftLaunchPosts(GIVEAWAY, RULES);
  const showHn = drafts.find((d) => d.platformId === 'show_hn')!;
  const reddit = drafts.find((d) => d.platformId === 'reddit')!;
  const linkedin = drafts.find((d) => d.platformId === 'linkedin')!;
  const substack = drafts.find((d) => d.platformId === 'substack')!;

  for (const draft of [showHn, reddit, linkedin, substack]) {
    assert.strictEqual(draft.firstPerson, true, `${draft.platformId} must be in Jeff's voice`);
    assert.strictEqual(draft.honestReceipts, true, `${draft.platformId} must carry a receipt`);
    assert.strictEqual(draft.noGrowthHackTone, true, `${draft.platformId} must be growth-hack-free`);
  }
  assert.ok(showHn.title?.startsWith('Show HN: '));

  // Stage 2: Approve — nothing proceeds without Jeff's explicit bless.
  const queue = new ApprovalQueue();
  const queued = drafts.map((d) => queue.enqueue(GIVEAWAY.title, d));
  assert.deepStrictEqual(queue.sendable(), []); // nothing sendable pre-approval

  for (const item of queued) queue.approve(item.id);
  assert.strictEqual(queue.sendable().length, drafts.length);

  // Stage 3: Drive — foreign platforms (Show HN, Reddit, LinkedIn) fill-and-stop;
  // only owned platforms (Substack et al.) may post, and only with an explicit go.
  const driven = driveApprovedDrafts(queue.sendable(), true);
  const byPlatform = Object.fromEntries(driven.map((d) => [d.platformId, d]));

  assert.strictEqual(byPlatform.show_hn.mode, 'fill_and_stop');
  assert.strictEqual(byPlatform.show_hn.posted, false);
  assert.strictEqual(byPlatform.reddit.mode, 'fill_and_stop');
  assert.strictEqual(byPlatform.reddit.posted, false);
  assert.strictEqual(byPlatform.linkedin.mode, 'fill_and_stop', 'LinkedIn must never be driven');
  assert.strictEqual(byPlatform.linkedin.posted, false, 'LinkedIn must never auto-post');
  assert.strictEqual(byPlatform.substack.mode, 'drive');
  assert.strictEqual(byPlatform.substack.posted, true);

  // Without an explicit go, even the owned platform stays unposted.
  const noGo = driveApprovedDrafts(queue.sendable(), false);
  assert.ok(noGo.every((d) => d.posted === false));

  // Stage 4: Track — log what/where/when, surface a reply for Jeff to answer himself.
  const tracker = new LaunchTracker();
  for (const result of driven) tracker.record(result, '2026-09-08T12:00:00Z');
  assert.strictEqual(tracker.launchReport().length, drafts.length);

  tracker.surfaceReply({
    draftId: byPlatform.substack.draftId,
    platformId: 'substack',
    author: 'a_reader',
    body: 'signed up, excited to try it',
    receivedAt: '2026-09-08T13:00:00Z',
  });
  assert.strictEqual(tracker.pendingReplies().length, 1, 'reply must surface for Jeff, not auto-answer');
});
