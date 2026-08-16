# BuildBuddy RBE — Operator Runbook (INFRA-2249)

> Sibling of `docs/process/SCCACHE_R2_CACHE.md` (INFRA-2093). BuildBuddy is
> a drop-in sccache remote-cache backend, wired to be **preferred over R2**
> when configured — R2 stays wired as the warm fallback so removing/rotating
> the BuildBuddy key never breaks a build, it just falls back to the
> existing (slower) path.

## What this does

`docs/process/SCCACHE_R2_CACHE.md` wired sccache against a self-hosted
Cloudflare R2 bucket. This gap adds BuildBuddy's free tier as a second,
preferred backend — same sccache compile-cache mechanism, no code changes
to how cargo invokes the compiler, only which endpoint the cache hits land
on. It also validates BuildBuddy's bonus (beyond compile caching): remote
build **execution** (RBE) and Bazel-style test-result caching, both
evaluated as previews below rather than shipped as load-bearing CI paths —
see [RBE preview](#rbe-preview-chump-tool-macro) and
[test-result caching](#test-result-caching-status) for why.

## Operator setup (5 min)

1. **Sign up** at https://app.buildbuddy.io (free tier: ~5,000 builds/mo,
   see [Cost monitoring](#cost-monitoring--free-tier-limits)).
2. **Generate an API key** — BuildBuddy dashboard → Settings → API Keys.
3. **Store it as a GH Actions secret** named `BUILDBUDDY_API_KEY`:
   ```bash
   gh secret set BUILDBUDDY_API_KEY --repo <owner>/<repo>
   ```
4. Nothing else to configure — `ci.yml` / `audit.yml` already detect the
   secret and switch backends automatically (see
   [Backend selection](#backend-selection) below). R2 secrets stay in
   place; they're the fallback, not replaced.

Until step 3 is done, CI behaves exactly as it does today (R2-only, or
no-cache if `vars.CHUMP_CI_SCCACHE` isn't `true` — see
`SCCACHE_R2_CACHE.md` for that flag's history).

## Backend selection

Each CI job that uses sccache runs a "Detect remote-cache backend" step
before installing sccache. It checks, in order:

1. `BUILDBUDDY_API_KEY` secret present (length >= 16) → `backend=buildbuddy`
2. `R2_ACCESS_KEY_ID` secret present (length >= 16) → `backend=r2`
3. Neither → `backend=none`, sccache isn't installed, plain `cargo`/`rustc`
   runs uncached (slow but always correct — never blocks a build on cache
   infra being down).

This mirrors the graceful-degrade pattern from INFRA-2288: a short/garbage
secret or an unreachable endpoint never crashes the toolchain, it just
drops to the next tier.

## Local dev fallback

Local dev doesn't commit a `.cargo/config.toml` — it's `.gitignore`'d
(INFRA-202) precisely so a CI runner without sccache installed can never
break from a stale committed config. Instead, `scripts/setup/install-sccache.sh`
generates one per machine. As of this gap it points `build.rustc-wrapper`
at `scripts/ci/sccache-or-rustc.sh`, a passthrough shim: if `sccache` is on
`PATH` it delegates to it, otherwise it execs the wrapped compiler directly.
Local builds work identically whether or not sccache is installed.

By default the generated config uses a **local disk cache** (zero-setup,
zero-latency, no network dependency) — same as before this gap. To also
opt into the BuildBuddy remote cache locally (useful for cross-machine /
cross-worktree sharing), set `BUILDBUDDY_API_KEY` in your shell env before
running the installer:

```bash
BUILDBUDDY_API_KEY=<your-key> bash scripts/setup/install-sccache.sh
```

CI itself sets `RUSTC_WRAPPER=sccache` directly (the literal binary, not
the shim) once it's installed via `mozilla-actions/sccache-action`, which
takes precedence over the generated `.cargo/config.toml` default anyway —
no double-wrapping.

## RBE preview (chump-tool-macro)

The gap's stretch bonus was full BuildBuddy **remote execution** (RBE) —
compiling on BuildBuddy's runners, not just fetching/storing cached
artifacts locally. Evaluated for `chump-tool-macro` (smallest crate,
lowest blast radius):

**Finding: cargo has no native RBE execution client.** BuildBuddy RBE
speaks the Bazel Remote Execution API (REv2); the standard client is
`bazel` itself (or `reclient`/`buildbarn` shims built for that protocol).
`cargo` + `rustc` have no REv2 client — `sccache` only implements the
**cache** half of the protocol (`ActionCache`/`CAS` read+write), not the
**execution** half. Getting real remote *execution* for a cargo build
would mean either (a) migrating the build graph to Bazel + `rules_rust`,
or (b) waiting on/contributing a cargo-side REv2 execution client — both
are multi-week efforts disproportionate to this gap's `m` sizing.

**What shipped instead:** the compile-cache path above (which is the part
of "RBE" that's actually achievable as a drop-in swap) plus this documented
finding, so the fleet doesn't re-evaluate the same dead end. A genuine RBE
migration is out of scope here; if the cache-hit measurement below shows
strong ROI, file a follow-up gap scoped explicitly to a Bazel/rules_rust
spike before promising remote execution again.

## Test-result caching status

AC asked for nextest test-result caching keyed on source+deps hash
("skip re-running tests that haven't changed"). `cargo-nextest` has no
built-in remote test-result cache today (no `--target-dir-strategy` flag
exists in nextest as of this writing) and BuildBuddy's test-result caching
is likewise scoped to Bazel's test action graph, not `cargo nextest run`.
Shipping a fabricated flag here would silently no-op or break CI, so this
AC is **not implemented** — documenting the gap rather than faking it.
Follow-up: watch `cargo-nextest` upstream for a remote-cache experiment,
or investigate wrapping test binaries as individual Bazel-style actions
(non-trivial; likely its own gap once RBE migration is evaluated).

## Measurement (post-rollout)

Once `BUILDBUDDY_API_KEY` is set (operator step above) and PRs start
landing against it, compare median `cargo-test-shard` wall-clock:

```bash
# Baseline (R2-only or no-cache) — before rollout, or filter to PRs where
# the "Detect remote-cache backend" step output backend=r2/none.
gh run list --workflow=ci.yml --json databaseId,createdAt,conclusion \
  --jq '.[] | select(.conclusion=="success")' | head -20

# Per-run wall-clock for the cargo-test-shard job:
gh run view <run-id> --json jobs --jq '.jobs[] | select(.name | startswith("cargo-test-shard")) | .name, (.completedAt|fromdateiso8601) - (.startedAt|fromdateiso8601)'
```

Target from the AC: -40% median wall-clock on cache-hit vs the R2-only
baseline (RBE-bonus over pure compile caching — mostly explained by
BuildBuddy's larger free-tier cache + faster edge than the R2 bucket, not
by any execution offload per the RBE preview finding above). Tag 10
post-rollout PRs and file the comparison as a follow-up gap once real data
exists — this can't be measured in the PR that wires the plumbing.

## Cost monitoring — free tier limits

BuildBuddy's free tier (as of signup) is ~5,000 cache/build events per
month. Watch for:

- BuildBuddy dashboard → Usage — trend line, not just current-month total.
- If the fleet's PR volume pushes past the free tier, either downgrade to
  R2-only (`gh secret delete BUILDBUDDY_API_KEY` — CI falls back
  automatically, no code change) or evaluate a paid tier.
- `scripts/ci/check-sccache-hit-rate.sh` (CREDIBLE-085) already gates on
  hit-rate regardless of backend — a BuildBuddy outage or quota exhaustion
  shows up there the same way an R2 outage would.

## Fallback behavior summary

| Condition | Behavior |
|---|---|
| `BUILDBUDDY_API_KEY` valid | sccache uses BuildBuddy (`SCCACHE_BUILDBUDDY_URL`) |
| `BUILDBUDDY_API_KEY` absent/short, R2 secrets valid | sccache uses R2 (unchanged from INFRA-2093) |
| Neither configured | plain `cargo`/`rustc`, no remote cache |
| Local dev, `sccache` not installed | `.cargo/config.toml` shim passes through to `rustc` directly |

Test: `scripts/ci/test-buildbuddy-fallback.sh` — asserts the sccache config
surface exposes both the BuildBuddy URL and the R2 fallback URL.
