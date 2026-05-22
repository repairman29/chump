---
doc_tag: canonical
owner_gap: META-066
last_audited: 2026-05-22
---

# Content Bots Suite

Four specialist content agents that run **alongside** the engineering Code Custodian when Chump deploys to a repo. The Code Custodian stays pure-technical; these bots translate the technical truth into every other format your project or company needs.

> **Status (2026-05-22):** foundation only. All bots default-disabled. Dispatcher + pipeline + PWA UI tracked in [META-066](../../gaps/META-066.yaml).

## The bots

| Bot | Tier | What it does | Pipeline role |
|---|---|---|---|
| [PMM](pmm.md) | marketing | Translates technical capabilities into business value + release positioning | leaf (consumes Code Custodian directly) |
| [DocuBot](docubot.md) | docs | Writes pristine `/docs`, API guides, quickstarts | fanout (PMM → DocuBot + Evangelist) |
| [Evangelist](evangelist.md) | community | Tutorials, community content, friction-spotting | fanout (PMM → DocuBot + Evangelist) |
| [CopyBot](copybot.md) | conversion | Landing pages, email flows, CTAs | terminus (consumes PMM + DocuBot + Evangelist) |

## Pipeline

```
                     ┌──→  DocuBot   ──┐
Code Custodian ──→ PMM ──┤                ├──→ CopyBot ──→ web/email/marketing channels
                     └──→ Evangelist ──┘
```

- **Code Custodian** outputs an accurate, current architecture map + gap registry. (Already exists; see [docs/process/CUSTODIAN_BLUEPRINT.md](../../process/CUSTODIAN_BLUEPRINT.md).)
- **PMM Bot** decides what's worth talking about, drafts launch plans, ground-truths positioning.
- **DocuBot + Evangelist Bot** run in parallel — one writes formal `/docs`, the other writes tutorials.
- **CopyBot** is the terminus — packages tutorial links into onboarding emails + lander copy.

Asynchronous via ambient events (`content_bot_invoked`, `content_bot_output`, `content_bot_pipeline_step` — registered in [`docs/observability/EVENT_REGISTRY.yaml`](../../observability/EVENT_REGISTRY.yaml) by the follow-up gaps).

## Toggle

**Default: all bots OFF.** Operator opts in two ways:

```toml
# .chump-config.toml in the target repo (per-repo opt-in)
[content_bots]
enabled = ["pmm", "docubot"]      # subset; only listed bots run
```

```bash
# environment override (per-invocation)
CHUMP_CONTENT_BOTS=pmm,evangelist chump deploy /path/to/customer-repo
```

The fleet picker filters by `WORKER_SKILLS=content-bot,<bot_id>` (analogous to the PWA-routing pattern from [INFRA-1622](../../gaps/INFRA-1622.yaml)) so content tasks route to content-tagged workers only.

## Why a separate suite

The engineering Code Custodian's value depends on it staying pure-technical — no marketing context, no positioning bias, no audience-tailoring. Productizing the rest into a distinct suite means:

1. **The code agent stays a "true librarian"** — its only audience is engineers.
2. **Each content bot stays in its persona** — no PMM voice bleeding into reference docs; no copywriter shortcuts in tutorials.
3. **Operators can toggle them independently** — a customer who wants engineering hygiene but writes their own marketing can disable the content tier entirely.
4. **The pipeline is auditable** — each bot's output becomes the next bot's input, so the chain of derivation is explicit and traceable.

## Manifest schema

Defined in [`bots.yaml`](bots.yaml). Each entry:

| Field | Purpose |
|---|---|
| `bot_id` | unique key referenced by toggle config + dispatcher |
| `prompt_path` | repo-relative path to the bot's system prompt manifest |
| `tier` | category (marketing / docs / community / conversion) |
| `model_tier` | which Claude tier to invoke (haiku / sonnet / opus) |
| `default_enabled` | always `false` in this foundation |
| `pipeline_predecessors` | upstream bot_ids whose output this bot consumes |
| `pipeline_role` | leaf / fanout / join / terminus |

## Roadmap

| Gap | Phase |
|---|---|
| [INFRA-1690](../../gaps/INFRA-1690.yaml) | Foundation (this PR): manifests + bots.yaml + README + smoke test |
| Follow-up (TBF) | Dispatcher script (`scripts/content-bots/run-bot.sh`) + ambient event registration |
| Follow-up (TBF) | Pipeline orchestrator (PMM → DocuBot/Evangelist → CopyBot) |
| Follow-up (TBF) | Fleet integration via `WORKER_SKILLS=content-bot,<bot_id>` |
| Follow-up (TBF) | PWA toggle UI with per-bot daily cost estimate |
| Productization umbrella | [META-066](../../gaps/META-066.yaml) |

## Provenance

Operator strategy 2026-05-22 21:15Z: "To keep your engineering agent pure, technical, and focused on the code, you should offload the rest of the business, product, and creative copy to a dedicated suite of specialized Content Bots. By separating concerns, your code agent stays a 'true librarian,' while these specialized personas translate that core technical truth into every other format your project or company needs."

The 4 system prompts are captured verbatim from operator direction. Chump-specific operational notes (research-privacy compliance, pipeline wiring, fleet routing) are added per-bot.
