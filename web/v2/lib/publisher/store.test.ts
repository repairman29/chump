// EFFECTIVE-1508 (EFFECTIVE-365 slice): CRUD + persistence proof for LaunchDraftStore.
import assert from 'node:assert';
import { test } from 'node:test';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LaunchDraftStore } from './store.ts';

function freshStorePath(): string {
  const dir = mkdtempSync(join(tmpdir(), 'launch-draft-store-'));
  return join(dir, 'drafts.json');
}

test('create persists a record with platform, title, body, status, and timestamps', () => {
  const store = new LaunchDraftStore(freshStorePath());

  const record = store.create(
    { platform: 'show_hn', title: 'Show HN: Foo', body: 'body text' },
    '2026-10-03T00:00:00Z',
  );

  assert.strictEqual(record.platform, 'show_hn');
  assert.strictEqual(record.title, 'Show HN: Foo');
  assert.strictEqual(record.body, 'body text');
  assert.strictEqual(record.status, 'draft');
  assert.strictEqual(record.createdAt, '2026-10-03T00:00:00Z');
  assert.strictEqual(record.updatedAt, '2026-10-03T00:00:00Z');
});

test('read: a record survives a reload from disk, not just in-memory', () => {
  const path = freshStorePath();
  const store = new LaunchDraftStore(path);
  const record = store.create({ platform: 'reddit', body: 'hello' }, '2026-10-03T00:00:00Z');

  const reloaded = new LaunchDraftStore(path);
  assert.deepStrictEqual(reloaded.get(record.id), record);
});

test('update changes body/status and bumps updatedAt, leaving createdAt untouched', () => {
  const store = new LaunchDraftStore(freshStorePath());
  const record = store.create({ platform: 'substack', body: 'v1' }, '2026-10-03T00:00:00Z');

  const updated = store.update(
    record.id,
    { body: 'v2', status: 'pending_approval' },
    '2026-10-03T01:00:00Z',
  );

  assert.strictEqual(updated.body, 'v2');
  assert.strictEqual(updated.status, 'pending_approval');
  assert.strictEqual(updated.createdAt, '2026-10-03T00:00:00Z');
  assert.strictEqual(updated.updatedAt, '2026-10-03T01:00:00Z');
});

test('list filters by status', () => {
  const store = new LaunchDraftStore(freshStorePath());
  store.create({ platform: 'show_hn', body: 'a' }, '2026-10-03T00:00:00Z');
  const approved = store.create({ platform: 'reddit', body: 'b' }, '2026-10-03T00:00:00Z');
  store.update(approved.id, { status: 'approved' }, '2026-10-03T00:30:00Z');

  assert.strictEqual(store.list().length, 2);
  assert.strictEqual(store.list('approved').length, 1);
  assert.strictEqual(store.list('draft').length, 1);
});

test('delete removes a record; get returns undefined and update/delete throw after', () => {
  const store = new LaunchDraftStore(freshStorePath());
  const record = store.create({ platform: 'linkedin', body: 'x' }, '2026-10-03T00:00:00Z');

  store.delete(record.id);

  assert.strictEqual(store.get(record.id), undefined);
  assert.throws(() => store.update(record.id, { body: 'y' }, '2026-10-03T00:00:00Z'));
  assert.throws(() => store.delete(record.id));
});
