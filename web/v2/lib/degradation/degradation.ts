// EFFECTIVE-1181 (slice of EFFECTIVE-370): generic honest-degradation
// framework.
//
// The anti-beast-mode.dev rule, generically: when a bucket (API quota,
// backend dependency, feature) is blocked or quota-exhausted, callers get a
// truthful fallback response instead of a dead endpoint or silent failure.
// Existing error-handling paths opt in via a feature flag (AC 3) rather
// than being switched over silently.

export type BucketState = 'blocked' | 'quota_exhausted';

export interface DegradedResult {
  readonly degraded: true;
  readonly bucketId: string;
  readonly message: string;
}

export interface HealthyResult {
  readonly degraded: false;
  readonly bucketId: string;
  readonly message: null;
}

export type DegradationResult = DegradedResult | HealthyResult;

/** Tracks per-bucket health state. One instance per process/surface. */
export class DegradationRegistry {
  private readonly blocked = new Map<string, BucketState>();
  private enabled: boolean;

  constructor(opts: { enabled?: boolean } = {}) {
    this.enabled = opts.enabled ?? false;
  }

  setEnabled(enabled: boolean): void {
    this.enabled = enabled;
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  markBlocked(bucketId: string, state: BucketState = 'blocked'): void {
    this.blocked.set(bucketId, state);
  }

  markHealthy(bucketId: string): void {
    this.blocked.delete(bucketId);
  }

  isBlocked(bucketId: string): boolean {
    return this.blocked.has(bucketId);
  }

  /**
   * AC 1/2: when the flag is on and `bucketId` is blocked or
   * quota-exhausted, returns a truthful fallback result carrying
   * `fallbackMessage` instead of letting the caller hit a dead endpoint.
   * Otherwise returns a healthy result so the caller proceeds with its
   * normal path.
   */
  handleDegradedState(bucketId: string, fallbackMessage: string): DegradationResult {
    if (this.enabled && this.blocked.has(bucketId)) {
      return { degraded: true, bucketId, message: fallbackMessage };
    }
    return { degraded: false, bucketId, message: null };
  }
}

/** Shared default instance for callers that don't need isolated state. */
export const defaultRegistry = new DegradationRegistry();

/** AC 1: module-level convenience wrapper over the default registry. */
export function handleDegradedState(bucketId: string, fallbackMessage: string): DegradationResult {
  return defaultRegistry.handleDegradedState(bucketId, fallbackMessage);
}
