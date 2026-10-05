// EFFECTIVE-483 (EFFECTIVE-365 slice): PUBLISHER.md platform rules and
// boundaries, codified as typed config instead of prose. Consumed by the
// publisher chair (org/RUN/publication/roles/publisher.md) to decide which
// action is legal on which platform before drafting/approving/posting.
//
// "drive" (own the platform end-to-end) is only legal on platforms Chump
// actually owns the account for. Everywhere else, the fleet can draft and
// stage but must hand off ("fill_and_stop") for a human to actually post —
// per publisher.md's "the one irreversible click never automates" rule.

export type PublisherAction =
  | 'draft'
  | 'approve_queue'
  | 'drive'
  | 'fill_and_stop';

export interface PublisherPlatform {
  readonly id: string;
  readonly label: string;
  readonly owned: boolean;
  readonly allowedActions: readonly PublisherAction[];
}

const OWNED_PLATFORM_IDS = ['substack', 'jeffadkins.dev', 'upshiftai.dev'] as const;

const OWNED_ACTIONS: readonly PublisherAction[] = ['draft', 'approve_queue', 'drive'];
const FOREIGN_ACTIONS: readonly PublisherAction[] = ['draft', 'approve_queue', 'fill_and_stop'];

export const PUBLISHER_PLATFORMS: Readonly<Record<string, PublisherPlatform>> = {
  show_hn: {
    id: 'show_hn',
    label: 'Show HN',
    owned: false,
    allowedActions: FOREIGN_ACTIONS,
  },
  reddit: {
    id: 'reddit',
    label: 'Reddit',
    owned: false,
    allowedActions: FOREIGN_ACTIONS,
  },
  linkedin: {
    id: 'linkedin',
    label: 'LinkedIn',
    owned: false,
    allowedActions: FOREIGN_ACTIONS,
  },
  substack: {
    id: 'substack',
    label: 'Substack',
    owned: true,
    allowedActions: OWNED_ACTIONS,
  },
  'jeffadkins.dev': {
    id: 'jeffadkins.dev',
    label: "Jeff Adkins' site",
    owned: true,
    allowedActions: OWNED_ACTIONS,
  },
  'upshiftai.dev': {
    id: 'upshiftai.dev',
    label: 'UpshiftAI site',
    owned: true,
    allowedActions: OWNED_ACTIONS,
  },
};

/**
 * Throws unless `action` is legal on `platformId`. Enforces two layers:
 *   1. the platform must exist in PUBLISHER_PLATFORMS
 *   2. the action must be in that platform's allowedActions
 * "drive" additionally re-checks `owned` directly (AC 3) so a future
 * mis-edit of allowedActions can't silently grant drive on a foreign
 * platform — the ownership check is structural, not just data-driven.
 */
export function assertPlatformAction(platformId: string, action: PublisherAction): void {
  const platform = PUBLISHER_PLATFORMS[platformId];
  if (!platform) {
    throw new Error(`unknown publisher platform: "${platformId}"`);
  }
  if (action === 'drive' && !platform.owned) {
    throw new Error(
      `drive action is not allowed on non-owned platform "${platformId}" ` +
        `(owned platforms: ${OWNED_PLATFORM_IDS.join(', ')})`,
    );
  }
  if (!platform.allowedActions.includes(action)) {
    throw new Error(`platform "${platformId}" does not allow action "${action}"`);
  }
}
