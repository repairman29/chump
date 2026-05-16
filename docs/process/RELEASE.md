# Chump Release Procedure

> **This document covers the operational steps for cutting a Chump release.**
> The CI pipeline handles artifacts automatically; this doc covers the secrets
> required, manual fallbacks, and what to do when things go wrong.

## Overview

A release is triggered by pushing a tag (e.g. `v0.1.3`). The
`.github/workflows/release.yml` pipeline then:

1. **Builds** cross-platform binaries (macOS arm64/x86_64, Linux x86_64)
2. **Creates** a GitHub Release with the binaries and a generated formula
3. **Publishes** the updated Homebrew formula to `repairman29/homebrew-chump`

## Required secrets

| Secret | Scope | Where to set |
|---|---|---|
| `HOMEBREW_TAP_TOKEN` | `public_repo` on `repairman29/homebrew-chump` | [Repo secrets](https://github.com/repairman29/chump/settings/secrets/actions) |

### Homebrew tap token (INFRA-1383)

**What it is:** A GitHub classic Personal Access Token (PAT) that authorises
the `publish-homebrew-formula` CI job to commit the updated formula to
`repairman29/homebrew-chump`.

**How to create:**
1. Go to [github.com/settings/tokens](https://github.com/settings/tokens)
2. Click **Generate new token (classic)**
3. Scopes: check **`public_repo`** only
4. Expiration: 1 year (set a calendar reminder to rotate)
5. Copy the token
6. Go to [repairman29/chump → Settings → Secrets → Actions](https://github.com/repairman29/chump/settings/secrets/actions)
7. Click **New repository secret**, name: `HOMEBREW_TAP_TOKEN`, paste token

**Why it matters:** Without this token, the `actions/checkout@v6` step that
checks out `repairman29/homebrew-chump` fails silently. The release binaries
still publish, but `brew upgrade chump` continues serving the old version.

**Rotation:** When the token expires, repeat the steps above. The preflight
step in `release.yml` will error immediately with a clear message before
wasting runner time on builds.

## Cutting a release

```bash
# 1. Ensure main is green and all target gaps are shipped
chump health --slo-check

# 2. Draft the release notes (pulls from CHANGELOG.md unreleased section)
cargo run --bin chump -- release-notes --preview

# 3. Tag and push (triggers .github/workflows/release.yml)
git tag v0.1.3 -m "chump v0.1.3"
git push origin v0.1.3

# 4. Watch CI: https://github.com/repairman29/chump/actions/workflows/release.yml
```

## Manual fallback: updating the Homebrew tap by hand

Use this when `HOMEBREW_TAP_TOKEN` is missing or the CI job fails.

**What v0.1.2 required (2026-05-15):**

```bash
# 1. Download the formula from the release assets
gh release download v0.1.2 --repo repairman29/chump --pattern "*.rb" --dir /tmp/formula

# 2. Clone the tap
git clone git@github.com:repairman29/homebrew-chump.git /tmp/homebrew-chump
cd /tmp/homebrew-chump

# 3. Copy the formula
cp /tmp/formula/chump.rb Formula/chump.rb

# 4. Commit and push
git add Formula/chump.rb
git commit -m "chump v0.1.2"
git push origin main
```

After pushing, `brew update && brew upgrade chump` should pick up the new version
within a few minutes.

## Troubleshooting

### `publish-homebrew-formula` fails with "Input required and not supplied: token"

→ `HOMEBREW_TAP_TOKEN` secret is missing. Add it (see above). The release
  binaries are already published; run the manual fallback to update the tap.

### `publish-homebrew-formula` fails with preflight check (INFRA-1383 guard)

→ Same root cause as above. The preflight now catches it before the artifact
  build phase, saving ~35min of runner time.

### Formula checksum mismatch after manual tap update

→ Re-download the release binary, compute `sha256sum`, update the `sha256`
  field in `Formula/chump.rb`, commit and push to the tap.

## Post-release checklist

- [ ] `brew install repairman29/chump/chump` installs the new version
- [ ] `chump --version` returns the new tag
- [ ] GitHub Release page shows all platform binaries
- [ ] Ambient: `chump health --slo-check` exits 0
- [ ] File a gap for any manual steps that should be automated
