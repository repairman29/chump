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

  test('POST /api/tasks + GET pending returns array', async ({ request }) => {
    const ts = Date.now();
    const p = await request.post('/api/tasks', {
      data: { title: `e2e-pending-${ts}`, assignee: 'chump', priority: 1 },
    });
    expect(p.ok()).toBeTruthy();
    const g = await request.get('/api/tasks?status=pending');
    expect(g.ok()).toBeTruthy();
    const arr = await g.json();
    expect(Array.isArray(arr)).toBeTruthy();
    expect(arr.length).toBeGreaterThan(0);
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
