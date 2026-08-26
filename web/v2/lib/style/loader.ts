// EFFECTIVE-484 (EFFECTIVE-365 slice): loads content/STYLE.md and applies
// Jeff's voice rules to draft text before it reaches the publisher
// approval queue (EFFECTIVE-365). Parses the ban-list and first-person
// substitution tables straight out of the markdown so STYLE.md stays the
// single source of truth — no rule is duplicated in code.

import { readFileSync } from 'node:fs';

export interface StyleRules {
  readonly bannedWords: readonly string[];
  readonly substitutions: ReadonlyMap<string, string>;
}

const MARKDOWN_TABLE_ROW = /^\|\s*(.+?)\s*\|(?:\s*(.+?)\s*\|)?$/;

function parseSingleColumnTable(section: string): string[] {
  const rows: string[] = [];
  for (const line of section.split('\n')) {
    const match = MARKDOWN_TABLE_ROW.exec(line.trim());
    if (!match) continue;
    const cell = match[1].trim();
    if (cell === '' || /^-+$/.test(cell) || cell === 'Banned word / phrase') continue;
    rows.push(cell.replace(/^`|`$/g, ''));
  }
  return rows;
}

function parseTwoColumnTable(section: string): Map<string, string> {
  const map = new Map<string, string>();
  for (const line of section.split('\n')) {
    const match = MARKDOWN_TABLE_ROW.exec(line.trim());
    if (!match || !match[2]) continue;
    const from = match[1].trim().replace(/^`|`$/g, '');
    const to = match[2].trim().replace(/^`|`$/g, '');
    if (from === '' || /^-+$/.test(from) || from === 'From') continue;
    map.set(from, to);
  }
  return map;
}

function extractSection(markdown: string, heading: string): string {
  const headingIndex = markdown.indexOf(heading);
  if (headingIndex === -1) {
    throw new Error(`STYLE.md is missing the "${heading}" section`);
  }
  const rest = markdown.slice(headingIndex + heading.length);
  const nextHeading = rest.search(/\n## /);
  return nextHeading === -1 ? rest : rest.slice(0, nextHeading);
}

export function parseStyleGuide(markdown: string): StyleRules {
  const bannedWords = parseSingleColumnTable(extractSection(markdown, '## No growth-hack tone'));
  const substitutions = parseTwoColumnTable(extractSection(markdown, '## First-person substitutions'));
  return { bannedWords, substitutions };
}

export function loadStyleGuide(path = 'content/STYLE.md'): StyleRules {
  return parseStyleGuide(readFileSync(path, 'utf-8'));
}

/**
 * Rewrites company-voice pronouns to first person and strips growth-hack
 * ban-list words. This is normalization, not a full voice pass — it makes
 * mechanically-detectable violations (AC 2: first person, no growth-hack
 * tone) hold before a human reviews the draft in the approval queue.
 */
export function applyStyle(text: string, rules: StyleRules): string {
  let out = text;
  for (const [from, to] of rules.substitutions) {
    out = out.replace(new RegExp(`\\b${from}\\b`, 'gi'), (m) =>
      m[0] === m[0].toUpperCase() ? to[0].toUpperCase() + to.slice(1) : to,
    );
  }
  for (const banned of rules.bannedWords) {
    out = out.replace(new RegExp(`\\b${banned}\\b`, 'gi'), '');
  }
  return out.replace(/[ \t]{2,}/g, ' ').trim();
}

export function assertFirstPerson(text: string): void {
  if (/\b(we|our|the team)\b/i.test(text)) {
    throw new Error('draft is not in first person — found "we"/"our"/"the team"');
  }
}

export function assertNoGrowthHackTone(text: string, rules: StyleRules): void {
  for (const banned of rules.bannedWords) {
    if (new RegExp(`\\b${banned}\\b`, 'i').test(text)) {
      throw new Error(`draft uses growth-hack tone: "${banned}"`);
    }
  }
}

export function assertHonestReceipts(text: string): void {
  const hasReceipt = /#\d+|\bPR\s*\d+|\bcommit\b|https?:\/\/|\b\d+(\.\d+)?%/i.test(text);
  if (!hasReceipt) {
    throw new Error('draft has no checkable receipt (PR/commit/link/metric)');
  }
}
