# Voice Guardrail — INFRA-1728

## Audience

Chump documentation is written for **tired senior engineers** who have seen every
hype cycle and will close the tab the moment they read a word that belongs in a
Series A deck. The target reader values:

- Technical leverage over persuasion
- Execution speed over vision statements
- Architectural elegance over brand storytelling
- Demonstrated capability over promised capability

## The ban-list

The following words are banned in all `docs/` content. CI will reject a PR that
introduces them (see `scripts/ci/test-voice-banlist.sh`).

| Banned word / phrase | Why |
|---|---|
| `synergy` | Vacuous. Senior engineers hear "we don't know what this does." |
| `revolutionary` | Self-awarded. If it were, the code speaks for itself. |
| `disruptive` | VC-speak. The engineer you're addressing invented the thing you're calling this. |
| `game-changing` | Same class as "revolutionary." Never self-applicable. |
| `paradigm-shift` | Academic pretension deployed as marketing. |
| `seamless` | Everything someone calls this has seams. |
| `robust` | Synonymous with "we hope it doesn't break." Prove it with a test. |
| `world-class` | Unmeasurable. Cite a benchmark instead. |
| `best-in-class` | Same as "world-class." Specify the class and the metric. |
| `leverage` (as verb) | "Use" means the same thing without the suit. |
| `unleash` | Action-movie verb. Not found in a technical spec. |
| `supercharge` | Same class as "unleash." |
| `next-generation` | Every release calls itself this. The term has collapsed. |

## Bypass

### Per-PR bypass (rare, documented)

Add this trailer to any commit in the PR:

```
Voice-Lint-Bypass: <one-sentence reason why this banned word is necessary>
```

Example: `Voice-Lint-Bypass: Quoting a third-party vendor's own marketing copy for critical analysis.`

Every bypass emits `kind=voice_lint_bypassed` to `ambient.jsonl` for retro
tracking. Patterns of bypass get reviewed at the quarterly curation pass.

### Operator-wide opt-out (emergency only)

```bash
export CHUMP_VOICE_LINT_DISABLE=1
```

Sets an ambient event `kind=voice_lint_bypassed` with `reason=operator_override`
and prints a loud warning. Not intended for routine use.

### Allowlist: code blocks and backticks

Text inside Markdown code fences (` ``` `) or inline backticks is exempt.
Quoting third-party copy for technical analysis does not trigger the lint.

## Wiring

- CI gate: `scripts/ci/test-voice-banlist.sh`
- Workflow: `.github/workflows/voice-lint.yml`
- Self-test: `scripts/ci/test-voice-banlist-self.sh`
- Emits: `kind=voice_lint_violation {pr, doc_path, word, line_no}` per violation
- Pairs with: Evangelist content bot voice prompt (META-066)
