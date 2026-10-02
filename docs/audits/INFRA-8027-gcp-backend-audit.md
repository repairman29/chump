# INFRA-8027: GCP/Firebase backend audit — per-app classification

> Synthesizes `/tmp/wsdocs/GCP_EXIT.md` (workspace-docs, operator-maintained, built 2026-09-25 from a
> scan of 81 `repairman29` repos) into the explicit per-app classification this gap's AC asks for, checks
> it against the gaps already filed, and flags what's still open. Does not re-derive the underlying
> evidence — GCP_EXIT.md is the source of record; this doc is the audit rollup + gap-coverage check.

## Classification legend

- **cuphead-Supabase** — migrates to the self-hosted Supabase OSS stack on cuphead (RESILIENT-314, shipped).
- **migrate-elsewhere** — leaves GCP but not to cuphead (hosted Supabase free/paid slot, or a Vercel-only rebuild).
- **Google-login-only** — Firebase/Firestore/Functions/Storage leave; the GCP project (or a successor
  auth-only project) is **kept** solely for the "Sign in with Google" OAuth client.
- **retire** — export anything worth keeping, then delete the project. No migration.

## Per-app inventory + classification (AC #1–5)

| App (repo) | GCP project(s) | Backend deps found | Classification | Migration gap |
|---|---|---|---|---|
| Peak Vinyl Club (`pvc`) | `peakvinyl` | Firebase Auth (30 files), Firestore (members/events/transactions/filings/applications…), 1 Cloud Function | **migrate-elsewhere** (hosted Supabase free slot — real member data, highest stakes, not the shared cuphead box) | PRODUCT-304 |
| Smuggler (`smuggler`) | `playsmuggler-b1cda`, `smuggler-d1b4a` | firebase-admin for `sessions`/`presence` + ID-token verify; Gemini as one LLM provider | **cuphead-Supabase** | PRODUCT-305 |
| PostSub (`postsub`) | `fulcrum-41e50` (+ `newsletter-platform-mvp`?) | Firestore (60 files: users/subscribers/subscriptions/email_queue…), Functions (25 files: Stripe, email), Auth, Storage | **cuphead-Supabase** | PRODUCT-306 |
| MyTrove (`trove-web`) | `trove-web` | App Hosting (Next.js), Firestore (collections/items/usage/subscriptions), Auth, Storage, Vision API, Secret Manager (31 files), live SA key | **cuphead-Supabase** | PRODUCT-307 |
| POV (`pov-video`) | `echeo-vid` | Firestore (videos/comments/workspaces…), Auth, Storage (video), Functions, Speech-to-Text, Secret Manager | **cuphead-Supabase** | PRODUCT-308 |
| Workbench / TAM app (`workbench`) | `workbench-tam-app` | Hosting, Firestore (customers/mtmWorkflows…), Auth, Functions, Storage, Genkit/Vertex | **retire** (export then archive; migrate only if it gets a real user) | PRODUCT-309 |
| SlideMate (`slidemate`) | `slidemate-1568` | Firebase Hosting + Functions, Gemini (180 files), Secret Manager; **also holds Olive's + SlideMate's Google OAuth clients** | **Google-login-only** (hosting/functions move to Vercel; project itself is kept, not deleted — holds two apps' OAuth clients, ASK-049) | PRODUCT-309 (explicit DO-NOT-DELETE) |
| Kosmos / LifeOS (`kosmos`) | `lifeos-dev`, `lifeos-family-os` | Firebase Hosting, Auth, Firestore; Gmail/Calendar OAuth | **inconsistent in source — flagged below** | PRODUCT-309 |
| Echeo work platform (`echeo-workplatform`) | `echeodev` | Cloud Run ×5, Pub/Sub, Cloud Tasks, Vertex, Secret Manager (38), Storage — heaviest GCP user | **retire** (confirm idle, delete; rebuild only what's needed on Vercel) | PRODUCT-309 |
| `mythseeker`/`mythseeker2` | `mythseekers-rpg` | Firestore, Auth | **retire** | PRODUCT-309 |
| `smugglers`, `code-roach`, `oracle` (`smuggler-d1b4a`), `project-forge`, `payment-platform-service` | dormant/killed, no live deploy | — | **retire** | PRODUCT-309 |
| `roblox-game-manager` | n/a (GCP Secret Manager only, no Firebase) | Secret Manager (python) | **retire the GCP dependency** (swap to local env vars — trivial, no migration gap needed) | — |
| `playsmuggler-auth`, `postsub-auth`, `mytrove-auth`, `sendpov-auth` | 4 new sign-in-only projects, created 2026-09-27 | Google OAuth client only, no billing | **Google-login-only** (by design — these ARE the per-app auth-only replacement projects) | n/a — already shipped, live per GCP_EXIT.md 2026-09-27 entry |
| "Smuggler" (ambiguous) | `gen-lang-client-0312503272` | unknown — ownership unresolved | **unclassified** — page Jeff (already flagged in PRODUCT-303 notes: which account owns `smuggler-d1b4a`, or was this the intended second project?) | blocked on operator answer |
| 50 of 81 repos (incl. `holler`, `almanac`, `upshift`, Olive's backend, `chump`'s own runtime) | none | no GCP usage at all | **clean — not in scope** | n/a |
| `ai-gm-service`, `echeo-web`, `wear-sentinel-suite`, `jarvis-gateway`, `chump` | none (API-key only) | Gemini as one LLM provider (keys, rate tables, weekly reflection job) | **small swap** — decide once, fleet-wide, whether Gemini stays in the provider list; not a GCP-project-exit item | — |
| `openclaw` | n/a | Upstream Gemini + Google Chat provider support | **leave** — upstream code, not owned infra | — |

## Finding: Kosmos/LifeOS classification conflict (needs operator resolution)

GCP_EXIT.md lists `lifeos-dev` / `lifeos-family-os` two different ways:

- **"GCP projects to wind down" table**: `export → delete`.
- **"Keep (Google, but not what we're leaving)" section**: "Sign in with Google: ... `kosmos` ..." — implying
  the OAuth client should survive the same way `slidemate-1568`'s does.

Those two statements as written are contradictory: you cannot delete the project *and* keep its OAuth
client unless the client is first moved to a new auth-only project (the same pattern used for
`playsmuggler-auth`/`postsub-auth`/`mytrove-auth`/`sendpov-auth`). PRODUCT-309's current AC says "Every
GCP project ... is either deleted ... or listed as auth-only with no billable services" but its
description still says `export → delete` for both lifeos projects with no auth-only carve-out.

**This audit's resolution (recorded here per AC #7, pending Jeff confirmation):** do not delete
`lifeos-dev`/`lifeos-family-os` as part of PRODUCT-309 until either (a) kosmos's Gmail/Calendar OAuth
client is confirmed dead/unused (kosmos has been dormant since Aug 1, so this is plausible), or (b) the
client is migrated to a new auth-only project first, same pattern as the four `*-auth` projects. Added a
flag to GCP_EXIT.md's wind-down table (see change in this PR) so PRODUCT-309 doesn't silently delete a
project holding a live OAuth client.

## Coverage check against filed gaps (AC #6)

The cuphead-Supabase set (AC #6: "extends PRODUCT-304..309") is fully covered — no new migration gaps
needed:

| Gap | App | Target |
|---|---|---|
| PRODUCT-304 | pvc | hosted Supabase (not cuphead — pvc is `migrate-elsewhere`, by design, see GCP_EXIT.md "$0/month hosting" decision) |
| PRODUCT-305 | smuggler | cuphead-Supabase |
| PRODUCT-306 | postsub | cuphead-Supabase |
| PRODUCT-307 | trove-web | cuphead-Supabase |
| PRODUCT-308 | pov-video | cuphead-Supabase |
| PRODUCT-309 | wind-down (retire + Google-login-only carve-outs) | n/a |
| PRODUCT-310 | Firestore/Storage completion, billing-gated | n/a |

No additional PRODUCT gap is needed for the migrate-to-cuphead-Supabase set; it's a 1:1 mapping onto
PRODUCT-305..308 already.

## What this audit does NOT cover (honesty on the "~28 projects" figure, AC #1)

GCP_EXIT.md's 2026-09-26 operator decision states "Export scope = ALL ~28 GCP projects, not just the ~6
named." The table above enumerates every project **named with evidence** in GCP_EXIT.md — roughly 20
distinct project IDs across the live/dormant/dead tiers plus the 4 new auth-only projects. That's short
of "~28" by an unexplained ~8. This gap cannot close that delta: enumerating the literal account project
list requires `gcloud projects list` under `jeffadkins1@gmail.com`, which (per GCP_EXIT.md's own
prerequisites section) only runs from an authenticated operator session on cuphead, not from this
worktree. Filed a small P3 follow-up (INFRA-7888) to run that enumeration and reconcile any project not
already named above.

## Output cross-referenced into GCP_EXIT.md (AC #8)

See the companion edit to `/tmp/wsdocs/GCP_EXIT.md` in this PR: adds a dated entry pointing back to this
audit doc, and flags the lifeos-dev/lifeos-family-os wind-down row per the finding above.
