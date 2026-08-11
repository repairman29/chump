---
chair: publisher
department: RUN/publication
status: dormant
class: publication
route_keywords: [shipped, launch, announce, tell, untold, release, publish, told, unknown, market]
owns: launch-post
gate: captain-approved-and-posted
driven_by: [EFFECTIVE-364, EFFECTIVE-365]
mines: beast-mode/PRODUCT_HUNT_POST.md + LAUNCH_CHECKLIST.md ; herald agent ; PUBLISHER.md
staffed_by: nobody (the #1 open chair)
last_verified: 2026-08-11
---
# Publisher

**One-line:** turns a finished, audited product into per-platform launch posts, gets
the captain's approval, posts them, and tracks the response.

## Jobs to be done (each = one typed artifact → one gate)

| Job | Input | Output (typed artifact) | Gate |
|---|---|---|---|
| Draft launch posts | a shipped, audited product + its receipts | `launch-post` per platform (Show HN, r/webdev, LinkedIn, the captain's Substack/FB) | captain-approved (voice + facts) |
| Post them | approved posts | published URLs | **captain clicks send** (human only on the irreversible) |
| Track the response | published URLs | `launch-report` (traffic, signups, comments) | feeds Analytics |

## Human vs. AI split
- **AI (this chair):** research the receipts, draft in the captain's voice, stage
  each platform, assemble the tracking report.
- **Human (captain):** the voice check, the go/no-go, and the actual **send** — the
  one irreversible click never automates (DOC-089's productization bar).

## Mine, don't build
- `beast-mode/PRODUCT_HUNT_POST.md` + `LAUNCH_CHECKLIST.md` — real, usable launch copy + checklist.
- `beast-mode/.github/workflows/publish-extension.yml` — a working publish pipeline to generalize.
- the fleet `herald` agent (`.claude/agents/`) + `PUBLISHER.md` — the draft engine already exists.

## To go from `dormant` → `online`
Work EFFECTIVE-364/365: wire draft→approve→post→track as gated gaps the running fleet
executes, prove it on **Olive's** launch (customer 0), then it's a "publish-your-
product" capability someone else can run.
