# Data Home & Supabase-Replacement — placement + sequence (2026-08-19)

Decision doc for "where the fleet's data lives" and how/whether we replace hosted Supabase.
Supersedes the "on CJ" assumption in RESILIENT-314. Owner: board/crew-chief.

## Where it lives (the decision)

| Data | Home | Why |
|---|---|---|
| **Fleet-internal** (gap registry, telemetry, scoreboard) | **Pixel Postgres** (tailnet `100.84.132.93:5432`) | Idle (load ~0.8), 11Gi RAM / 76G free, always-on, AC-powered/cool. Native Postgres runs fine on aarch64 Termux (already live). Keeps data OFF the busy CJ factory. |
| **Product-app data** (olive, upshift: Auth + RLS + Storage + Edge Functions) | **Hosted Supabase — stays, for now** | Replacing it needs the FULL Supabase OSS stack (GoTrue/Auth + Storage + PostgREST + Realtime + Kong) = docker-compose, which does NOT fit Termux/Android and must not burden the CJ factory. ~$45/mo, sovereignty-not-cost. Ripping out live products' auth/RLS is high-risk, low-urgency. |
| Product data IF ever self-hosted | a **dedicated Linux box** (never CJ, never Termux) | Full OSS stack needs Docker + isolation from the factory. Not a today problem. |

**Bottom line: Pixel is the fleet's data node; hosted Supabase keeps the live products until a dedicated box + real need justify the migration.**

## Scope truth (why this isn't a "point apps at Postgres" swap)

Supabase = Postgres **+ Auth + Storage + Row-Level-Security + Edge Functions + auto-generated REST/Realtime APIs**. The product apps consume all of it via the supabase-js client. Phases 0–1 below need only Postgres (already running). Phase 2 needs the whole stack — that's the real, deferred project.

## Sequence (low-risk first)

- **Phase 0 — fleet registry → Pixel Postgres (actionable now, P2).** Migrate `state.db` (single-node SQLite) → Pixel Postgres as tenant #1 (**INFRA-2092**). Fleet-internal, no auth/RLS. Kills the single-node SQLite drift/split-brain class + gives an off-CJ registry. This is what turns "Postgres is running" into "the Pixel serves the fleet." First proof.
- **Phase 1 — fleet telemetry → Pixel Postgres (later, P3).** ambient / scoreboard / observability rows. Still internal.
- **Phase 2 — product Supabase → dedicated box (deferred, P3, gated on real need).** Full OSS stack; keep hosted Supabase live until then. **RESILIENT-314** carries this, re-scoped + re-homed.

## Deliberately NOT doing
- Not standing up the Supabase OSS stack on CJ (RESILIENT-314's original target) — wrong box.
- Not migrating olive/upshift off hosted Supabase now — live bets, high blast radius, no urgency.
- Not inflating this to P0/P1 — it's real infra but it is NOT factory-forward; it stays parked behind shipping product (tonight's lesson: capability ≠ output).

## 2026-08-22 reconciliation note (INFRA-3634)

Plan/reality drift found and resolved: this doc's Phase-0 plan (above) names
**Pixel** as the fleet registry's home, but the S0 self-hosted Postgres +
PostgREST gap store was actually hand-cranked and stood up on **CJ**
(`100.90.52.126`) — `scripts/setup/install-gap-substrate.sh` (INFRA-3631)
codifies exactly those CJ artifacts (`/etc/systemd/system/chump-postgrest.service`,
`~/.chump/postgrest.conf`), not anything on Pixel. Reality wins: **CJ is the
canonical shared-gap-store address until INFRA-2092 actually executes the
Pixel migration** — Phase 0 above stays the target, it just hasn't shipped
yet, and callers shouldn't assume it has.

Canonical address is now exposed as a single var, `CHUMP_GAP_STORE_URL`
(default `http://100.90.52.126:3000`, the PostgREST surface installed by
`install-gap-substrate.sh`), read by both:
- **`scripts/setup/install-gap-substrate.sh`** (provision side) — persists it
  into `~/.chump/providers.env` after a successful install.
- **`scripts/setup/chump-node-install.sh`** (connect side, INFRA-3633's
  state-db pin block) — reads the `providers.env` pin (or `CHUMP_GAP_STORE_URL`
  env override), falling back to the CJ default.

When INFRA-2092 lands the real Pixel migration, update the default in both
scripts (or set `CHUMP_GAP_STORE_TAILNET_HOST`/`CHUMP_GAP_STORE_URL` at
provision time) and re-date this note — don't let the two scripts drift
again.
