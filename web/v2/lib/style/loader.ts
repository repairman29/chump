// EFFECTIVE-484 (EFFECTIVE-365 slice): load content/STYLE.md and apply
// Jeff's voice rules to draft text before it reaches the captain for
// approval (org/RUN/publication/roles/publisher.md's "voice check" job).
//
// STYLE.md is the source of truth; this module only parses its `## Rules`
// section (one bullet per rule, `**rule_id** — description`) so editing the
// prose doc is the only thing anyone has to do to change the contract.

import { readFileSync } from 'node:fs';

export type StyleRuleId = 'first_person' | 'honest_receipts' | 'no_growth_hack';

export interface StyleRule {
  readonly id: StyleRuleId;
  readonly description: string;
}

export interface StyleViolation {
  readonly rule: StyleRuleId;
  readonly reason: string;
}

export interface StyleCheckResult {
  readonly passed: boolean;
  readonly violations: readonly StyleViolation[];
}

const RULE_LINE = /^-\s+\*\*(\w+)\*\*\s+—\s+(.+)$/;

const GROWTH_HACK_PHRASES = [
  'game-changing',
  'game changing',
  'revolutionary',
  '10x',
  'disrupt',
  'unlock your potential',
  'supercharge',
  'next-level',
  'next level',
  'level up',
  'crush it',
  '🚀',
];

const FIRST_PERSON_PRONOUNS = /\b(I|I'm|I've|I'll|we|we're|we've|we'll|my|our)\b/i;
const THIRD_PERSON_BRAND = /\b(the team|the company|our team|the organization)\b/i;

/** Parses the `## Rules` section of a STYLE.md into typed StyleRule entries. */
export function parseStyleRules(styleMd: string): StyleRule[] {
  const rules: StyleRule[] = [];
  for (const line of styleMd.split('\n')) {
    const match = RULE_LINE.exec(line.trim());
    if (!match) continue;
    const [, id, description] = match;
    rules.push({ id: id as StyleRuleId, description });
  }
  return rules;
}

/** Reads content/STYLE.md (or the given path) and returns its parsed rules. */
export function loadStyleRules(path = 'content/STYLE.md'): StyleRule[] {
  const styleMd = readFileSync(path, 'utf-8');
  return parseStyleRules(styleMd);
}

/**
 * Checks draft text against a set of loaded style rules. Returns every
 * violation found rather than short-circuiting, so a draft can be fixed in
 * one pass instead of one rule at a time.
 */
export function checkStyle(text: string, rules: readonly StyleRule[]): StyleCheckResult {
  const violations: StyleViolation[] = [];
  const ruleIds = new Set(rules.map((r) => r.id));

  if (ruleIds.has('first_person')) {
    if (THIRD_PERSON_BRAND.test(text) || !FIRST_PERSON_PRONOUNS.test(text)) {
      violations.push({
        rule: 'first_person',
        reason: 'text must speak as "I"/"we", not third-person brand voice',
      });
    }
  }

  if (ruleIds.has('honest_receipts')) {
    const claimVerb = /\b(shipped|launched|built|fixed|grew|increased|reduced|saved)\b/i;
    const hasReceipt = /(#\d+|https?:\/\/\S+|\b\d[\d,.]*%?\b)/;
    if (claimVerb.test(text) && !hasReceipt.test(text)) {
      violations.push({
        rule: 'honest_receipts',
        reason: 'a results claim appears with no receipt (number, link, or PR) nearby',
      });
    }
  }

  if (ruleIds.has('no_growth_hack')) {
    const lower = text.toLowerCase();
    const hit = GROWTH_HACK_PHRASES.find((phrase) => lower.includes(phrase.toLowerCase()));
    if (hit) {
      violations.push({
        rule: 'no_growth_hack',
        reason: `banned growth-hack phrase found: "${hit}"`,
      });
    }
  }

  return { passed: violations.length === 0, violations };
}

/** Convenience: load content/STYLE.md and check text against it in one call. */
export function checkStyleAgainstFile(text: string, path = 'content/STYLE.md'): StyleCheckResult {
  return checkStyle(text, loadStyleRules(path));
}
