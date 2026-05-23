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

## Phase-0 addendum — manual language scan of `echeo` (2026-05-23 06:35Z)

Per orchestrator suggestion, ran a fast `tokei` pass against the cloned
`repairman29/echeo` working copy ahead of INFRA-1719 (AST crawler)
landing. Goal: surface language-coverage blind spots before the full
`chump ingest` flow lights up. Findings rewrite three claims from the
body above; one new policy question opens up.

### Real language distribution (tokei against the working tree)

| Language | Files | Code lines |
|---|---|---|
| JSON | 7 | **175,187** |
| Rust | 10 | 3,026 |
| Markdown | 8 | 0 (1,420 comments) |
| Python | 3 | 1,300 |
| JavaScript | 3 | 369 |
| Shell (Bash) | 5 | 311 |
| TOML | 1 | 37 |
| Dockerfile | 1 | 9 |
| **YAML** | **0** | **0** |

**Source-code total (Rust + Python + JS + Shell + TOML + Dockerfile): ~5,052 lines.** Still inside the 2k-15k window the rubric called for.

### Three corrections to the body

1. **The body said "5 languages."** Reality is **4 of Chump's 6 supported languages** present (Rust, Python, JavaScript, Bash via Shell — no YAML, no Go). Plus TOML, Dockerfile, Markdown, JSON as non-supported but present formats. The 3+ language-mix gate still passes (4 of 6 > 3), so the 15/15 score holds — but the per-language detector strategy needs to drop YAML emphasis entirely.

2. **The body said LOC = 6,319.** Tokei's source-line count (~5,052) is ~20% lower because it excludes Markdown comments and the JSON catalog files. The earlier estimate came from a bytes-per-LOC heuristic (`gh api .../languages` returns bytes, not lines) that miscalibrated against repos with large fixture files. **Both numbers are inside the 2k-15k sweet spot.**

3. **The body said the Bash detector "needs to find SOMETHING in echeo but not produce the headline finding."** Echeo has 5 shell files (311 lines) — meaningful enough that a thoughtful Bash detector can produce a real secondary finding (e.g. dead scripts, missing `set -euo pipefail`, etc.). Don't under-invest in Bash on the assumption it's a token slice.

### New question this surfaces — JSON policy for `chump ingest`

The 175,187 lines of JSON aren't a measurement quirk. They're 3 catalog files under `docs/repo-catalog/` (TOP_REPOS_WITH_CODE.json @ 77k, COMPLETE_CATALOG_FIXED.json @ 72k, COMPLETE_CATALOG.json @ 24k) — generated repo-discovery snapshots, not hand-written code. Three policy choices for the demo:

| Policy | What the demo shows | Cost |
|---|---|---|
| **(a) Ignore data-fixture JSON** (matches gitignore-style heuristic: large, generated-looking, in docs/) | Clean demo, focuses on source code | Risk: viewer asks "what about the JSON?" and we have no answer |
| **(b) Index the JSON as structured data** (schema-extract, surface as a separate "data assets" artifact) | Differentiated finding: "Chump understood your fixtures" | Real engineering — needs a JSON-schema-inference detector that doesn't exist yet |
| **(c) Defer to operator decision at ingest time** (interactive prompt: "Index this 76k-line JSON file?") | Honest UX | Bad screencast — viewer sees a prompt and loses the magic |

**Recommended Phase-0 policy: (a) — ignore large generated JSON in `docs/repo-catalog/`**. Cleaner demo arc, and the JSON catalog files in echeo specifically are out-of-scope for any value-add Chump would offer. **File a follow-up gap to add (b) capability as a Phase-2 differentiator once the basic demo lands.**

### Week 2 design defaults — updated

The body's per-language detector priority (Rust > Python > JS > Bash + YAML lighter) gets a small revision:

| Old | New | Why |
|---|---|---|
| Rust | Rust (unchanged) | echeo's load-bearing core |
| Python | Python (unchanged) | ML/embedding scripts |
| JavaScript | JavaScript (unchanged) | npm install shim |
| Bash + YAML lighter | **Bash second-secondary** | 5 files / 311 LOC — real surface |
| (YAML implied) | **YAML deprioritized to zero for echeo demo** | 0 files; investing in YAML detector earns no echeo signal |
| (JSON not addressed) | **JSON: implement (a) policy — ignore docs/repo-catalog/** | Plus follow-up gap for Phase-2 (b) |

### Pre-flight (INFRA-1778) still required

This Phase-0 scan does NOT replace the auth pre-flight. INFRA-1778
verifies push access, cloneability, and per-file edge-case handling.
This addendum confirms language SHAPE is well-suited; pre-flight
confirms Chump can actually ACT on the repo.

### Phase-0 follow-up after #2385 lands

When [#2385](https://github.com/repairman29/chump/pull/2385) (INFRA-1719 AST crawler) lands, re-run the same scan with the AST-crawler tool against `/tmp/echeo-phase0-scan`. Compare deltas — places where the AST crawler finds structure that tokei misses, or vice versa. Append a second addendum to this doc. If AST crawler surfaces a true blocker (e.g. parse failures on echeo's Rust workspace layout), promote the next fallback (`daisy-chain`) and re-record here.

## Phase-0 pass-2 — AST crawler scan of `echeo` (2026-05-23 16:30Z)

#2385 (INFRA-1719) merged at 15:35Z. Ran `chump_ast_crawler::crawl_repo`
against `/tmp/echeo-phase0-scan` via a throwaway example program; output
captured here.

### Cross-check: AST crawler vs tokei (pass-1)

| Language | tokei files | AST files | tokei lines | AST symbols |
|---|---|---|---|---|
| Rust | 10 | 10 | 3,026 | **119** |
| Python | 3 | 3 | 1,300 | **34** |
| JavaScript | 3 | 3 | 369 | **27** |
| Bash | 5 | 5 | 311 | **0** |
| (unknown / unsupported) | n/a | 18 | n/a | 0 |
| **TOTAL** | 21 supported | 21 supported | 5,006 | **180** |

**File counts cross-check exactly: 10/3/3/5.** No ghost files, no skipped trees.

### Two real findings the pass-1 tokei pass couldn't surface

#### Finding A: Bash via AST crawler extracts **zero symbols**

Tree-sitter-bash IS active and the 5 echeo shell files ARE parsed, but the crawler's top-level-symbol extraction returns 0 for every Bash file. Bash doesn't carry "top-level symbols" the way Rust/Python/JS do — there are no `pub fn`, no exported classes, no module exports. Functions in shell are anonymous-by-convention until called.

**This contradicts the pass-1 recommendation** to "promote Bash to second-secondary." The AST crawler can't produce a Bash insight on echeo through its symbol-extraction path. **Revised pass-2 verdict**: Bash detector for the echeo demo needs a **non-AST strategy** — file-text heuristic scan (looks for `set -euo pipefail`, missing error handlers, hard-coded paths, etc.) — OR Bash gets deprioritized to "tertiary, only if surplus token budget." Filed as a Week-2 design question; the Phase-0 doc revises Bash priority back to **tertiary**.

#### Finding B: Rust dominates symbol density 66% of the supported total

| Language | Symbols | % of supported total |
|---|---|---|
| Rust | 119 | 66% |
| Python | 34 | 19% |
| JavaScript | 27 | 15% |
| Bash | 0 | 0% |

The Week-2 design call ("Rust-first per-language detector") was correct on file/LOC count but **confirmed even more strongly by symbol density**. Rust's symbol-per-file (11.9) is ~3× Python's (11.3) and ~3× JS's (9.0) — wait, those are close per-file. The asymmetry is in absolute volume: Rust has more files AND more symbols-per-file.

**Implication**: Chump's primary `chump ingest echeo` artifact should lead with the Rust shape (module-map, function listing, cargo deps) because **66% of the symbol-evidence the LLM gets to act on** comes from Rust. Python and JS findings should be secondary. Bash needs its own track (per Finding A).

### Concrete artifact shape (what the demo will produce)

The AST crawler's `to_prompt_block(6 KiB)` output is the actual LLM-input format Chump will use. Sample structure from echeo (lightly redacted for length):

```
Codebase shape (deterministic AST crawl, 39 files, 180 symbols, langs: bash, javascript, python, rust):

src/matchmaker.rs [rust]
  imports: anyhow::Result, serde::{Deserialize, Serialize}, ...
  L8: struct Matchmaker — / THE MATCHMAKER: Connects capabilities to bounties using vector similarity
  L13: struct Need
  L22: struct Match
  L29: impl Matchmaker
  L30: fn new
  L35: fn cosine_similarity — / Calculate cosine similarity between two vectors
  L53: fn calculate_ship_velocity_score — / Calculate Ship Velocity Score
  L109: fn match_need
  L142: fn match_needs
  ...
```

Symbol kind + line number + doc-comment first line. **This is what the screencast will show as "Chump understood your repo in 2 seconds."** It's legibly skimmable and language-agnostic at the surface level.

### What this addendum changes (vs pass-1)

| Pass-1 said | Pass-2 says |
|---|---|
| Bash promoted to second-secondary (5 files / 311 LOC) | **Bash demoted back to tertiary** — AST symbol extraction returns 0 for Bash; either invest in a non-AST Bash auditor or deprioritize |
| Rust-first detector priority (file/LOC based) | Rust-first **confirmed** — 66% of total symbol density |
| Artifact shape: "optimize for Rust module-map / cargo deps tree" | **Concretized**: the `to_prompt_block` text is the artifact. Lead with Rust files; show symbol + import listings per file |
| Will use the AST crawler when #2385 lands | ✓ done — pass-2 captures the actual output |

### Hard blocker check — passed

The crawler completed against echeo without parse failures across all 4 supported languages. No echeo-specific edge case surfaced. **No need to walk the fallback ladder.** echeo remains the primary; the strategy doc stands.

### Throwaway tooling note

The pass-2 scan used `crates/ast-crawler/examples/dump-shape.rs` — a temporary example program that calls `crawl_repo` and prints the shape. It is NOT meant to be part of the long-term API surface. A proper operator-facing `chump ast-shape <repo>` subcommand belongs to a follow-up gap (file under Week-2 tooling); the throwaway can be removed once that lands. This addendum's findings stand independently of whether the example file is kept or pruned.
