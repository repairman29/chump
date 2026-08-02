import { test, expect } from '@playwright/test';

/**
 * Extra API coverage for the daily-driver checklist (no browser UI).
 * Run via ./scripts/ci/run-ui-e2e.sh (sets CHUMP_E2E_BASE_URL; probes 3847 / 3000 / bound-port marker).
 */

test.describe('Daily driver — API', () => {
  test('POST /api/sessions twice; list includes new IDs', async ({ request }) => {
    const c1 = await request.post('/api/sessions', { data: {} });
    expect(c1.ok()).toBeTruthy();
    const j1 = await c1.json();
    expect(j1.session_id).toBeTruthy();
    const c2 = await request.post('/api/sessions', { data: {} });
    expect(c2.ok()).toBeTruthy();
    const j2 = await c2.json();
    const list = await request.get('/api/sessions');
    expect(list.ok()).toBeTruthy();
    const arr = await list.json();
    expect(Array.isArray(arr)).toBeTruthy();
    const ids = new Set(arr.map((s: { id: string }) => s.id));
    expect(ids.has(j1.session_id)).toBeTruthy();
    expect(ids.has(j2.session_id)).toBeTruthy();
  });

  test('POST /api/tasks; THE created task appears in the open list', async ({ request }) => {
    // Depth pass 2026-08-02: the old form of this test queried
    // ?status=pending — but 'pending' is not a task status
    // (open|blocked|in_progress|done|abandoned), and task_list treats unknown
    // statuses as "all active", so the filter was meaningless. Worse, it only
    // asserted the array was non-empty: any pre-existing task made it green,
    // and the created task was never looked up. Assert the actual row, by id.
    const title = `e2e-open-${Date.now()}`;
    const p = await request.post('/api/tasks', {
      data: { title, assignee: 'chump', priority: 1 },
    });
    expect(p.ok()).toBeTruthy();
    const { id } = await p.json();
    expect(id, 'create returns the new task id').toBeTruthy();
    const g = await request.get('/api/tasks?status=open');
    expect(g.ok()).toBeTruthy();
    const arr = await g.json();
    const mine = arr.find((t: { id: number; title: string }) => t.id === id);
    expect(mine, `created task ${id} present in the open list`).toBeTruthy();
    expect(mine.title).toBe(title);
  });

  test('POST /api/chat empty message -> 400', async ({ request }) => {
    const r = await request.post('/api/chat', {
      data: { message: '', session_id: 'e2e-empty' },
    });
    expect(r.status()).toBe(400);
  });

  test('POST /api/chat message over CHUMP_MAX_MESSAGE_LEN -> 400', async ({ request }) => {
    const huge = 'y'.repeat(20_000);
    const r = await request.post('/api/chat', {
      data: { message: huge, session_id: 'e2e-huge' },
    });
    expect(r.status()).toBe(400);
  });

  test('/task via API persists user + assistant rows', async ({ request }) => {
    const cr = await request.post('/api/sessions', { data: {} });
    expect(cr.ok()).toBeTruthy();
    const { session_id: sid } = await cr.json();
    const title = `api-task-${Date.now()}`;
    const chat = await request.post('/api/chat', {
      data: { message: `/task ${title}`, session_id: sid },
      timeout: 600_000,
    });
    expect(chat.ok()).toBeTruthy();
    const text = await chat.text();
    expect(text).toMatch(/created task|Created task/i);
    const msg = await request.get(`/api/sessions/${sid}/messages`);
    expect(msg.ok()).toBeTruthy();
    const rows = await msg.json();
    expect(Array.isArray(rows)).toBeTruthy();
    expect(rows.length).toBeGreaterThanOrEqual(2);
    const roles = rows.map((m: { role: string }) => m.role);
    expect(roles).toContain('user');
    expect(roles).toContain('assistant');
  });

  test('parallel /task chat requests complete (stress)', async ({ request }) => {
    const n = 3;
    const tasks = [];
    for (let i = 0; i < n; i++) {
      const sid = `stress-${Date.now()}-${i}`;
      const title = `stress-${i}-${Date.now()}`;
      tasks.push(
        request
          .post('/api/chat', {
            data: { message: `/task ${title}`, session_id: sid },
            timeout: 600_000,
          })
          .then(async (r) => {
            expect(r.ok()).toBeTruthy();
            const t = await r.text();
            expect(t).toMatch(/created task|Created task/i);
          }),
      );
    }
    await Promise.all(tasks);
  });
});
