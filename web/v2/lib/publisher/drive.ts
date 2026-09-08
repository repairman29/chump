// EFFECTIVE-365 slice: stage 3 (Drive) of the publisher co-pilot.
//
// Takes an approved draft (queue.ts) and produces the stage-3 action per
// PUBLISHER.md: on an owned platform, "drive" may complete on an explicit
// go from Jeff (this module still never calls a platform API — it returns
// a typed, sendable payload for whatever posts it); on every other
// platform it fills-and-stops, returning hand-off text for Jeff to paste
// himself. LinkedIn sessions are never automated, full stop — that ban is
// enforced structurally in platforms.ts (drive requires owned:true) and
// re-asserted here so a future foreign-platform addition can't silently
// bypass it by calling drive() directly.

import { assertPlatformAction, PUBLISHER_PLATFORMS } from './platforms.ts';
import type { QueuedDraft } from './queue.ts';

export interface DriveResult {
  readonly draftId: string;
  readonly platformId: string;
  /** 'drive' = ready to post on Jeff's explicit go; 'fill_and_stop' = hand off text. */
  readonly mode: 'drive' | 'fill_and_stop';
  readonly title?: string;
  readonly body: string;
  /** Only set when mode is 'drive' — Jeff's explicit go was given. */
  readonly posted: boolean;
}

/**
 * Advances one approved draft to stage 3. Throws if the draft isn't
 * approved yet (stage 2's gate), or if the platform doesn't allow either
 * `drive` or `fill_and_stop` (platforms.ts is the single source of truth).
 *
 * `go` is Jeff's explicit go-ahead for owned platforms — without it, even
 * an owned-platform draft stops at "ready to post, not yet posted" so the
 * irreversible click always requires a deliberate call, never a default.
 */
export function driveApprovedDraft(draft: QueuedDraft, go: boolean = false): DriveResult {
  if (draft.status !== 'approved') {
    throw new Error(`cannot drive "${draft.id}": not approved (status: ${draft.status})`);
  }

  const platform = PUBLISHER_PLATFORMS[draft.platformId];
  if (!platform) {
    throw new Error(`unknown publisher platform: "${draft.platformId}"`);
  }

  const body = draft.approvedBody ?? draft.body;
  const mode: 'drive' | 'fill_and_stop' = platform.owned ? 'drive' : 'fill_and_stop';

  assertPlatformAction(draft.platformId, mode);

  return {
    draftId: draft.id,
    platformId: draft.platformId,
    mode,
    title: draft.title,
    body,
    posted: mode === 'drive' && go,
  };
}

/** Drives every sendable draft from the queue. Owned platforms only post with `go: true`. */
export function driveApprovedDrafts(
  drafts: readonly QueuedDraft[],
  go: boolean = false,
): readonly DriveResult[] {
  return drafts.map((draft) => driveApprovedDraft(draft, go));
}
