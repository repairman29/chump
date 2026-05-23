# Column A demo target — repo selection (2026-05-23)

> **Decision-of-record.** Names the ONE repo Chump's first end-to-end
> "ingest an unfamiliar repo and add value" demo will run against.
> Gates every Week 2 design choice (which language gets attention,
> what artifacts will look impressive, what tooling surfaces matter).
> Reviewed by: operator (Jeff). Drafted by: Opus curator under
> META-069 discipline (Sonnet did the per-repo data gather; Opus does
> synthesis + final call).

## TL;DR

**Primary target: `echeo`** (`github.com/repairman29/echeo`).

- 6,319 LOC across **5 languages** (Rust, Python, JavaScript, Bash, YAML)
- Last operator push **2026-04-07** (45 days cold; past the 7-day hard gate)
- Pitch: *"Find where your code resonates with market needs"* — readable in one breath
- Scores **15/15** against the 6-criterion rubric

If pre-flight (INFRA-1778) finds a blocker on `echeo`, fall back in order:

1. **`daisy-chain`** (4-month cold; safest unfamiliarity; weaker pitch)
2. **`echeo-internal`** (sibling of echeo; older; similar shape)
3. **`olive`** (best domain contrast for screencast; loses one criterion on language mix)

## Scoring matrix

| Repo | Lang mix (0-3) | Size (0-3) | Age (0-3) | Push (0-3) | Demo-watch (0-3) | Total | Last push | LOC est. | Top languages |
|---|---|---|---|---|---|---|---|---|---|
| **echeo** | 3 | 3 | 3 | 3 | 3 | **15** | 2026-04-07 | 6,319 | Rust, Python, JavaScript, Bash, YAML |
| upshift | 3 | 1 | 3 | 3 | 3 | 13 | 2026-04-10 | 25,192 | TypeScript, JavaScript, YAML |
| daisy-chain | 3 | 3 | 3 | 3 | 1 | 13 | 2026-01-25 | 11,263 | JavaScript, YAML, Bash |
| echeo-internal | 3 | 3 | 2 | 3 | 2 | 13 | 2026-01-31 | 7,174 | Rust, Bash, JavaScript |
| olive | 1 | 3 | 2 | 3 | 3 | 12 | 2026-02-27 | 7,101 | TypeScript, JavaScript, YAML |

Criteria (recap from the brief):

1. **Language mix** — at least 3 of (Rust, Python, JS/TS, Go, Bash, YAML). 3-4 is sweet spot.
2. **Size** — 2k-15k LOC. Below trivial, above hard-mode.
3. **Age / activity** — 3-12 months of real history. Surfaces conventions without architectural churn.
4. **Push access** — must own or have push. Hard gate.
5. **Demo-watchability** — domain explicable in 30s for screencast.
6. **Familiarity (inverted, hard gate)** — operator must NOT have pushed in the last 7 days; 30+ days cold is ideal.

## Why echeo (over the rest)

### What echeo has that the runners-up lack

**5 languages, each load-bearing.** Rust runs the CLI core (`src/main.rs`, 10 files). Python handles embeddings and the ML scripts (3 files). JavaScript provides an npm install shim. Bash drives build + integration (5 files). YAML carries CI workflows (2 files). Every supported language has a real role — not a `.bashrc` and a `LICENSE.md` thrown into the count. When Chump's per-language detectors run, four of them will have meaningful matches and one will find nothing — exactly the contrast that makes the demo legible.

**Size is dead-center.** 6,319 LOC. Above 2k means there's real structure for Chump to discover (modules, build pipeline, CI). Below 15k means a human reviewer can verify Chump's claims by reading the actual code in finite time during the screencast.

**The pitch reads in one breath.** README opens with *"Mission: Find where your code resonates with market needs."* A viewer who's never seen this repo can repeat the sentence back after one watch. Contrast with `daisy-chain` (generic JS template README — what does this thing DO?) or library crates with arcane domain pitches.

### The honest concerns (and why I'm overriding them)

**Concern 1 (Sonnet, flagged): "echeo is too thematically close to Chump itself."** Both are AI-dev-tools, both Rust-heavy. Risk that the screencast reads as *"Chump improves a Chump-shaped repo"* rather than *"Chump tackles the unfamiliar."*

**Override:** The unfamiliarity is real. 45 days since touch + 16 total commits + Jeff's stated "many repos" cadence means the repo IS strange to him in the way that matters for the demo. The screencast can frame this explicitly: *"This is a small Rust CLI I built 4 months ago. I don't remember half of it. Let's see what Chump finds."* That framing turns the adjacency into a strength — viewers see a developer rediscovering their own code, which is more relatable than ingesting a stranger's repo.

**Concern 2 (Sonnet, flagged): "Familiarity edge — 45 days is just past the 30-day ideal."** 

**Override:** The criterion language is *"30+ days is ideal."* echeo qualifies. The 16-commit count over 3 months tells us Jeff was not deeply embedded — this was a side experiment, not a daily driver. Compare `daisy-chain` (4 months cold) where the colder familiarity is bought at the cost of a screencast-incompatible README.

**Concern 3 (not flagged by Sonnet, surfaced in synthesis): "What if Chump's first run on echeo surfaces something embarrassing about Jeff's code?"** 

**Override (and a positive framing):** That's good content. The demo is more interesting when Chump's first PR is a real finding, not "we ran clippy and it's clean." Jeff's 4-month-old side project is statistically going to have a real bug, a dead import, a stale dep, or a misleading comment. Chump SHOULD find that. Lean into it.

## Fallback ladder

Used in order when pre-flight (INFRA-1778) reports a blocker on the primary.

### 1. `daisy-chain` (score 13/15)

- **Why use:** coldest available — last push 2026-01-25, ~4 months. Maximally unfamiliar.
- **What we lose:** README is the generic "high-quality JavaScript project" template. Hard to explain the domain in 30s without reading the code. The screencast either skips the "what is this repo" section (jarring) or burns 60s on a hand-written intro (kills momentum).
- **Use when:** post-pre-flight discovers Jeff actually remembers echeo well, OR the Chump–echeo adjacency feels too inbred on a second look from a fresh viewer.

### 2. `echeo-internal` (score 13/15)

- **Why use:** sibling of echeo. Same description, similar shape, but **older** (2026-01-31 last push, ~4 months cold). Slightly fewer total languages but still hits the 3+ gate.
- **What we lose:** marginal demo polish vs echeo; slightly lower demo-watchability (less polished README).
- **Use when:** echeo specifically has a blocker (e.g. `chump ingest` errors on a unique echeo file format) but the broader shape works.

### 3. `olive` (score 12/15)

- **Why use:** **best screencast-storytelling repo** in the candidate pool. Pitch is *"Kroger grocery list app"* — every viewer instantly groks it; the domain contrast against Chump is maximum.
- **What we lose:** fails the language-mix criterion. Only 2 of the 6 supported languages have real presence (JS/TS + YAML). Bash and Python detectors will find nothing meaningful, which may make the demo feel narrower than the team-wide language story we want to tell.
- **Use when:** all three above are blocked AND the story-arc concern outweighs the language-coverage demo.

### 4. `upshift` (score 13/15) — *deliberately demoted*

- 25k LOC is 67% over ceiling. Would be the most-polished pitch ("AI fixes your dep upgrades") if we had time budget for the bigger repo. Cite this as the future "Phase 2" demo target once the first one lands — `upshift` becomes the upgrade story.

## What this gates (Week 2 design choices)

Because we're going with echeo, these become defaults:

1. **Per-language detector quality bar**: Rust gets the heaviest investment for Week 2 (echeo's core), then Python (ML scripts), then JS (npm shim). Bash + YAML detectors can be lighter — they need to find SOMETHING in echeo but not produce the headline finding.
2. **Artifact shape**: the first `chump ingest echeo` output will be heavily judged on the Rust-side analysis. Make sure the Rust artifact (module map, cargo deps tree, function-level summaries) is the visually-strongest output.
3. **Tooling surfaces that matter**: `chump ingest` must handle a Rust workspace with a `Cargo.toml`, a Python subdir with `requirements.txt`, and a CI workflow YAML — those are the three surfaces echeo exercises.
4. **Failure-mode coverage**: write the Rust-on-Cargo-workspace error paths first; Python-on-pip-requirements second.

## Pre-flight gate (must pass before demo)

Run **INFRA-1778** (chump ingest pre-flight) against echeo as the next concrete step:

- Verifies push access from Jeff's keyring
- Checks repo cloneability
- Confirms language detection matches the scoring table above
- Surfaces any one-off file formats that would block ingestion

If pre-flight reports a hard blocker, walk down the fallback ladder. Re-record the chosen target here.

## Out of scope (deliberately)

- **Choosing the demo intent** (what Chump WILL do once it has ingested echeo). That's a separate document. This one only picks the target.
- **Screencast script.** Week 4 deliverable. The repo choice constrains it but doesn't write it.
- **Multi-repo demos.** Phase 2. `upshift` is parked there.

## Process notes

Sonnet ran the per-repo data gather (`gh repo list` + per-repo `gh api repos/.../languages`, scored against the 6-criterion rubric, returned a top-5 matrix). Opus did the synthesis: validated the scoring against the criterion definitions (caught that `olive` legitimately fails the 3-language gate because JS/TS is one criterion-category), surfaced concerns Sonnet hadn't (the embarrassing-finding framing), picked the winner, ordered the fallbacks.

META-069 discipline: implementation-grade data work delegated; judgment-grade picks held by Opus.
