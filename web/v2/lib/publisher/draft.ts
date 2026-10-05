// EFFECTIVE-365 slice: stage 1 (Draft) of the publisher co-pilot.
//
// Turns a shipped artifact into per-platform launch drafts, using
// platforms.ts (EFFECTIVE-483) to decide which platforms are legal to
// draft for and style.ts (EFFECTIVE-484) to enforce Jeff's voice on the
// resulting text. This module only drafts — it never posts. Nothing here
// calls a platform API; the output is a plain object destined for the
// approval queue (queue.ts).

import { assertPlatformAction, PUBLISHER_PLATFORMS } from './platforms.ts';
import { applyStyle, type StyleRules } from './style.ts';

/** A shipped, audited artifact the co-pilot is announcing. */
export interface ShippedArtifact {
  readonly title: string;
  readonly summary: string;
  /** Something a reader can go verify: a PR URL, commit, or receipts link. */
  readonly receiptUrl: string;
}

export interface LaunchDraft {
  readonly platformId: string;
  readonly title?: string;
  readonly body: string;
  readonly firstPerson: boolean;
  readonly honestReceipts: boolean;
  readonly noGrowthHackTone: boolean;
  readonly violations: readonly string[];
}

type PlatformFraming = (artifact: ShippedArtifact) => { title?: string; body: string };

const FRAMINGS: Readonly<Record<string, PlatformFraming>> = {
  show_hn: (a) => ({
    title: `Show HN: ${a.title}`,
    body: `${a.summary}\n\nReceipts: ${a.receiptUrl}`,
  }),
  reddit: (a) => ({
    title: a.title,
    body: `${a.summary}\n\nI shipped this myself — receipts here: ${a.receiptUrl}`,
  }),
  linkedin: (a) => ({
    body: `${a.title}\n\n${a.summary}\n\nReceipts: ${a.receiptUrl}`,
  }),
  substack: (a) => ({
    title: a.title,
    body: `${a.summary}\n\nAs always, the receipts: ${a.receiptUrl}`,
  }),
  'jeffadkins.dev': (a) => ({
    title: a.title,
    body: `${a.summary}\n\nReceipts: ${a.receiptUrl}`,
  }),
  'upshiftai.dev': (a) => ({
    title: a.title,
    body: `${a.summary}\n\nReceipts: ${a.receiptUrl}`,
  }),
};

/**
 * Drafts a launch post for `platformId`. Throws if the platform is unknown
 * or doesn't allow the `draft` action (platforms.ts is the single source of
 * truth for that). Applies STYLE.md's rules to the framed text so a draft
 * that fails voice/receipts checks is visibly flagged, not silently posted.
 */
export function draftLaunchPost(
  artifact: ShippedArtifact,
  platformId: string,
  rules: StyleRules,
): LaunchDraft {
  assertPlatformAction(platformId, 'draft');

  const framing = FRAMINGS[platformId];
  if (!framing) {
    throw new Error(`no draft framing registered for platform "${platformId}"`);
  }

  const framed = framing(artifact);
  const styled = applyStyle(framed.body, rules);

  return {
    platformId,
    title: framed.title,
    body: styled.text,
    firstPerson: styled.firstPerson,
    honestReceipts: styled.honestReceipts,
    noGrowthHackTone: styled.noGrowthHackTone,
    violations: styled.violations,
  };
}

/** Drafts the artifact for every platform that allows `draft` (i.e. all of them today). */
export function draftLaunchPosts(
  artifact: ShippedArtifact,
  rules: StyleRules,
): readonly LaunchDraft[] {
  return Object.keys(PUBLISHER_PLATFORMS).map((platformId) =>
    draftLaunchPost(artifact, platformId, rules),
  );
}
