// EFFECTIVE-1512 (EFFECTIVE-365 slice): wires the Draft stage (draft.ts)
// into the EFFECTIVE-364 approval queue (queue.ts). Saving a drafted
// launch post enqueues it — nothing is postable until it passes through
// the queue's explicit approve() (stage 2). This module owns the
// "save a draft" entry point so callers don't reach into ApprovalQueue
// directly and skip the queue.

import type { LaunchDraft } from './draft.ts';
import { ApprovalQueue, type QueueStatus } from './queue.ts';

export interface SaveDraftResponse {
  readonly status: 200;
  readonly draft: {
    readonly id: string;
    readonly platformId: string;
    readonly status: QueueStatus;
  };
}

/**
 * Saves a drafted launch post by enqueuing it in the EFFECTIVE-364
 * approval queue. Returns 200 with the queue entry's draft id, platform,
 * and current status on successful enqueue (per EFFECTIVE-1512 AC).
 */
export function saveDraft(
  queue: ApprovalQueue,
  artifactTitle: string,
  draft: LaunchDraft,
): SaveDraftResponse {
  const queued = queue.enqueue(artifactTitle, draft);
  return {
    status: 200,
    draft: {
      id: queued.id,
      platformId: queued.platformId,
      status: queued.status,
    },
  };
}
