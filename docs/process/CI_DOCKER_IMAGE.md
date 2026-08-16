# chump-ci Docker image (INFRA-2241, wired into ci.yml by INFRA-2287)

Prebuilt CI toolchain image hosted at
`ghcr.io/repairman29/chump-ci:latest`. `fast-checks` and `clippy` in
`.github/workflows/ci.yml` opt in via
`container: ghcr.io/repairman29/chump-ci:latest`, which skips the
`dtolnay/rust-toolchain` install step (and the apt/mold install steps) and
inherits a warm `/usr/local/cargo` dep layer cached by `cargo-chef`.
This is Lever 1's "last mile" from `docs/strategy/CI_REVIEW_2026-05-29.md`
— the container image existed since INFRA-2241 but nothing in ci.yml
referenced it until INFRA-2287.

Saves ~30 s/job * 2 wired jobs * 20+ PRs/day = ~20 min wall-clock daily
(cold toolchain-setup ~5 min → <30s per job).

## What's pinned (and why)

| Tool | Version source | Why |
|---|---|---|
| Rust | `rust:X.Y-bookworm` base image | Matches `rust-toolchain.toml`'s `channel`; keep both in sync manually — INFRA-2287 caught them drifted (image at 1.82, toolchain.toml at 1.96.0) and re-synced |
| `cargo-chef` | `cargo install --locked` (latest) | Recipe-based dep caching (10x rebuild speedup on cache hit) |
| `cargo-binstall` | `cargo install --locked` (latest) | Fast tool install path (avoids rebuild) |
| `sccache` | `cargo binstall -y` (latest) | Used as `RUSTC_WRAPPER`; per-call cache |
| `cargo-nextest` | `cargo binstall -y` (latest) | Replaces `cargo test`; parallel runner |
| `cargo-deny` | `cargo binstall -y` (latest) | License/CVE policy gate |
| `clippy` + `rustfmt` | `rustup component add` | Required for lint/format gates |
| `jq`, `git`, `curl`, `sqlite3` | `apt-get` (bookworm pin) | Runtime utilities for CI shell scripts |

All four cargo tools fall back to `cargo install --locked` if `binstall`
doesn't have a prebuilt for the target — this matters when a release lands
without binaries yet.

## How the build works

`docker/Dockerfile.ci` is a 4-stage multi-stage:

1. **chef** — Rust 1.82 + cargo-chef + cargo-binstall + sccache + nextest + deny.
2. **planner** — `cargo chef prepare --recipe-path recipe.json` (deps fingerprint).
3. **builder** — `cargo chef cook --release --recipe-path recipe.json` (cached
   layer of all third-party deps; this is the 10x speedup layer).
4. **final** — lean `rust:1.82-bookworm` with tools copied from chef + apt
   utilities. No source, no recipe — the workspace is mounted by CI at
   runtime as `/__w/chump/chump` via `actions/checkout`.

The final image is what gets pushed to GHCR. The `builder` stage exists so
the `cargo chef cook` deps cache is bound to the dependency fingerprint —
that layer is reused across builds whenever `Cargo.lock` is unchanged.

## How to bump the Rust version

1. Edit `docker/Dockerfile.ci` — change both `FROM rust:X.Y-bookworm` lines.
2. (Optional) edit `rust-toolchain.toml` to match (INFRA-2242).
3. Commit + push. The push-trigger in `.github/workflows/build-ci-image.yml`
   fires immediately and rebuilds `ghcr.io/repairman29/chump-ci:latest`.
4. The weekly Sunday cron picks up the next refresh ~6-7 days later (security
   patches in the base image, tool drift).

No CI change is required — `container: ghcr.io/...:latest` picks up the new
toolchain automatically on the next CI run.

## How to roll back

If a `:latest` image breaks CI, pin a known-good SHA tag in
`.github/workflows/ci.yml`:

```yaml
jobs:
  cargo-test:
    container: ghcr.io/repairman29/chump-ci:abc123def456  # known-good sha
```

Find the previous SHA at https://github.com/repairman29/chump/pkgs/container/chump-ci
(the package page lists every `:{sha}` tag with timestamps).

## Fall-through (cache-fail safety)

The CI integration (deferred to INFRA-2241B) must NOT hard-break on GHCR
pull failure. Pattern:

```yaml
jobs:
  cargo-test:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/repairman29/chump-ci:latest
    steps:
      - uses: actions/checkout@v6
      - run: cargo test
```

If the container image pull fails (auth, throttle, registry outage),
GitHub Actions reports the pull error and the job fails — but a clean
retry with no container falls back to the existing toolchain-install
path. Operators should treat repeated GHCR pull failures as a
`graphql_exhausted`-class signal and pin the previous `:{sha}` tag while
investigating.

## Build trigger reference

| Trigger | When | Output |
|---|---|---|
| `schedule: cron: "23 7 * * 0"` | Sundays 07:23 UTC | `:latest` + `:{sha}` |
| `push` to `docker/Dockerfile.ci` on `main` | Immediate on merge | `:latest` + `:{sha}` |
| `workflow_dispatch` | Manual operator trigger | `:latest` + `:{sha}` |

Concurrency group `build-ci-image` prevents two builds racing on the cache
layer write.

## GHCR token

The workflow uses `secrets.GHCR_PAT` if set, otherwise
`secrets.GITHUB_TOKEN`. `GITHUB_TOKEN` works for pushes to packages owned
by the same repo (default — `repairman29/chump-ci` package under the
repairman29/chump repo). A PAT is only needed if the package is moved
under an org with stricter permissions.

## Follow-up work

- **INFRA-2241B / INFRA-2287 (done)** — wired
  `container: ghcr.io/repairman29/chump-ci:latest` into `fast-checks` and
  `clippy` in `.github/workflows/ci.yml`, guarded by the same
  `vars.CHUMP_SELF_HOSTED_*` expression each job already used for
  `runs-on:` (self-hosted-macOS path is unaffected — `container:` resolves
  to `null` there). `cargo-test`'s actual work happens in `cargo-test-shard`
  on `ubuntu-24.04-arm` — the chump-ci image is amd64-only today, so that
  lane is **not** wired; a multi-arch build is a separate follow-up if the
  ARM shard's toolchain-setup tax becomes worth chasing. `audit` similarly
  stayed out of scope for this pass.
- **Rust version drift caught during INFRA-2287**: the image's base was
  still pinned to `rust:1.82-bookworm` while `rust-toolchain.toml` had moved
  to `1.96.0` — bumped both `FROM` lines to match. Also added `gh` and
  `python3` (several `scripts/ci/*.sh` shell out to one or both).
- **Cranelift**: the gap that produced this image (INFRA-2287) asked for a
  cranelift-preinstalled image, but no workspace profile currently sets
  `codegen-backend = "cranelift"`, and the cranelift codegen backend isn't
  distributed for the stable channel this image tracks — nothing to bake in
  yet. Revisit if/when a nightly-companion profile lands.
- **Measurement** — tag 5 PRs post-rollout, compare median wall-clock of
  `fast-checks`/`clippy` before/after. Target: -30 %+ on toolchain-setup
  steps specifically (cold ~5 min → <30s per AC #4 of INFRA-2287).
