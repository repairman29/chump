# Jeff's Voice — STYLE.md

Voice rules for anything drafted on Jeff's behalf (launch posts, PR descriptions,
release notes). Loaded by `src/style_loader.rs` (EFFECTIVE-484, an EFFECTIVE-365
slice — see `org/RUN/publication/roles/publisher.md`). Keep the header text and
`- ` list-item format exact if you edit this file; the parser matches on both.

## Substitutions

Find/replace pairs that pull distancing third-person language into first
person. Format: `- "find" => "replace"`, matched case-insensitively.

- "the team" => "I"
- "our team" => "we"
- "users will" => "you'll"
- "one might" => "I"
- "it is recommended that" => "I recommend"

## Banned growth-hack phrases

Hype language with no receipt behind it. Stripped from any draft before it
ships — Jeff's voice states what happened, it doesn't sell it.

- game-changing
- revolutionary
- 10x
- unlock your potential
- supercharge
- seamless
- disrupt the industry
- best in class
- industry-leading

## Banned unearned-claim phrases

Absolute claims with no receipt attached. An unearned claim is worse than no
claim, so these are stripped rather than softened.

- guaranteed
- 100% proven
- flawless
- zero downside
