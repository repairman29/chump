// EFFECTIVE-483: typed codification of org/RUN/publication/roles/publisher.md's
// platform rules — which platforms the Publisher chair may draft/approve/drive
// vs. only fill-and-stop / hand-off on. See PUBLISHER.md (EFFECTIVE-365) for
// the full co-pilot spec this config feeds.

export type PublisherAction =
  | 'draft'
  | 'approve_queue'
  | 'drive'
  | 'fill_and_stop';

export interface PublisherPlatform {
  id: string;
  /** true only for surfaces Jeff owns outright: substack, jeffadkins.dev, upshiftai.dev */
  owned: boolean;
  allowedActions: PublisherAction[];
}

const OWNED_DRIVE_PLATFORMS = ['substack', 'jeffadkins.dev', 'upshiftai.dev'] as const;

export const PUBLISHER_PLATFORMS: Record<string, PublisherPlatform> = {
  show_hn: {
    id: 'show_hn',
    owned: false,
    allowedActions: ['draft', 'approve_queue', 'fill_and_stop'],
  },
  reddit: {
    id: 'reddit',
    owned: false,
    allowedActions: ['draft', 'approve_queue', 'fill_and_stop'],
  },
  linkedin: {
    id: 'linkedin',
    owned: false,
    // NEVER automate LinkedIn sessions (EFFECTIVE-365 hard constraint) —
    // fill-and-stop / hand-off text only, never drive.
    allowedActions: ['draft', 'approve_queue', 'fill_and_stop'],
  },
  substack: {
    id: 'substack',
    owned: true,
    allowedActions: ['draft', 'approve_queue', 'drive'],
  },
  'jeffadkins.dev': {
    id: 'jeffadkins.dev',
    owned: true,
    allowedActions: ['draft', 'approve_queue', 'drive'],
  },
  'upshiftai.dev': {
    id: 'upshiftai.dev',
    owned: true,
    allowedActions: ['draft', 'approve_queue', 'drive'],
  },
};

/**
 * Throws if `platformId` is unknown, if `action` isn't in that platform's
 * allowed-actions list, or if `action` is "drive" on a platform Jeff doesn't
 * own (only substack / jeffadkins.dev / upshiftai.dev may be driven).
 */
export function assertPlatformAction(platformId: string, action: PublisherAction): void {
  const platform = PUBLISHER_PLATFORMS[platformId];
  if (!platform) {
    throw new Error(`Unknown publisher platform: "${platformId}"`);
  }
  if (action === 'drive' && !platform.owned) {
    throw new Error(
      `Refusing "drive" on non-owned platform "${platformId}" — ` +
        `only ${OWNED_DRIVE_PLATFORMS.join(', ')} may be driven`,
    );
  }
  if (!platform.allowedActions.includes(action)) {
    throw new Error(`Platform "${platformId}" does not allow action "${action}"`);
  }
}
