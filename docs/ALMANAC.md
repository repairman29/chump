# Almanac protocol — the fleet reference desk

How any Chump agent (any harness) answers questions about code that exists
across the ~95-repo fleet: "have we built X", "which repo does Y", "what's the
exact signature", "what breaks if I touch this", "how is repo Z shaped".

Almanac is the grounded multi-repo index. Every answer carries a
`repo:path:line` citation. Standing order (workspace CLAUDE.md): fleet code
questions go to Almanac BEFORE grep or agent fan-outs.

## Surfaces

1. **CLI (harness-neutral, canonical):** `~/Projects/almanac/target/release/almanac`
   — subcommands `search`, `search-fleet`, `api`, `impact`, `architecture`,
   `neighbors`, `stats`, `repos`, `coverage`, `usage`, `gc`. Bare runs resolve
   inference via the `~/.almanac` machine config (helsinki as of 2026-08-01;
   env overrides). `--help` on any subcommand.
2. **MCP server `almanac`** (wired via `chump-mcp.json`, for MCP-capable
   harnesses): `almanac_search_fleet`, `almanac_search`, `almanac_api`,
   `almanac_impact`, `almanac_architecture`, `almanac_neighbors`,
   `almanac_status`, `almanac_comprehend`, `almanac_why`. Same index, same
   answers — except the last two, which read the live CHECKOUT (organs use
   the filesystem; `why` uses git blame), so they are current but slower, and
   a remote-cached repo with no worktree cannot answer them.

## Pick the tool by question shape

| Question shape | Tool | The thing to know |
|---|---|---|
| "Have we built X?" / "which repo does Y?" | `almanac_search_fleet` / `search-fleet` | Keyword across ALL repos, symbol-level, ranked cross-repo. |
| Deep or conceptual question in ONE repo | `almanac_search` / `search` (with repo) | Default fusion (89% hit@5 in eval). Response `mode_used` + `granularity` say what actually ran — read them. |
| "Exact signature / how do I call it?" | `almanac_api` / `api` | Verbatim signature + doc + a real cited usage. Copy the real API; never invent one. |
| "What breaks if I change this file?" | `almanac_impact` / `impact` | Transitive importers, level by level. LOWER BOUND — the `note` says how many edges resolved. |
| Orienting in an unfamiliar repo | `almanac_architecture` / `architecture` | Instant + structural (modules, cross-module edges, hub files). Call FIRST, then search deep. |
| One file's dependency picture | `almanac_neighbors` / `neighbors` | Imports / imported-by / unresolved externals. |
| "Why does this line exist?" (before deleting/rewriting) | `almanac_why` / `whymap` | The commit + gap/issue refs that introduced it, and what to check first. The anti-Chesterton's-fence lookup. An unblameable line says so rather than inventing a reason. |
| "Is it wired? What gates it? What flags govern it?" | `almanac_comprehend` / `comprehend` | WIRING + GATES + CONFIG organs in one call. EVERY organ states its own coverage and a partial map warns — outside Rust, `gate=none-recognized` means no guard of a KNOWN SHAPE was found, NOT "unprotected". |
| "Can I trust these results?" | `almanac_status` / `stats` | Grounding commit vs current HEAD, stale flag, row counts. Call before load-bearing answers. |

## Trust rules — each one encodes a real incident

1. **A zero-hit is a claim, not a fact.** Read the response's `note` /
   `fallback_reason` / warnings before repeating it — degradation is loud by
   design (2026-08-01 hardening). Only a clean zero-hit means "not in the
   index," and even then check the blind-spot list below.
2. **Check grounding before load-bearing answers.** The index is a snapshot at
   a commit; HEAD may have moved. Crons exist (refresh :00, discover-new-repos
   :15) but verify with `almanac_status`, don't assume. Receipt: Chump spent a
   week querying a frozen Jul-26 src/-only snapshot before the wiring was fixed
   (2026-08-04).
3. **A fusion label can hide a keyword answer.** Fusion's two semantic legs only
   fire on embedded+summarized rows, so a half-fed repo answers keyword wearing
   a fusion label. `almanac coverage` lists which repos have a real semantic
   layer; per-response, trust `mode_used`.
4. **Docs rank below code even when indexed** (INFRA-3529). And markdown was
   structurally invisible until 2026-08-02 (almanac#3 — three stacked bugs). If
   a doc you KNOW exists doesn't surface: try keyword mode, then re-index +
   re-summarize that repo.
5. **SQL is not indexed at all** (INFRA-3530). Schema / RLS / migration
   questions go to Supabase (MCP or CLI) against the live schema, never to
   Almanac. A SQL zero-hit means nothing.
6. **Multi-word keyword queries OR-tokenize** (fixed 2026-08-01). A hit may
   match one term, not all of them; scoring ranks multi-term matches up. Skim
   the hit before declaring "found it."
7. **The index locates; the file testifies.** Before asserting what code DOES,
   read the cited file at the citation. Snippets and summaries are pointers,
   not ground truth — and the working tree may have uncommitted changes the
   index never saw.
8. **CONFIG-organ DRIFT no longer over-claims on benign spelling variance**
   (INFRA-3472, almanac#7). Before the fix, an unset default spelled `""` in
   one call site and `"(unset)"`/`"None"` in another — or a dynamic
   per-process placeholder like `AGENT_ID:-$$` reading differently at every
   call site — each counted as N conflicting defaults. `normalize_default()`
   in `almanac-organs/src/config.rs` canonicalizes only known-equivalent
   spellings (unset sentinels -> `""`, dynamic expressions -> `<dynamic>`)
   before dedup/count, and never splits a multi-value default (e.g. a CSV
   allowlist) into per-element pieces. Genuine conflicting static literals
   still report as real drift.

## Latency shaping (measured 2026-08-06, Apple Silicon)

- Repo-scoped keyword ≈ **9ms**. Repo-scoped semantic ≈ **1.2s** (the
  query-embedding round trip is nearly all of it). Fleet-wide keyword ≈
  **2.5–4s** of real compute, not startup.
- Therefore: keyword-first for lookups; fusion/semantic for conceptual asks;
  fleet-wide only when the repo is unknown. All of it fits inside one voice
  exchange.

## Voice contract (Siri / spoken turns)

Ported from olive's `VOICE_ADDENDUM` (`olive:src/lib/agent/orchestrator.ts:63`
— production-tested; read-aloud formatting is the enemy). When the reply will
be READ ALOUD:

- 1–3 short sentences. Never markdown, never bullets, never enumerate a hit
  list aloud.
- Speak the VERDICT + count + repo names: "Yes — built three times: beast-mode,
  olive, and smuggler. Receipts are in the log."
- **Never speak a file path or line number.** Receipts (`repo:path:line`) go to
  the turn log / screen. The spoken sentence is not the evidence; the citations
  are (shop rule 1: facts over vibes).
- Only numbers a tool returned THIS turn — no arithmetic, no recalled figures.
- **Two-speed rule:** if the honest answer needs deep work (multi-file reads,
  an impact walk, anything agentic), speak what the quick keyword pass found
  plus "still digging — ask me again in a minute," and keep working
  server-side. Never leave Siri hanging past a few seconds.

## Not Almanac's job

- **Live state** (deploys, DNS, published pages): verify in a browser —
  dashboards lie (shop rule 2).
- **Database schema/RLS**: Supabase (INFRA-3530, rule 5 above).
- **Uncommitted work**: the index sees commits, not working trees — use git.
- **Non-git directories**: invisible to discovery forever unless explicitly
  registered (the opportunity-library blind spot, fixed 2026-08-05 as
  workspace-docs). If a whole PROJECT seems missing, check `almanac repos`
  before concluding anything.

## Mining the zero-hit log (EFFECTIVE-380)

Every almanac CLI/MCP call appends to `~/.almanac/usage.jsonl` (surface,
tool, repo, query, `hits`, mode, duration — schema in
`crates/almanac-core/src/usage.rs`), and a **zero-hit is a question the
fleet actually asked, in its own words, that the index could not answer** —
free capability-backlog signal, if it's ever read.

`scripts/dev/almanac-zero-hits.py --log ~/.almanac/usage.jsonl` (add
`--json` for machine consumption) clusters zero-hit queries into ranked
themes and classifies each as:

- **`unsupported-artifact`** — the query names SQL (INFRA-3530, deliberate
  deferral) or an unindexed source language (CREDIBLE-210 class: swift/
  kotlin/c/cpp/ruby/java).
- **`retrieval-miss`** — a proximity `git grep` against this checkout found
  >= 2 of the query's distinctive words within 6 lines of each other, i.e.
  the content exists and the miss is a quality bug, not absence.
- **`absent`** — neither of the above matched; treated as genuinely missing
  unless a human spots evidence the heuristic couldn't reach.

Every cluster states its classification method inline so a reader can
disagree — the `git grep` proximity check is a coarse proxy (see
[`ALMANAC_ZERO_HITS_FIRST_RUN.md`](observability/ALMANAC_ZERO_HITS_FIRST_RUN.md)
for a worked false-positive example) and should be read as a triage aid
over the raw log, not an oracle.

This tool is **chump-side**, not almanac-side: the almanac CLI/binary itself
lives in the separate repairman29/almanac repo, which isn't guaranteed to be
checked out in every chump worktree. `usage.jsonl`'s format is a stable,
documented, append-only contract any consumer can read without the almanac
binary being present.

## Census: duplicate-implementation detection (EFFECTIVE-391)

A single `search-fleet` query for "retry exponential backoff" (2026-08-07)
returned implementations in a dozen repos — several of them provably the
SAME code (same symbol, same line), not convergent design. `smugglers/
shared-utils/retry-patterns/` proves an extraction ALREADY happened and
never propagated to `bulwark`, which still carries its own copy. That is
the fleet's latent-value shape: not missing capability, unpropagated
capability.

`scripts/dev/almanac-census.py "<concept>"` turns a keyword hit-list into a
census: one row per capability (grouped by exact symbol name), literal
copies flagged by structural identity (same symbol + same start line;
`verbatim` when the relative path also matches, `moved` when it doesn't —
a copy can survive a path change even when the symbol/line don't), an
extractability score built from real `almanac impact`/`neighbors` data
that refuses to score on partial inputs (states exactly which of
importer-count / coupling / test-presence it couldn't get), and a named
"already extracted, N repos have not adopted it" call-out when a site's
path matches a shared/common-library convention.

```bash
python3 scripts/dev/almanac-census.py "retry exponential backoff" [--json]
# offline / CI: python3 scripts/dev/almanac-census.py "<concept>" \
#   --fixture scripts/dev/fixtures/almanac-census-retry-example.json
```

Chump-side, same posture as the zero-hits miner above. **Honest about
vocabulary**: `search-fleet` is keyword-only, so this groups strictly by
exact symbol name — differently-named implementations of the same idea
never merge into one row. Every report states its `retrieval_mode` and
carries the fleet's last known embedding-coverage percentage so a reader
knows how much of the fleet that blind spot still covers.
