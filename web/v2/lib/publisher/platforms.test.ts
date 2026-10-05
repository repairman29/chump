// EFFECTIVE-483: unit tests for the PUBLISHER_PLATFORMS typed config.
import assert from 'node:assert';
import { test } from 'node:test';
import { PUBLISHER_PLATFORMS, assertPlatformAction } from './platforms.ts';

const OWNED = ['substack', 'jeffadkins.dev', 'upshiftai.dev'];
const NON_OWNED = ['show_hn', 'reddit', 'linkedin'];

test('PUBLISHER_PLATFORMS has an entry for every required platform', () => {
  for (const id of [...NON_OWNED, ...OWNED]) {
    assert.ok(PUBLISHER_PLATFORMS[id], `missing platform config for ${id}`);
  }
});

test('each entry specifies allowed actions including draft + approve_queue', () => {
  for (const platform of Object.values(PUBLISHER_PLATFORMS)) {
    assert.ok(Array.isArray(platform.allowedActions));
    assert.ok(platform.allowedActions.includes('draft'));
    assert.ok(platform.allowedActions.includes('approve_queue'));
  }
});

test('owned platforms allow drive, non-owned platforms allow fill_and_stop instead', () => {
  for (const id of OWNED) {
    assert.ok(PUBLISHER_PLATFORMS[id].owned);
    assert.ok(PUBLISHER_PLATFORMS[id].allowedActions.includes('drive'));
    assert.ok(!PUBLISHER_PLATFORMS[id].allowedActions.includes('fill_and_stop'));
  }
  for (const id of NON_OWNED) {
    assert.ok(!PUBLISHER_PLATFORMS[id].owned);
    assert.ok(PUBLISHER_PLATFORMS[id].allowedActions.includes('fill_and_stop'));
    assert.ok(!PUBLISHER_PLATFORMS[id].allowedActions.includes('drive'));
  }
});

test('assertPlatformAction allows drive only on owned platforms', () => {
  for (const id of OWNED) {
    assert.doesNotThrow(() => assertPlatformAction(id, 'drive'));
  }
  for (const id of NON_OWNED) {
    assert.throws(() => assertPlatformAction(id, 'drive'), /not allowed on non-owned platform/);
  }
});

test('assertPlatformAction throws on an unknown platform', () => {
  assert.throws(() => assertPlatformAction('myspace', 'draft'), /unknown publisher platform/);
});

test('assertPlatformAction throws on an action not in the platform allowlist', () => {
  assert.throws(
    () => assertPlatformAction('substack', 'fill_and_stop'),
    /does not allow action/,
  );
  assert.throws(() => assertPlatformAction('reddit', 'drive'), /non-owned platform/);
});
