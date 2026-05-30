# sccache + Cloudflare R2 — Operator Runbook (INFRA-2093)

> Wave 1 #3 of 3 (CI scaling — see `docs/strategy/CI_SCALING_REFERENCE.md`).
> Maintained by the ZERO-WASTE pillar; CI gate: `scripts/ci/test-sccache-wired.sh`.

## What this does

Every CI cargo build today compiles all upstream crates from source (the
cache is per-runner local — when a job lands on a different runner, full
recompile). With sccache + R2 as a shared remote cache, the first runner
to build any given crate version writes the compiled artifact to R2;
every subsequent build (any runner, any PR) downloads the cached
artifact instead of recompiling.

**Target impact:** 50-70% wall-clock reduction on cargo build for cache
hits. Compounds with INFRA-2094 (cargo-nextest, 60% test speedup) and
INFRA-2095 (merge queue, batch CI cycles).

## Status

| Component | Status |
|---|---|
| Workflow env block wired (sccache vars + R2 endpoint) | ✅ this PR |
| sccache install step in cargo-test job | ✅ this PR (only fires when `RUSTC_WRAPPER=sccache`) |
| `sccache --show-stats` step for observability | ✅ this PR |
| Smoke test (`test-sccache-wired.sh`) | ✅ this PR |
| **Cloudflare R2 bucket created (`chump-sccache`)** | ✅ Operator (DONE) |
| **R2 API token generated** | ❌ Operator action below |
| **GH Actions secrets added (4 secrets)** | ❌ Operator action below |

The PR ships the **plumbing** with safe defaults: when R2 secrets are
absent, `RUSTC_WRAPPER` stays empty and sccache isn't invoked. CI
behaviour is unchanged. Setting the secrets flips on R2 sharing without
further code changes.

## Rotation (when sccache CI starts failing with `S3Error: Unauthorized`)

**Symptom.** CI runs on Rust PRs fail with:
```
sccache: error: Server startup failed: ... S3Error { code: "Unauthorized" }
error: command `cargo metadata ...` failed with exit status: 101
```

This means the R2 access-key + secret-access-key pair in GH secrets no longer
authenticates against the R2 bucket. The most common cause is a **half-rotation**:
one secret value was updated in GH but the matching half was not, breaking
the pair (see 2026-05-29 incident — INFRA-2127 / INFRA-2237).

### Primary path — atomic GH-secret update (INFRA-2240)

This is the daily-driver rotation flow. No Cloudflare API scope required —
operator regenerates the R2 token via the CF dashboard (a one-click flow
they're already doing), then a 20-line script atomically updates both
GH secrets so the pair can never end up half-rotated.

1. **CF dashboard** → R2 → Manage R2 API Tokens → roll the
   `chump-sccache-ci` token. New `Access Key ID` (32-char hex) and
   `Secret Access Key` (64-char hex) appear on-screen, **once only**.
2. **Paste both** into `~/.chump/r2-new-token.txt`:
   ```
   ACCESS_KEY_ID=<32-char-hex>
   SECRET_ACCESS_KEY=<64-char-hex>
   ```
   `chmod 600 ~/.chump/r2-new-token.txt` (gitignored under `~/.chump/`).
3. **Run:**
   ```bash
   # Dry-run shows lengths + fingerprints + intended writes:
   bash scripts/ops/rotate-sccache-r2-gh-only.sh

   # Actually rotate (single shell, both secrets, audit emit, file shredded):
   bash scripts/ops/rotate-sccache-r2-gh-only.sh --execute
   ```

The script validates lengths (refuses any deviation from 32/64), writes
`R2_ACCESS_KEY_ID` then `R2_SECRET_ACCESS_KEY` back-to-back, verifies both
secret timestamps land within 1-2 seconds of each other (pair-mismatch class
avoided), securely deletes the input file (`shred -uz` preferred,
`rm -P` fallback), and emits `kind=sccache_r2_gh_rotated` with first-4/last-4
audit fingerprints (never full secret values).

After rotation, the next CI run on any Rust PR uses the new pair. Trigger
with a push (any PR) or `gh workflow run ci.yml --ref main`. Watch for
`sccache` log to switch from `S3Error Unauthorized` to cache hit/miss stats.

### Advanced backup — full CF-API automation (INFRA-2237)

For operators who want zero manual dashboard interaction (CI/CD-style
rotation), `scripts/ops/rotate-sccache-r2-token.sh` automates the CF token
regen via API too. **Requires a Cloudflare API token with
`User API Tokens: Edit` scope** — a privileged scope an operator may not
want to keep around for everyday rotations.

```bash
export CHUMP_CF_API_TOKEN='cf-api-token-with-user-api-tokens-edit-scope'
export CHUMP_R2_ACCOUNT_ID='32-char-cf-account-hex'
bash scripts/ops/rotate-sccache-r2-token.sh           # dry-run
bash scripts/ops/rotate-sccache-r2-token.sh --execute # full rotation
```

This path creates a NEW R2 token via CF API, updates both GH secrets,
deletes the old CF token, emits `kind=sccache_r2_token_rotated`. Trap
EXIT/INT/TERM cleans up orphan new tokens on partial failure.

Both paths emit `kind=sccache_r2_gh_rotation_partial` (GH-only) or
`kind=sccache_r2_token_rotation_partial` (CF-API) if the second GH-secret
write fails after the first succeeds, with an explicit operator-recovery
message naming the half-rotated state.

## Operator: remaining R2 steps (~10 min — first-time setup only)

### Step 1 — Generate R2 API token (3 min)

1. Open the Cloudflare R2 dashboard: https://dash.cloudflare.com/?to=/:account/r2
2. Top-right → **Manage R2 API Tokens** → **Create API token**.
3. Settings:
   - **Token name:** `chump-sccache-ci` (any label you'll recognize)
   - **Permissions:** `Object Read & Write`
   - **Specify bucket:** `chump-sccache` (the one you already created)
   - **TTL:** leave blank (no expiry) — easier; rotate manually later if you want
4. Click **Create API Token**.
5. The next screen shows once-only credentials. **Copy and save:**
   - **Access Key ID** (32-char hex, looks like `a1b2c3...`)
   - **Secret Access Key** (~40-char hex)

### Step 2 — Capture your Cloudflare Account ID (30s)

1. On the R2 dashboard, look at the URL or the right sidebar:
   `https://dash.cloudflare.com/<32-char-hex>/r2/...`
2. That 32-char hex is your **Account ID**. Copy it.

### Step 3 — Add the 3 GH Actions secrets (2 min)

1. Open: https://github.com/repairman29/chump/settings/secrets/actions
2. Click **New repository secret** three times to add:

   | Secret name | Value |
   |---|---|
   | `R2_ACCOUNT_ID` | the 32-char Cloudflare Account ID from Step 2 |
   | `R2_ACCESS_KEY_ID` | Access Key ID from Step 1 |
   | `R2_SECRET_ACCESS_KEY` | Secret Access Key from Step 1 |

3. (Optional) If your bucket name isn't `chump-sccache`, also set the
   repo **variable** `SCCACHE_BUCKET` to your actual bucket name.
   Settings → Secrets and variables → Actions → Variables tab.

### Step 4 — Verify (1 PR cycle)

The next PR that touches Rust will trigger CI with sccache enabled.
Check the cargo-test job logs:

- **First run after enable:** all MISS (expected; cache is empty)
- **Second run:** HIT rate climbs as crates land in R2
- **Steady state (after 5-10 PRs):** ~50-70% hit rate; cargo build
  wall-clock visibly drops

The `sccache --show-stats` step at end of cargo-test prints the
numbers. Look for lines like:

```
Cache hits                  342
Cache misses                 47
Cache writes                 47
Average cache read           0.043 s
```

## Local-dev sccache (already set up via INFRA-202)

If you already ran `scripts/setup/install-sccache.sh` on your local
machine, that's a separate local-only sccache (no R2). It will keep
working as-is — local sccache populates `~/.cache/sccache` and never
touches R2.

You can opt your local dev into R2 sharing by adding the same env vars
to your shell profile:

```bash
export SCCACHE_BUCKET=chump-sccache
export SCCACHE_REGION=auto
export SCCACHE_ENDPOINT=https://<your-r2-account-id>.r2.cloudflarestorage.com
export AWS_ACCESS_KEY_ID=<r2-access-key-id>
export AWS_SECRET_ACCESS_KEY=<r2-secret-access-key>
export RUSTC_WRAPPER=sccache
```

But this is optional — local sccache local cache is already fast enough
for dev.

## Bypass / emergency disable

If sccache misbehaves in CI:

**Option A (most surgical):** rotate one of the R2 secret values to an
invalid string. sccache will fail to reach R2 and the workflow's
RUSTC_WRAPPER guard (`secrets.R2_ACCESS_KEY_ID && 'sccache' || ''`)
keeps it set, so this isn't ideal — better is:

**Option B (recommended):** delete the `R2_ACCESS_KEY_ID` secret. The
env block's conditional flips `RUSTC_WRAPPER` to empty string and
sccache is bypassed entirely. CI reverts to today's behaviour.

**Option C (per-run bypass):** set repo variable `RUSTC_WRAPPER` to
empty (overrides the secret-derived value for one or all runs).

## Observability

The smoke test `scripts/ci/test-sccache-wired.sh` checks wiring:

```bash
# Default (advisory) — exit 0 with WARN if R2 secrets not set
bash scripts/ci/test-sccache-wired.sh

# CI gate — fail if R2 secrets are set but RUSTC_WRAPPER misconfigured
bash scripts/ci/test-sccache-wired.sh --require-rustc-wrapper

# Diagnostic — also asserts R2 endpoint is reachable from this runner
bash scripts/ci/test-sccache-wired.sh --require-reachable
```

## Cost

Cloudflare R2 pricing for chump-scale (rough estimates):

- Storage: ~$0.015/GB/mo. Compiled artifact cache might grow to ~5-10 GB → ~$0.10/mo.
- Class A operations (writes): $4.50/M. ~50 writes per CI run × ~100 runs/day = ~5k writes/day = 150k/mo → ~$0.70/mo.
- Class B operations (reads): $0.36/M. ~500 reads per CI run × ~100 runs/day = ~50k reads/day = 1.5M/mo → ~$0.55/mo.
- Egress: **free** (R2's killer feature vs. S3).

**Total estimated:** ~$1.50-2/mo. Well under the $5/mo budget called out
in `docs/strategy/CI_SCALING_REFERENCE.md` for Wave 1.

## Wave 1 cohort

- INFRA-2094 (PR #2686): cargo-nextest swap — 60% test speedup
- INFRA-2095 (PR #2687): merge queue readiness — eliminates convoy
- **INFRA-2093 (this PR)**: sccache + R2 — 50-70% compile speedup

Combined: ~3-4× CI throughput on existing hardware for $0-5/mo spend.
