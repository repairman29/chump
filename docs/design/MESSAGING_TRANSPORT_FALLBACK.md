# Fleet-to-human messaging: default transport + fallback order (RESILIENT-270)

> **Status:** Decided. Discord is the shipped default; rung-2 fallback to
> Telegram is wired but **unverified** (no real send yet — see §4).
> **Decided:** 2026-09-10, operator direction from 2026-08-09 (RESILIENT-270 AC1).
> **Implements in:** `scripts/coord/lib/notify-operator.sh` (`_notify_deliver`,
> `_notify_deliver_discord`, `_notify_deliver_telegram`).

## 1. The question this doc answers

Not "which channel should the fleet use" — Discord already works, unconditionally,
in the default build (no cargo feature, see §2). The real question per RESILIENT-270
AC3: **what happens when Discord is unreachable** — token revoked, API down, or the
operator somewhere Discord doesn't reach. This doc defines the fallback order, the
failure-detection contract, and which rungs are actually proven.

## 2. Why this is a config choice, not a compile-time one (AC5)

`--features discord` gates the **gateway** (inbound replies, interactive buttons) —
+6.2MB, 14m27s cold build, measured. It does **not** gate outbound delivery.
`scripts/coord/lib/notify-operator.sh` is pure bash + curl; `src/discord_dm.rs` and
`src/telegram.rs` are both plain REST, compiled into the default build with no
feature flag. So the property this gap protects — "the fleet can always reach a
human" — must never depend on how the binary was compiled. It depends only on
**which env vars are set**, resolved at runtime from the process environment or
`.env` (see `_notify_env` / `_notify_env_files` in notify-operator.sh). This is
exactly how the gateway ended up silently compiled out in practice (RESILIENT-262)
and nobody noticed for three months — a default that needs a build flag is a
default that is not there.

## 3. The fallback order

| Rung | Transport | Config gate | Status |
|---|---|---|---|
| 1 (default) | Discord DM | `DISCORD_TOKEN` + `CHUMP_READY_DM_USER_ID` | **Verified** — proven live 2026-08-09, three DMs delivered, one chunked 4,959-char message into 3 parts |
| 2 (fallback) | Telegram Bot API `sendMessage` | `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` | **Built, UNVERIFIED** — `TELEGRAM_CHAT_ID` is absent everywhere in the fleet today; setting it is what makes this rung real (AC4) |
| — | Web push (INFRA-1340) | needs a browser subscription | Exists, not wired into this fallback chain — no standing subscription to send to |
| — | `operator-recall` (INFRA-665, `terminal-notifier`/`slack`/`pushover`) | n/a | Handler dead since 2026-05-08 (RESILIENT-262) — **not in the chain**, do not rely on it |
| — | WhatsApp / Twilio / Slack / Pushover | n/a | No credentials exist anywhere in the fleet — not buildable today without new signup |

Rung 2 only fires when rung 1 is **configured but fails to send** — a curl error,
a non-2xx from Discord's REST API, or a failed DM-channel open. It deliberately
does **not** fire when Discord is simply unconfigured (that's the pre-existing
quiet no-op contract every caller of `notify_operator` already depends on — see
`scripts/ci/test-notify-operator.sh` check 7). "Unconfigured" and "unreachable"
are different conditions; only the latter should trigger failover.

## 4. Every rung must be proven by a real send (AC6)

The operator-recall handler passed its own checks for three months while dead
(RESILIENT-262) — a green "the function was called" test is not evidence of
delivery. So:

- **Discord (rung 1): PROVEN.** Three real DMs delivered 2026-08-09, including the
  4,959-char chunked message. This is the only rung with a confirmed real-device
  delivery.
- **Telegram (rung 2): NOT PROVEN.** The fallback path in `_notify_deliver` /
  `_notify_deliver_telegram` was exercised in this change against the real Discord
  and Telegram REST endpoints with deliberately invalid credentials — confirming
  the control flow (Discord failure → ambient record → Telegram attempt → ambient
  record) executes correctly end-to-end — but no message has reached a real
  Telegram chat, because `TELEGRAM_CHAT_ID` is not set anywhere in the fleet.
  **Do not treat this rung as a working fallback until someone sets
  `TELEGRAM_CHAT_ID`, triggers a real failover (or calls
  `_notify_deliver_telegram` directly), and confirms delivery on a real device.**
  Update this section when that happens.
- **Web push, operator-recall, WhatsApp/Twilio/Slack/Pushover: NOT IN THE CHAIN.**
  Listed in §3 for completeness per AC4; none are wired into `_notify_deliver`.

## 5. Failure is detectable, not silent (AC7)

`_notify_deliver` emits to `ambient.jsonl` at each transition so the operator can
see what happened hours later instead of inferring it from silence — the exact
failure mode RESILIENT-263 was filed to close (a 23-hour-old PR destroyed with an
outcome literally named `operator_alert` that told nobody):

| Ambient kind | Meaning |
|---|---|
| `notify_discord_failed` | Rung 1 was configured but the send failed — Discord is down, token revoked, or network issue |
| `notify_fallback_unavailable` | Rung 1 failed and rung 2 is not configured (`TELEGRAM_CHAT_ID` unset) — the operator has **no working channel** right now |
| `notify_fallback_delivered` | Rung 2 delivered after rung 1 failed — worth a look even though the message got through |
| `notify_fallback_failed` | Both rungs failed — the loudest possible signal, read `.chump-locks/ambient.jsonl` immediately |

`notify_fallback_unavailable` is the one to watch for operationally: it means
Discord is down **and there is no fallback**, which is the exact gap this doc
exists to eventually close by getting `TELEGRAM_CHAT_ID` set and rung 2 proven.

## 6. Scope (AC8)

This is a default-selection and fallback-order decision. It does not block or
change RESILIENT-266 (gateway daemon) or RESILIENT-265 (approval-from-phone
buttons) — both continue to run on Discord as their transport; this doc's
fallback chain is additive underneath them, not a prerequisite.

## 7. Next step to fully close the loop

File a follow-up to set `TELEGRAM_CHAT_ID` (message `/start` to the bot from the
operator's Telegram, read the resulting `chat_id` from `getUpdates`) and run a
real failover drill (temporarily revoke/rotate `DISCORD_TOKEN`, trigger a
`notify_operator` call, confirm the Telegram DM lands). Until that drill runs,
rung 2 stays labelled UNVERIFIED per §4.
