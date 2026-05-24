---
name: external-collab
description: Chump's operator-facing + external-facing surface curator (curator-opus-external-collab role) — run the work-your-lane loop for Marcus customer-arc tracking + PITCH.md/HIDDEN_GEMS.md/DEMO_5MIN.md voice and freshness audits + partnership pipeline (INFRA-1501 Anthropic / INFRA-1506 license / INFRA-1511 founding-customer). Use to (1) get Marcus arc status, (2) audit operator-facing docs for voice drift + staleness, (3) check partnership pipeline health, (4) run one full tick. **This skill is a thin wrapper over `scripts/coord/external-collab-loop.sh`**. Examples that should trigger this skill: "Marcus review", "customer arc status", "PITCH.md update", "partnership pitch", "voice audit", "how stale is our operator surface".
user-invocable: true
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
---

# /external-collab — Operator-Facing Surface Curator Loop

The external-collab curator owns Chump's operator-facing and external-facing surfaces: the Marcus M-A through M-E customer arc, the PITCH.md / HIDDEN_GEMS.md / DEMO_5MIN.md voice and freshness, and the partnership pipeline (Anthropic outreach, license decision, founding-customer offer). The discipline lives at [`.claude/agents/external-collab.md`](../../agents/external-collab.md).

The canonical surface is `scripts/coord/external-collab-loop.sh` — a harness-neutral shell CLI. Any harness invokes it the same way.

Arguments passed: `$ARGUMENTS`.

## Routing

Parse `$ARGUMENTS`:
- Empty / `tick` → run one full cycle (all subcommands in sequence)
- `marcus-status` → show current Marcus milestone + days-since-last-progress
- `voice-audit` → run ban-list check on PITCH.md, HIDDEN_GEMS.md, DEMO_5MIN.md
- `partnership-pipeline` → report days-open for INFRA-1501, INFRA-1506, INFRA-1511
- `surface-freshness` → check age of each operator-facing doc; flag if >14d
- `status` → alias for full tick (all subcommands)

```bash
bash scripts/coord/external-collab-loop.sh ${ARGUMENTS:-tick}
```

## What each subcommand surfaces

| Subcommand | Output | Ambient event emitted |
|---|---|---|
| `marcus-status` | Current milestone (M-A/B/C/D/E), days stalled per gap | `external_collab_finding` w/ `category=marcus_at_risk` if >7d stalled |
| `voice-audit` | List of banned terms found per doc | `external_collab_finding` w/ `category=voice_drift` |
| `partnership-pipeline` | Days-open for each pipeline gap | `external_collab_finding` w/ `category=partnership_stalled` if deadline approaching |
| `surface-freshness` | Last-touched age per doc | `external_collab_finding` w/ `category=surface_stale` if >14d |
| `tick` | All of the above | All of the above |

## CRITICAL: what this curator does NOT do

- **Does NOT edit PITCH.md / HIDDEN_GEMS.md / DEMO_5MIN.md.** Audit only; edits go through normal gaps.
- **Does NOT make license or partnership decisions.** Drafts materials, surfaces data, defers to operator.
- **Does NOT touch `src/` or `crates/`.**

## Behavior rules

- Surface script output directly to the user. Don't re-paraphrase external-collab-loop.sh findings.
- When a finding fires, offer to file a gap if none exists — but do not self-file without confirmation.
- If the operator asks to edit a doc surface: decline, explain the audit-only discipline, offer to file a gap instead.
- One tick per invocation unless operator requests loop mode.

## Cross-references

- [`.claude/agents/external-collab.md`](../../agents/external-collab.md) — full agent discipline
- [`scripts/coord/external-collab-loop.sh`](../../../scripts/coord/external-collab-loop.sh) — canonical executable surface
- [`docs/strategy/ROADMAP_MARCUS.md`](../../../docs/strategy/ROADMAP_MARCUS.md) — Marcus M-A through M-E arc
- [`docs/PITCH.md`](../../../docs/PITCH.md) — operator surface (audit only)
- [`docs/HIDDEN_GEMS.md`](../../../docs/HIDDEN_GEMS.md) — operator surface (audit only)
- [`docs/DEMO_5MIN.md`](../../../docs/DEMO_5MIN.md) — operator surface (audit only)
- [`docs/gaps/INFRA-1501.yaml`](../../../docs/gaps/INFRA-1501.yaml) — Anthropic partnership
- [`docs/gaps/INFRA-1506.yaml`](../../../docs/gaps/INFRA-1506.yaml) — license decision (operator sign-off required)
- [`docs/gaps/INFRA-1511.yaml`](../../../docs/gaps/INFRA-1511.yaml) — founding-customer offer
- [`.claude/skills/target/SKILL.md`](../target/SKILL.md) — sibling pattern (productization template)
