// EFFECTIVE-1508 (EFFECTIVE-365 slice): persistence for launch drafts.
//
// Gives stage 1 (Draft, draft.ts) a durable home before a draft reaches the
// in-memory approval queue (queue.ts) — a launch draft survives a process
// restart between being drafted and being queued. Backed by a JSON file
// acting as the database; callers supply timestamps so tests stay
// deterministic (same convention as track.ts).

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { dirname } from 'node:path';

export type LaunchDraftStatus = 'draft' | 'pending_approval' | 'approved' | 'rejected';

export interface LaunchDraftRecord {
  readonly id: string;
  readonly platform: string;
  title?: string;
  body: string;
  status: LaunchDraftStatus;
  readonly createdAt: string;
  updatedAt: string;
}

export type NewLaunchDraftRecord = Pick<LaunchDraftRecord, 'platform' | 'body'> &
  Partial<Pick<LaunchDraftRecord, 'title' | 'status'>>;

export type LaunchDraftPatch = Partial<Pick<LaunchDraftRecord, 'title' | 'body' | 'status'>>;

/** File-backed store for LaunchDraftRecord — the database for stage 1 (Draft). */
export class LaunchDraftStore {
  private readonly path: string;
  private readonly records: Map<string, LaunchDraftRecord>;

  constructor(path: string) {
    this.path = path;
    this.records = this.load();
  }

  create(input: NewLaunchDraftRecord, at: string): LaunchDraftRecord {
    const record: LaunchDraftRecord = {
      id: randomUUID(),
      platform: input.platform,
      ...(input.title !== undefined ? { title: input.title } : {}),
      body: input.body,
      status: input.status ?? 'draft',
      createdAt: at,
      updatedAt: at,
    };
    this.records.set(record.id, record);
    this.persist();
    return record;
  }

  get(id: string): LaunchDraftRecord | undefined {
    return this.records.get(id);
  }

  list(status?: LaunchDraftStatus): readonly LaunchDraftRecord[] {
    const all = [...this.records.values()];
    return status ? all.filter((r) => r.status === status) : all;
  }

  update(id: string, patch: LaunchDraftPatch, at: string): LaunchDraftRecord {
    const record = this.require(id);
    const updated: LaunchDraftRecord = { ...record, ...patch, updatedAt: at };
    this.records.set(id, updated);
    this.persist();
    return updated;
  }

  delete(id: string): void {
    this.require(id);
    this.records.delete(id);
    this.persist();
  }

  private load(): Map<string, LaunchDraftRecord> {
    if (!existsSync(this.path)) return new Map();
    const raw = readFileSync(this.path, 'utf8').trim();
    const parsed = raw ? (JSON.parse(raw) as LaunchDraftRecord[]) : [];
    return new Map(parsed.map((r) => [r.id, r]));
  }

  private persist(): void {
    mkdirSync(dirname(this.path), { recursive: true });
    writeFileSync(this.path, JSON.stringify([...this.records.values()], null, 2));
  }

  private require(id: string): LaunchDraftRecord {
    const record = this.records.get(id);
    if (!record) throw new Error(`no launch draft with id "${id}"`);
    return record;
  }
}
