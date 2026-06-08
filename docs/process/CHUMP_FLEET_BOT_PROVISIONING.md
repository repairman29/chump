---
doc_tag: canonical
owner_gap: META-211
last_audited: 2026-06-08
---

# Chump Fleet Bot Provisioning (META-211)

Provision and secure the `chump-fleet-bot` GitHub identity and Personal Access Token (PAT) for autonomous admin-merge operations.

## Overview

The `chump-fleet-bot` is a dedicated GitHub account with constrained permissions that enables Chump agents to autonomously admin-merge PRs (via `gh pr merge --admin`) without depending on operator session auth.

This document covers:
1. Manual GitHub account creation (operator action)
2. PAT generation with required scopes
3. Secure storage in macOS Keychain
4. Daemon access and usage

## Prerequisites

- GitHub account ownership (operator must have permission to create org members or app accounts)
- `gh` CLI installed and authenticated with appropriate permissions
- macOS Keychain available (for local storage)
- Access to `chump-fleet-bot-setup.sh` script

## Step 1: Manual GitHub Account Creation

> **Operator action** (no automation possible)

### Option A: Create as a regular GitHub user

1. Go to https://github.com/signup
2. Create account with name: `chump-fleet-bot`
3. Email: choose a project-owned email or team-accessible address
4. Complete email verification
5. Go to https://github.com/settings/profile and set:
   - Name: `Chump Fleet Bot`
   - Bio: `Autonomous PR admin-merge worker for Chump CI/CD`
   - Avatar: (optional) project logo

### Option B: Create as an org member (GitHub Enterprise only)

If using GitHub org, ask owner to invite `chump-fleet-bot` as a member with:
- Role: `Member` (not Owner)
- Org visibility: (Org default, typically private)

## Step 2: Generate Personal Access Token

### Using GitHub Web UI (recommended for first setup)

1. Log in to `chump-fleet-bot` account
2. Go to **Settings** → **Developer settings** → **Personal access tokens** → **Tokens (classic)**
3. Click **Generate new token (classic)**
4. Configure:
   - **Token name:** `Chump Auto-Admin-Merge PAT`
   - **Expiration:** `No expiration` (or choose 90-day rotation)
   - **Scopes:** Check **`admin:repo`** (grants full repo access including admin operations)
   - **Note:** "Used by Chump autonomous agents for admin-merge on repairman29/chump"
5. Click **Generate token**
6. **Copy the token immediately** — it will not be shown again
   - Token format: `ghp_<...>` (GitHub Personal Token)
   - **KEEP SECRET** — this is your only copy

### Minimal scope for repairman29/chump only

If your GitHub instance supports fine-grained tokens, use:
- **Repository access:** `repairman29/chump` (single repo)
- **Permissions:**
  - `Contents: write` (commit/push)
  - `Pull requests: write` (merge)
  - `Workflows: write` (admin-merge, workflow triggering)
  - `Administration: write` (branch protection rules if future feature)

(Classic PAT with `admin:repo` is equivalent for public/private repos and is more widely supported across GitHub versions.)

## Step 3: Secure Storage in Keychain

Use the provided setup script to securely store the PAT:

```bash
bash scripts/setup/chump-fleet-bot-setup.sh
```

### What the script does

1. Prompts for the PAT securely (input is hidden)
2. Validates the token format (`ghp_` prefix, GitHub token length)
3. Stores in macOS Keychain under:
   - **Service:** `chump-fleet-bot-pat`
   - **Account:** `ghp` (placeholder; service name is the key)
4. Verifies retrieval works
5. Prints confirmation and diagnostic commands

### Manual Keychain entry (if needed)

If you prefer to set it manually or the script fails:

```bash
security add-generic-password \
  -s "chump-fleet-bot-pat" \
  -a "ghp" \
  -w "ghp_YOUR_PAT_HERE" \
  -U
```

The `-U` flag updates if the entry already exists.

### Verify it worked

```bash
security find-generic-password -s "chump-fleet-bot-pat" -w
# Should print: ghp_<token>
```

## Step 4: Daemon Access

### Retrieving the PAT from Keychain

Daemons and scripts access the PAT via:

```bash
CHUMP_FLEET_BOT_PAT="$(security find-generic-password -s "chump-fleet-bot-pat" -w 2>/dev/null)" || {
  echo "ERROR: chump-fleet-bot-pat not found in Keychain" >&2
  exit 1
}
```

The fleet's launchd plists and coordination scripts use this pattern automatically.

### Using with gh CLI

```bash
export GH_TOKEN="${CHUMP_FLEET_BOT_PAT}"
gh pr merge <number> --admin --squash
```

Or directly in commands:

```bash
GH_TOKEN="${CHUMP_FLEET_BOT_PAT}" gh pr list --author "chump-fleet-bot"
```

### Using with API calls

```bash
curl -H "Authorization: token ${CHUMP_FLEET_BOT_PAT}" \
  https://api.github.com/user
```

## Troubleshooting

### Token not working

1. **Verify token in Keychain:**
   ```bash
   security find-generic-password -s "chump-fleet-bot-pat" -w
   ```
   Should return the token (starts with `ghp_`).

2. **Verify token on GitHub:**
   - Log into `chump-fleet-bot` account on GitHub.com
   - Go to **Settings** → **Developer settings** → **Personal access tokens** → **Tokens (classic)**
   - Confirm the token exists and **Expiration date is not passed**

3. **Test token with gh CLI:**
   ```bash
   export GH_TOKEN="ghp_YOUR_TOKEN"
   gh auth status
   ```
   Should show authenticated as `chump-fleet-bot`.

4. **Verify permissions:**
   ```bash
   export GH_TOKEN="ghp_YOUR_TOKEN"
   gh repo view repairman29/chump --json owner,nameWithOwner
   ```
   Should work (read), and admin operations should be allowed.

### Keychain is locked

If `security find-generic-password` prompts for Keychain password or fails:

```
security: SecKeychainSearchCopyNext: User interaction is not allowed.
```

Solution: Unlock Keychain
```bash
security unlock-keychain
# or (non-interactively):
security unlock-keychain -p "$(security find-generic-password -w -l "login")"
```

### Token rotation / expiration

If you set an expiration and it expires:

1. Log into `chump-fleet-bot` account
2. Go to **Settings** → **Developer settings** → **Personal access tokens**
3. Regenerate the token
4. Run `scripts/setup/chump-fleet-bot-setup.sh` again to update Keychain
5. Restart related launchd daemons:
   ```bash
   launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.chump.*.plist 2>/dev/null || true
   # Then restart manually or wait for next scheduled run
   ```

## Security considerations

- **Never commit the PAT** to git history or documentation
- **Never echo the token** in logs; scripts sanitize output (`ghp_...REDACTED`)
- **Keychain-only storage** — the token does not exist in env files or `.git/config`
- **Narrow scope** — use `admin:repo` (or fine-grained equivalent) for `repairman29/chump` only
- **Audit access** — monitor `ambient.jsonl` for `kind=agent_admin_merge` events to verify expected usage
- **Rotation** — every 90 days (or manually) generate a new token and update Keychain
- **Revocation** — if compromised, delete the token immediately from GitHub → **Settings** → **Developer settings** → **Personal access tokens** → **Delete**

## Decision history

- **2026-05-30** — Operator directive to provision a dedicated bot identity for autonomous admin-merge
- **2026-06-08** — Provisioning runbook and Keychain setup script filed as META-211

## Related

- [AUTO_ADMIN_MERGE_POLICY.md](./AUTO_ADMIN_MERGE_POLICY.md) — policy gate for agent admin-merge
- [META-209](../../gaps/META-209.yaml) — parent gap (agent admin-merge protocol)
- [GITHUB_CREDENTIALS_FOR_AGENTS.md](./GITHUB_CREDENTIALS_FOR_AGENTS.md) (reference in CLAUDE.md) — general agent auth patterns
