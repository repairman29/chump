---
doc_tag: operator_manual
owner_gap: META-226
last_audited: 2026-06-08
---

# Chump Fleet Bot Setup Guide (META-226)

Provisioning a dedicated GitHub account (`chump-fleet-bot`) and scoped Personal Access Token (PAT) for agent-initiated operations. Separates agent identity from operator PAT inheritance.

## Overview

The auto-admin-merge protocol (META-209) and other agent-initiated GitHub operations require a dedicated bot identity separate from the operator's personal GitHub credentials. This guide walks through account creation, PAT generation, secure storage, and verification.

## Prerequisites

- GitHub organization access (ability to create bot accounts in repairman29 organization)
- macOS or Linux system with `gh` CLI installed and authenticated
- Access to 1Password or system Keychain for credential storage

## Step 1: Create GitHub Account

1. **Create a new GitHub account** with a name reserved for Chump agent operations.
   - Recommended names: `chump-fleet-bot`, `repairman29-bot`, `chump-admin-merge-bot`
   - Use a separate email address or alias to distinguish from personal accounts

2. **Optionally**: Invite the bot account to the `repairman29` organization with **no** organization-wide permissions yet.
   - The PAT scope (step 2) will limit access to specific repositories.

## Step 2: Generate Scoped PAT

1. **Log in to the bot account** on github.com

2. **Navigate to Personal Access Tokens (PAT) settings**:
   - Settings → Developer Settings → Personal Access Tokens → Tokens (classic)
   - Or use: `https://github.com/settings/tokens`

3. **Click "Generate new token (classic)"** and configure:
   - **Token name**: `chump-fleet-auto-admin-merge` (or similar descriptive name)
   - **Expiration**: 1 year (or adjust per your security policy)
   - **Scopes**: Check **only** `admin:repo_hook` (for repository webhook management if needed) and ensure the token is usable with `repairman29/chump`
     - If you need more restrictive fine-grained tokens (GitHub's newer PAT type), use `contents:write` + `pull_requests:write` scoped to the `repairman29/chump` repository only
   - **Leave all other scopes unchecked**

4. **Generate and copy the token** — GitHub displays it only once. Do **not** save it in plaintext yet.

## Step 3: Secure Storage

### Option A: macOS Keychain (Recommended for local dev)

```bash
# Store in Keychain
security add-generic-password \
  -a chump-fleet-bot \
  -s chump-fleet-bot-pat \
  -w "<paste-the-PAT-here>"

# Verify storage
security find-generic-password -a chump-fleet-bot -s chump-fleet-bot-pat -w
```

### Option B: 1Password

1. Open 1Password and create a new "Login" vault item
2. **Item name**: `chump-fleet-bot`
3. **Username**: `chump-fleet-bot`
4. **Password**: Paste the generated PAT
5. **Tags**: `github`, `chump-fleet`
6. **Vault**: Shared team vault (if available)

Then retrieve via:

```bash
op read op://Vault/chump-fleet-bot/password
```

## Step 4: Create Local Environment File

Create the file `~/.chump/chump-fleet-bot.env` with restricted permissions:

```bash
# Create the file
cat > ~/.chump/chump-fleet-bot.env << 'EOF'
# Chump fleet bot GitHub credentials (AUTO-ADMIN-MERGE)
# Do NOT commit. Do NOT push to any repo.
# Rotate annually or when compromise is suspected.

GITHUB_TOKEN="<paste-the-PAT-here>"
GH_TOKEN="<paste-the-PAT-here>"
EOF

# Set restrictive permissions (owner read/write only)
chmod 600 ~/.chump/chump-fleet-bot.env

# Verify permissions
ls -la ~/.chump/chump-fleet-bot.env
# Expected: -rw-------@ 1 user staff 256 Jun 8 12:34 ~/.chump/chump-fleet-bot.env
```

**DO NOT** commit this file to any repository. Add to `.gitignore` at the repository root if you work with multiple repos:

```bash
echo "~/.chump/chump-fleet-bot.env" >> ~/.gitignore
echo ".chump/*.env" >> ~/.gitignore
```

## Step 5: Verification

Verify the bot identity is working correctly:

```bash
# Source the env file and test gh CLI
source ~/.chump/chump-fleet-bot.env

# Confirm the bot account is authenticated
gh auth status
# Expected output: 
#   github.com
#     ✓ Logged in to github.com as chump-fleet-bot (REST API)
#     ✓ Git operations for github.com configured to use https protocol.
#     ✓ Token: gho_****...

# Test bot can access the target repository
gh repo view repairman29/chump
# Expected: Repository details displayed (no "Not Found" error)

# Test bot can create a draft PR (optional)
gh pr create --draft --title "Test PR from chump-fleet-bot" \
  --body "Verify bot can create PRs" \
  --repo repairman29/chump || echo "(Draft PR creation test)"
```

## Step 6: Integration with Scripts

Scripts that use the bot identity should source the env file before invoking `gh` commands:

```bash
#!/bin/bash

source ~/.chump/chump-fleet-bot.env || { echo "Bot credentials not found"; exit 1; }

# Use gh CLI with bot identity
gh pr merge <number> --admin --squash
```

The `auto-admin-merge-daemon.sh` (META-209) and other agent scripts will source this file automatically.

## Token Rotation

Rotate the PAT annually or immediately if:
- The token is accidentally exposed in logs or committed to a repository
- A suspected compromise occurs
- Security policy mandates more frequent rotation

**Rotation procedure**:

1. Generate a new PAT (Step 2)
2. Update local storage (Step 3)
3. Update `~/.chump/chump-fleet-bot.env` (Step 4)
4. Revoke the old token in GitHub settings
5. Test verification (Step 5)

## Troubleshooting

### "Failed to authenticate" or "Unauthorized"

- Verify the PAT scope includes `admin:repo` or equivalent write access to `repairman29/chump`
- Confirm the PAT has not expired
- Check that the correct PAT is in `~/.chump/chump-fleet-bot.env`

### "Rate limited"

- The bot account shares GitHub's rate limit with all other authentications
- Consider increasing the sleep duration in bot scripts during high-traffic periods

### "Repository not found"

- Verify the bot account has access to `repairman29/chump` (check organization permissions)
- Confirm the repository name is spelled correctly

## Decision history

- **2026-06-08** — META-226 filed to document chump-fleet-bot provisioning as a prerequisite for META-209 (auto-admin-merge protocol)
- **2026-05-30** — Operator directive to codify admin-merge protocol; dedicated bot identity required to separate agent operations from operator credentials
