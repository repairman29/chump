# Operator transports — default + fallback order (RESILIENT-270)

Fleet-to-human messages leave through `scripts/coord/lib/notify-operator.sh`
(pure bash + curl; no cargo feature, no `chump` binary). The transport is a
**runtime config choice**, not a compile-time one:

```
CHUMP_NOTIFY_TRANSPORTS=discord,telegram   # default; ordered, comma-separated
```

(Set in env, `.env`, or `~/.chump/.env`.) Inbound replies (the Discord gateway,
`--features discord`) stay opt-in; outbound does not depend on them.

## Rungs

| # | Transport | Needs | Status |
|---|-----------|-------|--------|
| 1 | `discord` (default) | `DISCORD_TOKEN`, `CHUMP_READY_DM_USER_ID` | **VERIFIED** — real DMs delivered 2026-08-09 (incl. a 4,959-char message chunked into 3 parts) |
| 2 | `telegram` | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | **UNVERIFIED** — `TELEGRAM_CHAT_ID` is not set on the fleet host, so no real send has happened. Setting it and running `CHUMP_NOTIFY_TRANSPORTS=telegram notify_operator "test"` is the proof; until then this rung is code + stub-tested only |
| — | web push (INFRA-1340) | browser subscription | **UNVERIFIED**, not wired into this chain |
| — | operator-recall (INFRA-665) | — | handler dead since 2026-05-08 (RESILIENT-262); not a rung |

A rung that is unconfigured (missing env) is **skipped, not failed**. If every
rung is unconfigured the call is a silent no-op (unchanged behaviour).

## Failure is visible

Each failed rung emits `kind=operator_transport_failed` (`transport`, `signal`)
to `ambient.jsonl`. If a later rung then delivers, `operator_transport_fellthrough`
(`failed`, `delivered_via`) is also emitted, so "Discord was down at 3am" is
recoverable from the stream even though the operator was reached. If no rung
delivers, `operator_transport_exhausted` is emitted and the function returns 1.

Hermetic coverage: `scripts/ci/test-notify-transport-fallback.sh` (stub curl).
A stub proves wiring, not delivery — only a real send promotes a rung to VERIFIED.
