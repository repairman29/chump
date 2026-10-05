# Discord / operator-escalation work — handoff briefing

Written 2026-08-09. For a Claude agent picking this up cold. Everything below is
verified by running it, not by reading. Where something is unverified it says so.

## The one-paragraph version

Chump can already **send** a Discord DM to Jeff's phone — that shipped tonight and
is proven live. Chump **cannot receive** replies or button taps yet, because the
Discord gateway was compiled out and not running. The receive path is otherwise
complete in `src/discord.rs` and has been for a while. The work in flight is
turning it on safely, then routing PR auto-close decisions through it so Jeff can
approve/deny from his phone instead of losing a day's work to a false red.

## Why this started

`pr-failure-auto-rescue` closed **PR #3510** on 2026-08-08 after 23.2h, on a
single required check that was **red-but-false** (a flake whose gate ran outside
the retry wrapper). 23 hours of ready work destroyed, and **nothing told Jeff** —
he found out by asking, hours later. The daemon even recorded an outcome named
`operator_alert` that wrote a log line and alerted nobody. A label, not an alert.

## What already existed (do NOT rebuild these)

| Thing | Where | State |
|---|---|---|
| DM send, REST, **needs no bot** | `src/discord_dm.rs` (`send_dm_if_configured`) | 5 live callers, works |
| Gateway bot, `DIRECT_MESSAGES` intent | `src/discord.rs` | complete, was compiled out |
| Owner verification | `src/discord.rs:932/964/999` vs `CHUMP_READY_DM_USER_ID` | complete |
| **Approve/deny button handler** | `src/discord.rs:1210` `interaction_create`, parses `chump_approve:<id>` / `chump_deny:<id>` | complete |
| Approval resolver + timeout | `src/approval_resolver.rs` (`request_approval`/`resolve_approval`/`is_pending`) | complete, unit-tested |
| Platform abstraction | `src/platform_router.rs` `MessagingAdapter` | complete |
| Telegram adapter | `src/telegram.rs` | built; `TELEGRAM_CHAT_ID` **absent**, so not addressable |
| Web approval UI + `POST /api/approve` | `web/v2/approval.js` | complete |

Credentials present (names only): `DISCORD_TOKEN`, `CHUMP_READY_DM_USER_ID`,
`TELEGRAM_BOT_TOKEN`. **No** WhatsApp/Twilio/Pushover/Slack credentials anywhere.

## Policy Jeff set, and it binds

- **openclaw is NOT to be run.** It is a fork of a third-party agent runtime;
  making it ChumpOS's transport violates the build-our-own directive. Jeff's
  words: *"we can port their code into our ops but not using their system."*
- **Porting its code IS allowed.** openclaw is MIT (© 2025 Peter Steinberger,
  `github.com/openclaw/openclaw`). Credit in the PR description; no per-file
  headers needed for a TS→Rust reimplementation. See DOC-093.
- **`discord` stays an opt-in cargo feature.** Measured: **+6.2 MB** binary,
  **14m27s** cold build. But outbound alerts must work in the DEFAULT build —
  and they do, because `notify-operator.sh` is pure bash+curl. See RESILIENT-270.

## Gap chain, in dependency order

Nothing is linked with `depends_on` yet — the orchestrator sees these as
independent. **Order matters:**

1. **RESILIENT-263** — outbound DM + chunking. **MERGED** (PR #3544, merged
   2026-08-09T20:15:42Z, `closed_pr: 3544`). Outbound escalation is on main.
   *(An earlier draft of this doc called this a "false-done" — that was wrong.
   It was checked in the seconds between the gap flipping and the merge
   completing. The gap store was right.)*
2. **RESILIENT-266** — compile `--features discord`, run the gateway under
   launchd with a liveness check. **This is the unlock.** Nothing can be received
   until it lands. In progress; see "traps" below.
3. **RESILIENT-265** — route auto-close through `request_approval()` so Jeff gets
   approve/deny buttons before a PR is destroyed. Needs 266.
4. **RESILIENT-262** — triage that decides retry vs escalate, so a flake never
   again closes a PR. Needs 266.
5. **RESILIENT-270** — decide the durable default transport + fallback order.
6. **RESILIENT-275 (P0)** — see below, unrelated to Discord but found by it.
7. **DOC-093** (decision record), **DOC-094** (the four opt-in gates),
   **DOC-096** (parity obligation).

## Traps that cost real time tonight — read before touching this

1. **`.env` is gitignored**, so it exists only in the main checkout, while
   `chump claim` makes a worktree per gap. Hit **3 times**, each with a different
   symptom: a silent skip, a false "token not set", and a daemon death loop. Fix
   exists: `scripts/coord/lib/resolve-env.sh` (resolves via
   `git rev-parse --git-common-dir`). Sweep filed as **CREDIBLE-265**.
2. **`discover-chump-bin.sh:57` calls `exit 1`** — sourcing it kills the parent.
   The daemon died with exit 1 and **zero output**. Run it in a subshell.
3. **cargo is in `~/.cargo/bin`** (rustup), not `/opt/homebrew/bin`. launchd's
   minimal PATH silently defeats binary discovery.
4. **Unquoted heredocs**: backticks become command substitution. A plist comment
   containing backticked `cargo metadata` caused bash to RUN it and inject the
   JSON dump into the plist → `Bootstrap failed: 5: Input/output error`.
5. **Four independent opt-in gates**, each invisible until the previous is
   cleared: cargo feature → `--discord` flag → `CHUMP_DISCORD_ENABLED=1`
   (PRODUCT-014) → SECURITY-005. See DOC-094.
6. **Adding a step to `audit.yml` obliges a preflight mirror** (INFRA-1867 scans
   sibling workflows). Caught 4 times in one session. See DOC-096.

## SECURITY-005 is CLOSED — do not reopen it by reverting

The gateway used to be blocked because serenity pulled
`tokio-tungstenite 0.21 → rustls 0.22 → rustls-webpki 0.102.8`
(**RUSTSEC-2026-0104**, HIGH: DoS via panic on malformed CRL).

It was **designed out, not bypassed**. `Cargo.toml`'s serenity dep had explicitly
opted into `rustls_backend`; it now uses `native_tls_backend`, which drops the
whole chain. Verified: `cargo tree -i rustls-webpki@0.102.8 --features discord`
matches no packages; `Cargo.lock` carries only `0.101.7` and `0.103.13`. The
runtime gate in `src/main.rs` is removed.

Neither version route could work, and both were tried: `[patch]` to 0.103 cannot
satisfy rustls 0.22's `^0.102`, and `cargo update --precise` has nowhere to go
because **0.102.8 IS the newest 0.102.x**.

**The trade:** native-tls pulls `openssl 0.10.81` / `openssl-sys` /
`security-framework 3.7.0`. macOS uses Security.framework; **Linux needs system
OpenSSL**, which rustls did not. If the Linux fleet node fails to build the
discord feature, that is why — and the fix is a build dep, **not** a revert to a
known-vulnerable chain. `cargo audit` in CI is the remaining adjudicator; it is
not installed locally.

## RESILIENT-275 (P0) — found by this work, bigger than this work

`~/Projects/Chump/target` is a **symlink** to `~/.cargo/chump-shared-target`
(same inode), and ZERO-WASTE-029 points every local build there. So a release
build in any worktree **deletes the fleet's binary mid-build** — observed live:
`ls` returned "No such file or directory" with two cargo procs running, and a
command in that session failed as a direct result.

Second, quieter mode: a `--features discord` build publishes a discord-enabled
binary, and a later default build replaces it with no error. RESILIENT-266's
installer works around this by copying to `~/.chump/bin/chump-discord`.

**Do not "fix" this by reverting ZERO-WASTE-029** — per-repo target dirs cost
54GB and caused a disk-100% incident.

## Verification standard for this work

Jeff's `operator-recall` notifier sat `enabled = true` with **zero processes
running since 2026-05-08** and nobody noticed for three months, because nothing
checked. Every notification path here must be proven by a **real send to a real
device**. A test asserting "the function was called" is exactly the mock-shaped
green that let that handler pass while dead.

Proven so far by real delivery: 3 DMs, including a 4,959-char message chunked
into 3 numbered parts, and a gateway that connected (`Discord connected as
Chump`) under launchd's exact minimal environment with **no bypass flag set**.

## Known-unverified

- `cargo audit` has not run against the native-tls swap (not installed locally).
- The full approve/deny loop has **never been exercised end to end**. Nobody has
  tapped a button and confirmed a PR was not closed. That is the acceptance test
  for RESILIENT-265 and it must be done on a real phone.
