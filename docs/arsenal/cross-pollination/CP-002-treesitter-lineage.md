# CP-002: Tree-sitter lineage — INFRA-1719 vs echeo/src/shredder.rs

**Target:** verify whether INFRA-1719 (shipped 2026-05-23) duplicated echeo's prior art
**Status:** investigation complete (2026-05-23, INFRA-1812)
**Verdict:** **(c) Genuinely different** — both use tree-sitter, but extract different things for different consumers

## Background

The Harvester catalog (`docs/arsenal/GLOBAL_ARSENAL.md`) lists echeo as a known sibling Rust repo but did **not** surface its `src/shredder.rs` as a primitive. INFRA-1719 shipped a brand-new `crates/ast-crawler/` (1031 LOC, 7 languages) on 2026-05-23 — two days after the catalog was first built.

This investigation tests the catalog's flagship value proposition: would Harvester catch a missed reuse opportunity? The honest finding is that **the catalog had a Discovery Failure footprint** (echeo present, shredder not indexed as a primitive) but the two implementations are sufficiently divergent that lineage-borrowing was not the right action anyway. The catalog still failed its job (didn't surface the question for the operator), but the answer to the question it should have raised is "build separately" rather than "vendor."

References:
- INFRA-1719 PR: [#2385](https://github.com/repairman29/chump/pull/2385), commit `db5e07981`, 2026-05-23 09:35 MDT
- echeo `src/shredder.rs`: first added in initial commit `d420751` on 2026-01-01 (5 months before INFRA-1719 shipped)

## INFRA-1719 implementation

Single crate; no echeo references anywhere in source or PR description.

| File | LOC | Languages | Extraction surface |
|---|---|---|---|
| `crates/ast-crawler/src/lib.rs` | 1031 | rust, python, javascript, typescript, go, bash, yaml (7) | Top-level `fn`/`struct`/`enum`/`trait`/`impl` + impl-block methods, `class`, `interface`, `type alias`, `const`/`static`, `mod`, `import`/`use`, first non-blank doc-comment line. YAML special-cased via `serde_yaml`. |
| `crates/ast-crawler/Cargo.toml` | 40 | — | Depends on `tree-sitter 0.25` + 6 grammar crates + `chump-ambient-cli` (for `ast_crawler_unsupported_language` event). |
| `src/main.rs` (call site, lines ~8124–8174) | ~50 | — | `chump gap decompose` extracts path hints from gap description, runs `crawl_paths`, renders `shape.to_prompt_block(6 KiB)`, injects into LLM prompt. `CHUMP_DECOMPOSE_AST=0` opts out. |

Output schema (lib.rs:49–86):
```rust
pub struct Symbol { name, kind: String, line, doc_first_line: Option<String> }
pub struct FileShape { path, language, supported: bool, top_level_symbols: Vec<Symbol>, imports: Vec<String> }
pub struct CodebaseShape { repo_root, generated_at: DateTime<Utc>, total_files, total_symbols, supported_languages: Vec<String>, files: Vec<FileShape> }
```

Key properties: deterministic (sorted, content-hashable), token-budget-shaped via `to_prompt_block(max_bytes)`, no source-byte snippets included (only identifier + line + 1-line doc), no git/blame integration, no authorship metadata, ambient-emit on unsupported extension.

## echeo/src/shredder.rs

Single 568-LOC file paired with `src/authorship.rs` (207 LOC, libgit2-backed blame).

| Dimension | Value |
|---|---|
| LOC | 568 (+207 in `authorship.rs`) |
| Languages | typescript, javascript (via TS parser), rust, python, go (5) |
| Tree-sitter API | older surface: `tree_sitter_typescript::language_typescript()` etc. — pre-`LANGUAGE` const era |
| Extraction kinds | `Function`, `Class`, `ApiRoute` (TS method-decls named get/post/put/delete), `Component` (React/Vue, PascalCase fn/const) |
| Authorship | **yes** — every `Capability` carries `Option<AuthorshipInfo>` with `author_email`, `commit_sha`, `is_self_authored`, `contribution_percentage` (git2 BlameOptions) |
| Code snippet | **yes** — `extract_code_snippet` keeps up to 500 source bytes per capability (for embedding into a vector store) |
| Bash / YAML | not supported |
| Imports | not extracted |
| Doc comments | not extracted |
| Visibility filtering | Rust `pub` check; Go upper-case-first check (`is_uppercase()`) |
| Output | `Vec<Capability>` per file; no top-level `CodebaseShape` aggregate, no `to_prompt_block` |
| Consumer | bounty matchmaker / vector embedding pipeline ("find where your code resonates with market needs") |
| Persistence | none in this file; caller embeds the snippet into a vector store downstream |

Output schema (shredder.rs:13–28):
```rust
pub struct Capability { name, kind: CapabilityKind, line, code_snippet: String, authorship: Option<AuthorshipInfo> }
pub enum CapabilityKind { Function, Class, ApiRoute, Component }
```

## Side-by-side overlap matrix

| Dimension | INFRA-1719 (Chump) | echeo shredder | Overlap? |
|---|---|---|---|
| Languages | rust, python, js, ts, go, bash, yaml (7) | ts, js, rust, py, go (5) | partial (5 shared, bash/yaml Chump-only) |
| Symbol granularity | top-level + impl-block methods | top-level + nested (recursive traversal) | partial |
| Extraction kinds | fn, struct, enum, trait, impl, const, mod, type, class, interface | Function, Class, ApiRoute, Component | minimal — kind taxonomies disjoint |
| Doc-comment extraction | yes (first non-blank line) | no | Chump-only |
| Imports list | yes | no | Chump-only |
| Code snippet bytes | no (line refs only) | yes (≤500 char snippets) | echeo-only |
| Git/blame authorship | no | yes (`AuthorshipInfo`) | echeo-only |
| Output shape | `CodebaseShape { files: Vec<FileShape> }` | `Vec<Capability>` (flat per file) | distinct |
| Token-budget rendering | yes (`to_prompt_block(max_bytes)`) | no | Chump-only |
| Ambient emit on unsupported ext | yes | no | Chump-only |
| Tree-sitter version | 0.25.x (`LANGUAGE` const ABI) | older (`language_typescript()` fn ABI) | incompatible APIs |
| Used by | `chump gap decompose` (LLM prompt context) | bounty matchmaker (vector embedding) | distinct consumers |
| Lines of code | 1031 | 568 (+207 authorship) | — |

## Verdict

**(c) Genuinely different.** Both use tree-sitter to walk source files, but the data they produce, the schemas they emit, the consumers they serve, and even the tree-sitter ABI generation they target are different enough that vendoring one into the other would have been a net cost.

Concrete signals supporting (c):

1. **Schema mismatch.** `CodebaseShape` (deterministic, JSON-serializable, hierarchical aggregate, token-budget rendering) vs `Vec<Capability>` (flat list with embedded source snippets + authorship). Neither schema is a subset of the other; merging them would require dropping load-bearing fields on at least one side.
2. **Consumer mismatch.** INFRA-1719 feeds an LLM prompt — wants minimal tokens, identifiers + line numbers, no snippets. Echeo feeds a vector store — wants source snippets for embedding, with authorship for attribution and bounty payout.
3. **API drift.** Echeo's shredder targets tree-sitter ≤0.24 (`tree_sitter_typescript::language_typescript()` style). INFRA-1719 targets 0.25 (`LANGUAGE` const + `LanguageFn` ABI). Vendoring would have forced echeo's tree-sitter version forward — and brought along the libgit2 transitive dep, which Chump explicitly avoided.
4. **Pillar mismatch.** Authorship/blame is the *point* of echeo (resonance attribution → bounty payout). It is irrelevant to `chump gap decompose`, where authorship would only inflate the prompt without affecting decomposition quality.
5. **Coverage mismatch.** Chump has bash + yaml; echeo doesn't. Echeo has React component detection (PascalCase heuristic) + API-route detection (TS `get`/`post` method names); Chump doesn't.

This is not a story of "Chump reinvented echeo's wheel." It's "two repos under the same operator both reached for tree-sitter for fundamentally different reasons, and built fit-to-purpose code."

**However — the catalog still missed the question.** The Harvester catalog listed echeo as a Rust repo but did not index `src/shredder.rs` as a primitive. If echeo's shredder *had* been indexed under "AST extraction" or "tree-sitter walker", the INFRA-1719 implementer would at least have been prompted to compare before building. That comparison would have arrived at the same verdict (c), but the catalog should be the surface that *raises* the comparison, not the operator's memory.

## Action items

- File **INFRA-NEW-HARVESTER-INDEX-PRIMITIVES** (P1/m): index per-file primitives, not just per-repo metadata. Schema additions: `(repo, file, primitive_name, dependency, summary_line)`. Surfacing rule: when a gap reaches for `tree-sitter` / `git2` / `nats` / `sqlite` etc., the catalog should be able to answer "what other repos in the arsenal already do this?" before code is written. The 2-day gap between catalog-build (2026-05-21) and INFRA-1719-ship (2026-05-23) is the exact window where this surface would have fired.
- Document the divergence in `docs/arsenal/HARVESTER.md` under a new **"Known parallel implementations"** section: list `chump/crates/ast-crawler` and `echeo/src/shredder.rs` together with the (c)-verdict rationale above, so future readers (and the catalog itself) don't mistake them for duplicates and don't waste a future investigation re-running this analysis.
- **No** lineage header on `crates/ast-crawler/src/lib.rs`. Adding "vendored from echeo" would be misleading — INFRA-1719 was not derived from shredder.rs.
- **No** consolidation gap. Merging the two would require schema decisions that hurt both consumers.

## Lineage / Risk

What could change this verdict:

- If a future gap asks "Chump's `chump gap decompose` should attribute prompt-relevant code to specific authors for cost allocation" or "embed source snippets for the LLM-context vector store" — that's the moment to revisit. At that point echeo's `Capability` + `AuthorshipInfo` shape becomes directly load-bearing, and the right move is to lift them into a shared `chump-ast-shared` crate consumed by both.
- If tree-sitter ABIs converge (echeo upgrades to 0.25), the cost of a shared crate drops materially.
- If a third repo in the arsenal lands a tree-sitter walker, the (c) verdict flips to (b) Reinvention by virtue of the third repo proving the pattern is general — at that point file a consolidation gap.

Re-evaluation cadence: revisit when the next tree-sitter-touching gap lands, or quarterly with the Harvester refresh, whichever comes first.
