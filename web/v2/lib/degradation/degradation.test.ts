// EFFECTIVE-1181: unit tests for the generic honest-degradation framework.
import assert from 'node:assert';
import { test } from 'node:test';
import { DegradationRegistry, handleDegradedState, defaultRegistry } from './degradation.ts';

test('flag off: healthy result even when bucket is blocked', () => {
  const reg = new DegradationRegistry({ enabled: false });
  reg.markBlocked('supabase-leaderboard');
  const result = reg.handleDegradedState('supabase-leaderboard', 'scores are napping');
  assert.strictEqual(result.degraded, false);
  assert.strictEqual(result.message, null);
});

test('flag on + bucket blocked: returns the truthful fallback message', () => {
  const reg = new DegradationRegistry({ enabled: true });
  reg.markBlocked('supabase-leaderboard');
  const result = reg.handleDegradedState('supabase-leaderboard', 'scores are napping');
  assert.strictEqual(result.degraded, true);
  assert.strictEqual(result.bucketId, 'supabase-leaderboard');
  assert.strictEqual(result.message, 'scores are napping');
});

test('flag on + quota-exhausted bucket: still degrades honestly', () => {
  const reg = new DegradationRegistry({ enabled: true });
  reg.markBlocked('upshift-ai-explain', 'quota_exhausted');
  const result = reg.handleDegradedState('upshift-ai-explain', 'AI explain is out of credits for now');
  assert.strictEqual(result.degraded, true);
  assert.strictEqual(result.message, 'AI explain is out of credits for now');
});

test('flag on + healthy bucket: no dead-endpoint substitution, caller proceeds', () => {
  const reg = new DegradationRegistry({ enabled: true });
  const result = reg.handleDegradedState('olive-kroger', 'list-keeping only for now');
  assert.strictEqual(result.degraded, false);
  assert.strictEqual(result.message, null);
});

test('markHealthy clears a previously blocked bucket', () => {
  const reg = new DegradationRegistry({ enabled: true });
  reg.markBlocked('bucket-a');
  assert.strictEqual(reg.isBlocked('bucket-a'), true);
  reg.markHealthy('bucket-a');
  assert.strictEqual(reg.isBlocked('bucket-a'), false);
  const result = reg.handleDegradedState('bucket-a', 'fallback');
  assert.strictEqual(result.degraded, false);
});

test('module-level handleDegradedState uses the shared default registry', () => {
  defaultRegistry.setEnabled(true);
  defaultRegistry.markBlocked('shared-bucket');
  const result = handleDegradedState('shared-bucket', 'shared fallback');
  assert.strictEqual(result.degraded, true);
  assert.strictEqual(result.message, 'shared fallback');
  // Reset so this test file stays order-independent.
  defaultRegistry.markHealthy('shared-bucket');
  defaultRegistry.setEnabled(false);
});
