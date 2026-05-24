# scripts/setup — Installer discipline (INFRA-1810)

Every `install-*.sh` in this directory must be registered in one of three buckets
or CI (`test-install-script-manifest.sh`) will fail the PR that adds it.

## Three-bucket discipline

| Bucket | Where registered | Meaning |
|--------|-----------------|---------|
| **REQUIRED** | `REQUIRED_DAEMONS` in `chump-fleet-bootstrap.sh` | Fleet is incomplete without this daemon; `chump-fleet-bootstrap.sh` auto-installs it |
| **OPTIONAL** | `optional-installers-allowlist.txt` | Situational or opt-in; not installed by default |
| **DEPRECATED** | `deprecated-installers-allowlist.txt` | Scheduled for removal; CI warns, does not fail |

## Adding a new installer

1. Create `install-<name>.sh`
2. Add to **one** bucket before merging the PR
3. To promote OPTIONAL → REQUIRED: add to `REQUIRED_DAEMONS` and remove from allowlist

## Files

- `optional-installers-allowlist.txt` — operators audit this list to promote/remove
- `deprecated-installers-allowlist.txt` — one entry per installer being sunset
- `chump-fleet-bootstrap.sh` — contains `REQUIRED_DAEMONS` array
