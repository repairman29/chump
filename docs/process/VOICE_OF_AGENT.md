---
doc_tag: process-protocol
audience: agent role authors, external operators, future curators
purpose: Defines the Voice-of-Agent (VOA) protocol — how an agent running chump in a user's repo can file upstream improvement reports against chump itself. Forward-deployment motion that turns every user-session into a contribution channel for chump-the-product.
status: v1 (2026-05-29) — operator-approved framing during the dogfood session that produced VOA-001
last_audited: 2026-05-29
---

# Voice of the Agent (VOA) Protocol

> **The strategic frame.** Chump goes out to work on other repos. Sometimes the product needs to improve **itself** rather than the target repo — because better chump = better work on the target. This is a forward-deployment motion: every agent shipping work in a user's repo is also a distributed product engineer for chump-the-product. This protocol gives them the channel.

## When to file a VOA

An agent (curator, sub-agent, paramedic, anything running in a chump session) files a VOA when **friction in chump itself slowed down the work for the target repo**. Typical triggers:

- A wedge class blocked shipping for >5 min
- A tool that should exist doesn't (workaround required hand-rolling)
- A tool that exists wedged silently (no clear failure signal)
- A doc that should explain something didn't
- An anti-pattern that surfaced N times and is now worth codifying

A VOA is **not**:
- A bug in the target repo (file that as a normal gap in the target)
- An aspirational feature with no evidence (file as a regular INFRA gap with rationale)
- A duplicate of an existing VOA (link the existing one instead)

## The shape

Two artifacts per VOA:

1. **Lightweight gap entry** at `docs/gaps/VOA-NNNN.yaml` — fits the existing gap registry; `chump gap list --domain VOA` finds them.
2. **Full report** at `docs/voice/VOA-NNNN-FULL.yaml` — the rich friction record. Schema defined in `docs/voice/VOA-001-FULL.yaml`.

Why two? The lightweight entry is the queue surface (operators triage VOAs alongside regular gaps); the full report is the durable evidence + design artifact that downstream fixes can reference. The split keeps `chump gap list` output legible.

## Reporter identity + privacy model

Every VOA has a `reporter` block. Three disclosure modes:

| Mode | What's disclosed | Default for |
|---|---|---|
| `anonymous` | Wedge class, minutes lost, workaround shape, proposed fix shape | All VOAs unless overridden |
| `opt-in:slug` | Above + the target-repo slug | User explicit opt-in per VOA |
| `opt-in:full` | Above + full session details, user identity | Power-user blanket consent via `~/.chump/voice-opt-in.toml` |

**Hard rule:** target-repo's source code, secrets, gap content, or any IP-bearing artifact **never** appears in a VOA — only chump-related artifacts (lease files, ambient events, chump CLI output, chump gap YAMLs, chump script paths).

**Power-user opt-in file** (`~/.chump/voice-opt-in.toml`):

```toml
# Voice-of-Agent disclosure consent
mode = "opt-in:slug"  # or "opt-in:full" or "anonymous"
github_identity = "your-gh-handle"
notes = "Optional comment that appears in dashboards"
```

## Filing flow (today — manual; tomorrow — `chump voice`)

**Today (manual):**
1. Agent identifies the friction class (consult `docs/process/SHIP_ASSIST_PLAYBOOK.md` § 1 for the canonical taxonomy; propose a new class if none fits)
2. Reserve `VOA-NNNN` via `chump gap reserve --domain VOA --title "<wedge-class>: <one-liner>"`
3. Write the lightweight YAML at `docs/gaps/VOA-NNNN.yaml` (AC bullets summarizing the report)
4. Write the full YAML at `docs/voice/VOA-NNNN-FULL.yaml` (the rich record — see `VOA-001-FULL.yaml` for schema)
5. Ship as a normal docs PR

**Tomorrow (after INFRA-2258 ships):**
```bash
chump voice \
    --wedge-class fmt-drift-queue-wide \
    --minutes-lost 30 \
    --workaround "cargo fmt --all sweep PR" \
    --workaround-pr 2782 \
    --fix-shape gate \
    --fix "auto-sweep daemon mirrors local preflight against CI parity (INFRA-2120)" \
    --target-repo anonymous \
    --evidence "PR #2769 job 78610314224"
```

Writes both YAMLs, emits `kind=voice_of_agent_filed` (anonymized fields only). Optional `--ship` opens a PR against `repairman29/chump` from the user's gh identity.

## Aggregation (INFRA-2260)

Three derived surfaces once VOAs land at volume:

| Surface | What it shows | Audience |
|---|---|---|
| `chump voice top` | Top-N VOA gaps ranked by impact (minutes × frequency) | Every new agent session reads at start |
| `docs/voice/WEDGE_HEATMAP.md` | 30-day rolling per-wedge-class counts + total-minutes-lost | Core team prioritization |
| `chump voice status` | Top-3 wedge classes this week, total minutes-lost, agents-filing-count | Operator dashboard |

**Auto-promote rule:** when ≥3 VOA gaps with the same `wedge_class` land within 30 days, the corresponding proposed-fix gap (if it exists) gets auto-promoted to **P0** and cross-linked to the source VOAs. Emit `kind=voice_of_agent_promoted`.

Privacy preservation: aggregation operates only on anonymized fields. Target-repo slugs surface in the operator dashboard only if user explicitly opted in.

## Forward-deployment example (what it looks like at scale)

Three different users running chump on three different target repos:

- User A on `github.com/marcus/example` — agent hits fmt-drift wedge, files VOA-005
- User B on `github.com/anonymous-startup/api` — agent hits same fmt-drift wedge, files VOA-008
- User C on `repairman29/chump` (dogfood) — agent hits same wedge, files VOA-011

Aggregation rule fires: `fmt-drift-queue-wide` now has 3 VOAs in 30 days. The `proposed_fix.existing_gap` field across all three points at INFRA-2120 (preflight-vs-CI parity). INFRA-2120 auto-promotes to P0. Operator picks it up next session.

User A's contribution credit: VOA-005 + (optional) PR they shipped fixing it. Real attribution, real fix, real impact.

## Companion gaps

- **VOA-001** (this session) — retroactive packaging of today's evidence into the VOA format. Schema-defining example.
- **INFRA-2258** — `chump voice` CLI subcommand (writes YAMLs, optional PR submission). Voice-of-Agent protocol Part 1.
- **INFRA-2260** — `chump voice top` + `docs/voice/WEDGE_HEATMAP.md` + 3-VOA-same-class auto-promote. Voice-of-Agent protocol Part 2.

## Cross-references

- `docs/process/SHIP_ASSIST_PLAYBOOK.md` (INFRA-2256, PR #2809) — canonical wedge taxonomy + tooling inventory; the seed corpus VOA reports cite
- `docs/strategy/OFFLINE_ROADMAP_2026Q2.md` (INFRA-2246, PR #2796) — strategic frame for what chump is becoming; VOA protocol is the "how we get there with users contributing" layer
- `docs/process/SHEPHERD_LOOP_PLAYBOOK.md` — Pattern 14 (verify before alarm) is the discipline that prevents VOA spam; Pattern 15 (no idle curators) is what produces VOAs naturally as a byproduct of working
- `docs/process/SUBAGENT_DISPATCH.md` (META-069) — sub-agents can file VOAs too; they're agents

## Maintenance

This protocol doc gets updated whenever:
- The VOA YAML schema evolves (e.g. new required fields)
- The disclosure-mode menu changes
- A new aggregation surface ships (chump voice subcommand grows)
- A privacy incident teaches a new boundary

Schema versioning is via the `chump_version` field in each VOA (records which chump build the agent was running) — there's no global `protocol_version`; the schema floats with chump itself.
