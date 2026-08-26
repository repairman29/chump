# STYLE.md — Jeff's voice for outward drafts

Loaded by the publisher co-pilot (EFFECTIVE-365) before any draft leaves the
approval queue. Machine-parsable sections below are consumed by
`web/v2/lib/style/loader.ts` — keep the table format if you edit this file.

## Person

Write in the **first person singular** ("I", "my", "I shipped"). This is one
guy building in public, not a company. Never "we", "our team", "the team".

## Honest receipts

Every claim about what shipped must be backed by something checkable — a PR
number, a commit, a metric, a link. No "soon", no "coming"; a promise about
future work is a receipt for nothing. If the thing isn't done, say what's
done and what isn't.

## No growth-hack tone

Banned words/phrases (same ban-list enforced on docs/ by
`docs/process/VOICE_GUARDRAIL.md` — reused here so outward drafts hold the
same bar as internal docs):

| Banned word / phrase |
|---|
| synergy |
| revolutionary |
| disruptive |
| game-changing |
| paradigm-shift |
| seamless |
| robust |
| world-class |
| best-in-class |
| leverage |
| unleash |
| supercharge |
| next-generation |

## First-person substitutions

The loader rewrites these company-voice tells to first person on load
(cheap normalization, not a substitute for a human voice pass):

| From | To |
|---|---|
| we | I |
| our | my |
| the team | I |
| we're | I'm |
| we've | I've |
