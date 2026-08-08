# WHEN TO CRATE — the build-speed extraction doctrine

**One sentence:** Rust compiles and caches per *crate*, not per *file*, so the size of a
crate is the cost of recompiling it — and the `chump` bin is one ~190k-line crate that
recompiles wholesale on every change. This doc is the doctrine for pulling coherent
subsystems out of the bin into their own library crates so they compile once and stay
cached. **Keep the bin thin.**

Worked examples this doctrine is distilled from:
- **EFFECTIVE-394** → `crates/chump-verify` (pr_ac_coverage + external_verify_merge + confidence)
- **EFFECTIVE-399** → `crates/chump-atomic-claim` (atomic_claim + autonomy_level + worktree_build_cache)

---

## Why this matters (the mechanical fact)

`cargo` is incremental at the **crate** boundary. Touch any one file in a crate and the
*whole crate* recompiles. The `chump` binary is a single crate whose `src/` is ~190k lines
(main.rs alone is ~19k). So a one-line change anywhere in it pays the full-bin recompile:
warm-incremental is tens of seconds, and a **cold** build (fresh CI runner, fresh
worktree, post-dependency-bump) is ~5 minutes. That cold cost is paid by:

- **CI** on every PR (three required checks, each a build)
- **release / `cargo install`** deploys
- **every fresh agent worktree** that has to build before it can work

Every subsystem we move into its own crate is a subsystem that **stops being recompiled**
when the bin changes. The 28 crates already in `crates/` cache independently today; the
bin is the last big monolith. Shrinking it is the highest-leverage speed win we have.

**The payoff compounds; one extraction is modest.** A single cut of a 190k-line bin barely
moves the warm-incremental number. The win is (a) cumulative across a wave of extractions
and (b) largest exactly where it hurts most — cold builds in CI, deploy, and fresh
worktrees, where the extracted lines are now a cached dependency instead of source.

---

## WHEN to extract (all three should hold)

1. **It's a coherent subsystem.** A named thing with a clear boundary (a command, an
   engine, a store, a cache) — not a random pile of functions. If you can't name the crate
   in two words, it's not ready.
2. **It's big enough to matter.** Rule of thumb: **≥ ~1,500 lines**, or a tight cluster of
   files that always change together and sum to that. Below that the per-crate overhead
   (Cargo.toml, a compile unit, a dependency edge) isn't worth it — a 200-line module
   should stay in the bin.
3. **Its coupling is LOW and OUTWARD-measurable.** Few **outbound** `crate::` references
   (the module calling *into* the rest of the bin). Inbound references (the bin calling
   *into* the module) are fine — the re-export trick (below) makes them free. Measure
   coupling with grep, and confirm with the compiler; **do not trust almanac** for this
   (see the coupling-authority rule).

## WHEN NOT to extract (yet)

- **Heavy outbound coupling.** If the module calls into many still-in-bin modules
  (`crate::a`, `crate::b`, `crate::c`, …), a library crate literally can't reach them —
  library crates can't call back into the bin. Extract the **shared foundation** those
  things live in *first*, then come back. Forcing it produces a broken build; **report the
  coupling evidence and stop** instead.
- **Circular dependency.** If A needs B and B needs A, splitting them just moves the cycle
  to the crate graph, which Cargo rejects. Break the cycle (usually by extracting a third
  "shared types" crate) before splitting.
- **Too small** (see threshold above).

**Leaf-first, bottom-up.** Extract the low-coupling leaves before the tangled hubs. Build a
shared foundation crate before the subsystems that depend on it. Save the most-referenced,
most-referencing modules (e.g. `improve`, `provider_cascade`, `web_server`) for **last** —
by then their dependencies are already crates and the cut is clean.

---

## THE RECIPE (proven on 394 + 399)

1. **Measure coupling.** For the target file(s):
   ```bash
   grep -oE 'crate::[a-z_]+' src/<mod>.rs | sort | uniq -c   # outbound deps
   grep -rn '<mod>' src/ src/commands/                       # who calls in (both forms)
   ```
   Inbound callers use **either** `crate::<mod>::X` **or** bare `<mod>::X` — the re-export
   in step 6 makes both keep resolving.
2. **Create the crate.** `mkdir -p crates/chump-<name>/src`; write `Cargo.toml` (copy the
   shape from an existing extracted crate, e.g. `crates/chump-verify/Cargo.toml`: name,
   version `0.1.0`, edition 2021, license `AGPL-3.0-only`). Add **only** the deps the moved
   code actually uses — read its `use` statements. For `crate::ambient_emit`, depend on
   `chump-ambient-cli` and import `chump_ambient_cli::ambient_emit`.
   **MANDATORY: add a `[lints]` table with `workspace = true`.** The root
   `[workspace.lints.clippy]` allow-lists ~15 lints (`manual_strip`,
   `manual_pattern_char_comparison`, `dead_code`, …) that the bin's code relies on. A new
   crate does **not** inherit them unless it opts in with `[lints] workspace = true`. Skip
   this and CI's `clippy -D warnings` will fail on moved code that was clean in the bin
   (this bit both EFFECTIVE-394 and -399 — the local `cargo build` gate passed but CI
   clippy failed).
3. **Move as SIBLING modules.** `git mv src/<mod>.rs crates/chump-<name>/src/<mod>.rs`, and
   in `crates/chump-<name>/src/lib.rs` declare `pub mod <mod>;`. Moving the cluster's files
   as siblings keeps their *intra-cluster* `crate::` paths valid — files in the same new
   crate still see each other via `crate::`. (git records these as 100%-similarity renames,
   so the diff stays tiny and reviewable even for thousands of lines.)
4. **Fix only OUTBOUND refs** inside the moved files: a `crate::foo` where `foo` is *not*
   moving into this crate → point it at the crate that owns it now (`chump_foo::…`). Leave
   intra-cluster `crate::` paths alone.
5. **Re-export from the bin.** In `src/main.rs`, replace `mod <mod>;` with
   `pub use chump_<name>::<mod>;`. This is the trick that makes **every existing caller
   compile unchanged** — `crate::<mod>::X` across the whole bin now resolves through the
   re-export. Zero edits to callers.
6. **Widen visibility as the compiler demands.** Items the bin calls must be `pub` (not
   `pub(crate)`) now that they live in another crate. Don't guess — build and let the
   compiler list them (`error[E0603]: ... is private`); bump each, iterate to clean.
7. **Wire the workspace.** Add `"crates/chump-<name>"` to root `Cargo.toml` `[workspace]`
   members, and `chump-<name> = { path = "crates/chump-<name>", version = "0.1.0" }` to the
   bin `[dependencies]`.
8. **GATE — all three must be green, because CI runs all three.** In order:
   `cargo fmt --all`, then **`cargo build --workspace`** (exit 0), then
   **`cargo clippy --workspace --all-targets`** (exit 0 — CI runs it with `-D warnings`, so
   this is where the `[lints] workspace = true` omission bites), then
   **`cargo test --workspace`** (or at least `-p chump-<name>` plus the bin's tests). A green
   `cargo build -p chump-<name>` **alone is not enough** on two counts: (a) the *bin* must
   build, to catch bare `<mod>::item` references to items you left private; (b) `build` is
   not `clippy` and is not `test` — CI is stricter than a build. Gate on what CI actually
   runs, not a cheaper subset.
9. **Measure the win.** From the warm worktree: `touch src/main.rs && cargo build --workspace`
   and confirm `chump-<name>` does **not** appear in the `Compiling …` lines — it stayed
   cached. That "stayed cached" is the whole point; capture it for the PR.

Ship mechanics (manual fallback, CI flake handling, reconciliation) live in the ship-plumbing
notes — the short version: bot-merge dies on the cold recompile under the CI tool cap, so push
+ open PR + `gh pr merge --auto --squash` by hand, commit `--no-verify` with a
`Preflight-Skip-Reason:` trailer, always `cargo fmt --all` first.

---

## THE LOAD-BEARING RULE: the compiler is the coupling authority

Grep tells you where to *start*. The **compiler** tells you the *truth*.

On EFFECTIVE-394, both `grep` (as run) and almanac's dependency graph missed a bare
`load_ac_bullets` call (no `crate::` prefix) that only surfaced as an `E0603` when the
workspace built. **almanac's `almanac_impact`/`almanac_neighbors` silently under-report
Rust coupling** — they resolve `use <path>;` import edges but not inline `crate::module::item`
path references, which is how most intra-crate Rust calls are written (it found 1 of 4
callers on 394). So:

- Use **grep `crate::<Symbol>` + who-references** to scope the work.
- Use **almanac semantic search** (`almanac_search`) to *find prior art* before building —
  that part is reliable.
- Never treat almanac's dependency graph as the coupling authority. A wrong blast radius is
  a broken extraction. **`cargo build --workspace` green is the only proof the cut is clean.**

(Same silent-incompleteness class tracked as CREDIBLE-223.)

---

## The campaign

Extract leaf-first, biggest-win-first, a few in parallel (each in its own worktree with its
own `CARGO_TARGET_DIR` so their builds don't collide). Parallel extractions only collide on
`Cargo.toml` / `Cargo.lock` / `main.rs` — all different-line edits, trivially rebased. As
each lands, the next fresh worktree and the next CI run build a little less of the monolith.
