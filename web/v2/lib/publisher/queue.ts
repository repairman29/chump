// EFFECTIVE-365 slice: stage 2 (Approve) of the publisher co-pilot.
//
// The queue Jeff reads/edits/blesses. Nothing a draft produces (draft.ts)
// is postable until it passes through here with an explicit approve() —
// this is PUBLISHER.md's gate: "captain-approved-and-posted". The queue
// itself never posts; it only tracks status. Posting (stage 3, Drive) is
// out of scope for this module and, per platforms.ts, is only ever legal
// on owned platforms — foreign platforms stop at fill_and_stop.

import type { LaunchDraft } from './draft.ts';

export type QueueStatus = 'pending_approval' | 'approved' | 'rejected';

export interface QueuedDraft extends LaunchDraft {
  readonly id: string;
  readonly artifactTitle: string;
  status: QueueStatus;
  /** Set on approve() if Jeff edited the body before blessing it. */
  approvedBody?: string;
  rejectionReason?: string;
}

let nextId = 1;

function freshId(): string {
  return `launch-${nextId++}`;
}

/** In-memory approval queue. One instance per publish run. */
export class ApprovalQueue {
  private readonly items = new Map<string, QueuedDraft>();

  enqueue(artifactTitle: string, draft: LaunchDraft): QueuedDraft {
    const queued: QueuedDraft = {
      ...draft,
      id: freshId(),
      artifactTitle,
      status: 'pending_approval',
    };
    this.items.set(queued.id, queued);
    return queued;
  }

  /** Jeff blesses a draft, optionally with edits. Throws if already decided. */
  approve(id: string, editedBody?: string): QueuedDraft {
    const item = this.require(id);
    if (item.status !== 'pending_approval') {
      throw new Error(`cannot approve "${id}": already ${item.status}`);
    }
    item.status = 'approved';
    if (editedBody !== undefined) item.approvedBody = editedBody;
    return item;
  }

  /** Jeff kills a draft. Throws if already decided. */
  reject(id: string, reason: string): QueuedDraft {
    const item = this.require(id);
    if (item.status !== 'pending_approval') {
      throw new Error(`cannot reject "${id}": already ${item.status}`);
    }
    item.status = 'rejected';
    item.rejectionReason = reason;
    return item;
  }

  list(status?: QueueStatus): readonly QueuedDraft[] {
    const all = [...this.items.values()];
    return status ? all.filter((item) => item.status === status) : all;
  }

  /** Drafts cleared for stage 3 (Drive/hand-off). Nothing else may proceed. */
  sendable(): readonly QueuedDraft[] {
    return this.list('approved');
  }

  private require(id: string): QueuedDraft {
    const item = this.items.get(id);
    if (!item) throw new Error(`no queued draft with id "${id}"`);
    return item;
  }
}
