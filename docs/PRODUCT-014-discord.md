# PRODUCT-014: Discord intent parsing

The Discord adapter is Chump's asynchronous secondary surface — the PWA is the
primary North Star. PRODUCT-014 ships the first user-facing slice of the
"understand and act" promise: a thin intent classifier that recognizes three
top-level verbs (`summarize`, `search`, `remind`) and emits a structured
`discord_intent` event into `ambient.jsonl` so the PWA / observability surfaces
can show what users are asking Discord for. The LLM agent still drives the
actual reply — the classifier only labels.

## Setup

1. **Create a Discord bot** at <https://discord.com/developers/applications>:
   - New Application → Bot → Add Bot
   - Copy the bot token
   - Under "Privileged Gateway Intents" enable **Message Content Intent**
   - Under OAuth2 → URL Generator pick scopes `bot` + `applications.commands`,
     bot perms: Send Messages, Read Messages/View Channels
   - Open the generated URL to invite the bot to a server (or DM it directly)

2. **Set environment variables** in `.env`:
   ```
   DISCORD_TOKEN=...your bot token...
   CHUMP_DISCORD_ENABLED=1
   ```

   `CHUMP_DISCORD_ENABLED=1` is a deliberate second gate — the binary refuses to
   attach to Discord without it, even if a token is present. This keeps
   shared deployments from auto-attaching.

3. **Run**:
   ```
   chump --discord
   ```

## Three recognized intents

| Intent      | Slash form               | Natural-language openers                          |
|-------------|--------------------------|---------------------------------------------------|
| `summarize` | `/summarize`, `/tldr`    | `summarize ...`, `TLDR ...`, `tl;dr ...`          |
| `search`    | `/search`, `/find`       | `search ...`, `look up ...`, `find me ...`       |
| `remind`    | `/remind`                | `remind me to ...`, `remind ...`                  |

The classifier is case-insensitive, anchored at the start of the message, and
intentionally narrow — bare words inside a sentence (e.g. "give me a summary")
do **not** trigger. Implementation: `src/discord_intent.rs`.

## Observability

Every classified intent emits one line to `.chump-locks/ambient.jsonl`:

```json
{"kind":"discord_intent","intent":"summarize","channel":"123","user":"alice","ts":"..."}
```

Tail it locally with `scripts/ambient-watch.sh` or query with
`scripts/ambient-query.sh`. The PWA's activity stream filters on
`kind=discord_intent` to surface Discord-sourced asks alongside other adapter
activity (Slack, Telegram).

## Limitations

- **Classifier is heuristic, not semantic.** "Can you summarize..." won't
  match (the verb isn't at the start). The LLM still handles the request,
  but it won't be tagged. Future work: an LLM-routed classifier behind a
  feature flag.
- **Three verbs only.** This is the minimum slice; broader vocabularies can
  ship behind feature flags as their own gaps.
- **No reply-side intent confirmation.** The LLM reply is free-form; the
  intent label is for ambient observability only.
- **Not deployed in production.** Opt-in via `CHUMP_DISCORD_ENABLED=1`; you
  bring your own bot token.

## Related

- `src/discord.rs` — full Discord adapter (Serenity-based, ~1450 LOC)
- `src/discord_intent.rs` — classifier + ambient emit
- `src/messaging/discord_shim.rs` — `MessagingAdapter` trait shim (COMP-004a)
- Docs: `docs/CHUMP_PROJECT_BRIEF.md` for the original "understand and act in
  Discord" North Star this slice operationalizes.
