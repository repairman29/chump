---
doc_tag: operator_manual
owner_gap: INFRA-8652
last_audited: 2026-10-27
---

# Fleet identity split — `GH_TOKEN_FLEET` (INFRA-8652)

## Why this exists

Fleet workers and the review organ both used to run as the same GitHub
login (the operator's personal `repairman29` account, inherited via `gh`'s
ambient auth / keyring). GitHub refuses to let an account approve its own
PR, so the review organ's "approve this fleet PR" step was structurally
impossible — it was reviewing itself.

This splits the two identities:

- **Fleet workers** (`bot-merge.sh` and anything that pushes branches /
  opens PRs on a gap's behalf) author commits and PRs as a dedicated
  **machine account**, driven by `GH_TOKEN_FLEET`.
- **The review organ and the operator** keep using their existing
  `repairman29` login (ambient `gh` auth, no change). Because the PR author
  is now a *different* account, their APPROVED review is accepted by
  GitHub instead of silently no-op'd as self-review.

## The variable

| Var | Who sets it | Effect |
|---|---|---|
| `GH_TOKEN_FLEET` | Operator, in the fleet worker's environment (launchd plist env, tmux pane env, or CI secret) | `scripts/coord/lib/fleet-identity.sh` (`fleet_identity_init`, called at the top of `bot-merge.sh`) exports it as `GH_TOKEN` for the rest of the process, so every `gh` call (and `git push` over HTTPS, which `gh` credential-helpers) authenticates as the machine account. It also looks up the account's login via `gh api user` and rewrites the **local repo's** `git config user.name` / `user.email` to that login, so commits on the branch carry the machine identity too. |

**Fallback (unset):** `fleet_identity_init` is a complete no-op — no env var
or git config is touched, so behavior is byte-for-byte identical to before
this gap. It emits `kind=fleet_identity_missing` to `ambient.jsonl` once per
boot (debounced via a sentinel file under `/tmp`, which every target OS
clears on reboot) so the gap is visible without spamming every ship cycle.

## Token scopes

`GH_TOKEN_FLEET` must be a PAT belonging to the machine account
(`chump-fleet-bot` — see `docs/process/CHUMP_FLEET_BOT_SETUP.md` for account
provisioning) scoped to **exactly**:

- **Contents: Read and write** — push branches, create commits
- **Pull requests: Read and write** — open PRs, read PR state for bot-merge polling
- **Metadata: Read** (mandatory baseline for any fine-grained PAT)

No other scope. In particular, no `Administration`, no org-wide access —
the token is repo-scoped to `repairman29/chump` (and `repairman29/froogle`
for the froogle receipt in AC2).

## Rotation

- **Cadence:** annually, or immediately on suspected compromise (same
  policy as the oauth-refresh token in INFRA-622/INFRA-2124).
- **Current token issued / next rotation due:** issued 2026-10-27, rotate by
  **2027-10-27**. Update this line when the token is rotated.
- **Rotation procedure:** regenerate the fine-grained PAT under the
  `chump-fleet-bot` account (Settings → Developer settings → Fine-grained
  tokens), update the value wherever `GH_TOKEN_FLEET` is sourced from
  (launchd plist `EnvironmentVariables`, `~/.chump/chump-fleet-bot.env`, or
  the CI secret store), and restart any daemon that cached the old value
  (`bot-merge.sh` re-reads it fresh on every invocation, so no daemon
  restart is needed for that script specifically).

## Verifying the split is live

```bash
# With GH_TOKEN_FLEET exported, confirm bot-merge.sh resolves the machine
# account login (not your personal login):
GH_TOKEN_FLEET="<pat>" bash -c '
  source scripts/coord/lib/fleet-identity.sh
  fleet_identity_init
  echo "login=$FLEET_IDENTITY_LOGIN active=$FLEET_IDENTITY_ACTIVE"
'

# Receipt (AC2): one APPROVED review visible on a real fleet PR in each repo.
gh pr view <fleet-pr-number> --repo repairman29/chump --json reviews \
  --jq '.reviews[] | select(.state=="APPROVED")'
gh pr view <fleet-pr-number> --repo repairman29/froogle --json reviews \
  --jq '.reviews[] | select(.state=="APPROVED")'
```

## Test coverage

`scripts/ci/test-fleet-identity.sh` covers the token split: `GH_TOKEN_FLEET`
set → `GH_TOKEN` + git identity flip to the machine account; unset → clean
no-op fallback with `fleet_identity_missing` emitted once per boot; and that
`bot-merge.sh` actually wires `fleet_identity_init` into its startup path.
