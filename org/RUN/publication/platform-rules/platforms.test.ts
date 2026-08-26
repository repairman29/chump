import assert from 'node:assert';
import { PUBLISHER_PLATFORMS, assertPlatformAction } from './platforms.ts';

const OWNED_DRIVE = ['substack', 'jeffadkins.dev', 'upshiftai.dev'];
const HAND_OFF_ONLY = ['show_hn', 'reddit', 'linkedin'];

// AC1: all six platforms present
for (const id of [...OWNED_DRIVE, ...HAND_OFF_ONLY]) {
  assert.ok(PUBLISHER_PLATFORMS[id], `expected PUBLISHER_PLATFORMS to have "${id}"`);
}
assert.strictEqual(Object.keys(PUBLISHER_PLATFORMS).length, 6);

// AC2: every platform allows draft + approve_queue, plus exactly one of drive/fill_and_stop
for (const id of Object.keys(PUBLISHER_PLATFORMS)) {
  const { allowedActions } = PUBLISHER_PLATFORMS[id];
  assert.ok(allowedActions.includes('draft'), `${id} must allow draft`);
  assert.ok(allowedActions.includes('approve_queue'), `${id} must allow approve_queue`);
  const hasDrive = allowedActions.includes('drive');
  const hasFillAndStop = allowedActions.includes('fill_and_stop');
  assert.ok(hasDrive !== hasFillAndStop, `${id} must allow exactly one of drive/fill_and_stop`);
}

// AC3: drive succeeds only for the three owned platforms
for (const id of OWNED_DRIVE) {
  assert.doesNotThrow(() => assertPlatformAction(id, 'drive'));
}
for (const id of HAND_OFF_ONLY) {
  assert.throws(() => assertPlatformAction(id, 'drive'), /Refusing "drive" on non-owned platform/);
}

// AC4: invalid platform / invalid action both throw
assert.throws(() => assertPlatformAction('myspace', 'draft'), /Unknown publisher platform/);
assert.throws(
  () => assertPlatformAction('linkedin', 'drive'),
  /Refusing "drive" on non-owned platform/,
);

console.log('platforms.test.ts: all assertions passed');
