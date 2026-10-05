// EFFECTIVE-484 (EFFECTIVE-365 slice): loads content/STYLE.md's rules and
// applies them to draft text before it enters the approval queue.
//
// This is the enforcement half of PUBLISHER.md's "drafts in Jeff's voice"
// requirement — platforms.ts (EFFECTIVE-483) decides *where* a draft can
// go, this decides whether the draft's *text* is actually in-voice.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

export interface StyleRules {
  readonly bannedPhrases: readonly string[];
}

export interface StyleCheckResult {
  readonly text: string;
  readonly firstPerson: boolean;
  readonly honestReceipts: boolean;
  readonly noGrowthHackTone: boolean;
  readonly violations: readonly string[];
}

const FIRST_PERSON_RE = /\b(I|I'm|I've|I'll|I'd|my|me)\b/i;

// A "receipt" is something a reader can go verify: a PR/gap/commit
// reference, a bare URL, or an explicit "receipts:" callout.
const RECEIPTS_RE = /(#\d+|\b[0-9a-f]{7,40}\b|https?:\/\/\S+|\breceipts?:)/i;

/**
 * Parses the "## Banned phrases" bullet list out of a STYLE.md document.
 * Only that section is machine-readable today (EFFECTIVE-484 slice) — the
 * "## Rules" section stays prose for a human editor.
 */
export function parseStyleRules(styleMd: string): StyleRules {
  const lines = styleMd.split('\n');
  const bannedPhrases: string[] = [];
  let inBannedSection = false;

  for (const line of lines) {
    if (/^##\s+Banned phrases/i.test(line)) {
      inBannedSection = true;
      continue;
    }
    if (inBannedSection) {
      if (/^##\s+/.test(line)) break; // next section ends the list
      const match = line.match(/^-\s+(.+)$/);
      if (match) bannedPhrases.push(match[1].trim());
    }
  }

  return { bannedPhrases };
}

/** Reads and parses content/STYLE.md, resolved relative to the repo root. */
export function loadStyleRules(styleMdPath?: string): StyleRules {
  const path = styleMdPath ?? defaultStyleMdPath();
  return parseStyleRules(readFileSync(path, 'utf8'));
}

function defaultStyleMdPath(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  // web/v2/lib/publisher -> repo root is 4 levels up.
  return resolve(here, '..', '..', '..', '..', 'content', 'STYLE.md');
}

/**
 * Strips any banned phrase (case-insensitive) out of `text`, collapsing
 * the resulting double-spaces. Returns the transformed text plus the list
 * of phrases that were found and removed.
 */
export function stripBannedPhrases(
  text: string,
  rules: StyleRules,
): { text: string; violations: string[] } {
  let result = text;
  const violations: string[] = [];

  for (const phrase of rules.bannedPhrases) {
    const re = new RegExp(escapeRegExp(phrase), 'gi');
    if (re.test(result)) {
      violations.push(phrase);
      result = result.replace(re, '').replace(/\s{2,}/g, ' ').trim();
    }
  }

  return { text: result, violations };
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Applies STYLE.md's rules to a draft: strips growth-hack phrases, then
 * checks the result for first person voice and honest receipts. Does NOT
 * invent a first-person voice or a receipt if the draft lacks one — those
 * are drafting failures the approval queue (PUBLISHER.md stage 2) should
 * catch, not something the style loader can fabricate.
 */
export function applyStyle(text: string, rules: StyleRules): StyleCheckResult {
  const { text: stripped, violations } = stripBannedPhrases(text, rules);

  return {
    text: stripped,
    firstPerson: FIRST_PERSON_RE.test(stripped),
    honestReceipts: RECEIPTS_RE.test(stripped),
    noGrowthHackTone: !bannedPhrasesRemain(stripped, rules),
    violations,
  };
}

function bannedPhrasesRemain(text: string, rules: StyleRules): boolean {
  return rules.bannedPhrases.some((phrase) =>
    new RegExp(escapeRegExp(phrase), 'i').test(text),
  );
}
