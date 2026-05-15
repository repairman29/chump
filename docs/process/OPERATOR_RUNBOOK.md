# Operator Runbook

Chump operational procedures that require manual one-time setup or emergency
intervention. Each section is self-contained.

## Table of Contents

1. [INFRA-1076: GitHub App lane installations (one-shot setup)](#infra-1076-github-app-lane-installations-one-shot-setup)

---

## INFRA-1076: GitHub App lane installations (one-shot setup)

> **Related:** [`docs/design/GITHUB_LIAISON.md`](../design/GITHUB_LIAISON.md) ·
> [`CLAUDE.md` call-criticality section](../../CLAUDE.md)

### Why

GitHub imposes per-user **secondary rate limits** on mutation operations
(PR creates, merges, label edits, update-branch calls). When a fleet sweep
saturates those limits on the operator user account, ship-blocking merges —
`gh pr merge --auto` and `gh pr update-branch` — are queued behind background
polls for hours.

**Live evidence (2026-05-14):** A label-edit sweep consumed the secondary
mutation budget. The operator account was gag'd for ~2 hours, during which 12
auto-armed PRs could not merge despite all required CI checks passing. No
backpressure signal was visible until operators saw `gh pr merge` silently
sitting at 429.

**Structural fix:** Create two GitHub App installations — `chump-critical` for
ship-blocking operations, `chump-background` for sweep/polling work. Each
installation has its own secondary rate-limit quota counter. Critical merges
never compete with background sweeps.

See also: INFRA-1076 (Rust implementation), INFRA-1360 (chump-gh-app crate),
INFRA-1361 (token rotator cron).

---

### Prerequisite

- GitHub **admin access** to the org and to `repairman29/chump` (or your fork).
- `chump` binary built (`cargo build --release --bin chump`).
- `~/.chump/` directory writable.

---

### Step 1 — Create the `chump-critical` GitHub App

1. Go to **github.com/settings/apps → New GitHub App** (or the org equivalent:
   `github.com/organizations/<org>/settings/apps`).
2. Fill in:
   - **GitHub App name:** `chump-critical`
   - **Homepage URL:** `https://github.com/repairman29/chump` (or your repo URL)
   - **Webhook:** disable (uncheck "Active")
3. Set **Repository permissions** (minimum required):
   - Contents: **Read & write**
   - Pull requests: **Read & write**
   - Commit statuses: **Read & write**
   - Checks: **Read & write**
   - Metadata: **Read** (forced by GitHub)
4. Click **Create GitHub App**.
5. On the app settings page, note the **App ID** (shown at the top).
6. Scroll to **Private keys → Generate a private key**. A `.pem` file downloads.
7. Move it to `~/.chump/keys/chump-critical.pem` and `chmod 600` it.

---

### Step 2 — Create the `chump-background` GitHub App

Repeat Step 1 with **GitHub App name:** `chump-background`.
Same scopes, same process. Save the App ID and `.pem` as
`~/.chump/keys/chump-background.pem`.

---

### Step 3 — Install both Apps on the repository

For each App (`chump-critical`, `chump-background`):

1. On the App settings page, click **Install App** in the left sidebar.
2. Choose **Only select repositories** → select `repairman29/chump`.
3. Click **Install**.
4. After install, the URL will contain the **Installation ID** (the number at
   the end of `github.com/settings/installations/<installation_id>`).
   Record it.

---

### Step 4 — Create `~/.chump/github_apps.toml`

```bash
mkdir -p ~/.chump
cat > ~/.chump/github_apps.toml << 'EOF'
[critical]
app_id          = <App ID for chump-critical>
private_key_path = "/Users/<you>/.chump/keys/chump-critical.pem"
installation_id = <Installation ID for chump-critical>

[background]
app_id          = <App ID for chump-background>
private_key_path = "/Users/<you>/.chump/keys/chump-background.pem"
installation_id = <Installation ID for chump-background>
EOF
chmod 600 ~/.chump/github_apps.toml
```

Replace `<you>` with your macOS username, and the IDs with the values from
Steps 1–3.

---

### Step 5 — Install the token-rotator cron

The rotator generates fresh installation tokens (GitHub App tokens expire after
1 hour) and writes them to `~/.chump/oauth-token-{critical,background}.json`.

**macOS (launchd — recommended):**
```bash
bash scripts/setup/install-gh-token-rotate-launchd.sh
```

**Linux (crontab):**
```
*/50 * * * * /path/to/repo/target/release/chump gh-token rotate
```

The `*/50` interval ensures rotation happens before the 60-minute expiry window.

---

### Step 6 — Verify: manual rotation

```bash
chump gh-token rotate
```

Expected output:
```
[gh-token-rotate] chump-critical  → ~/.chump/oauth-token-critical.json  (chmod 600)
[gh-token-rotate] chump-background → ~/.chump/oauth-token-background.json (chmod 600)
[gh-token-rotate] done
```

Check the files exist with correct permissions:
```bash
ls -la ~/.chump/oauth-token-{critical,background}.json
# Expected: -rw------- for both
```

---

### Step 7 — Verify lane routing in flight

Confirm the two App installations have **separate rate-limit quota counters**:

```bash
# Background lane — uses chump-background token
CHUMP_GH_CALL_CRITICALITY=background chump_gh api rate_limit \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('background remaining:', d['resources']['core']['remaining'])"

# Critical lane (no override) — uses chump-critical token
chump_gh api rate_limit \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('critical remaining:', d['resources']['core']['remaining'])"
```

If both calls succeed and return **different** `remaining` values, the lanes are
isolated and the App installations are working correctly.

> **Troubleshooting:** If both return the same value, the CHUMP_GH_CALL_CRITICALITY
> env var may not be wired to `chump_gh` yet (requires INFRA-1076 Rust code
> merged). Confirm the binary version with `chump --version`.

---

### Recovery — rotating or revoking credentials

If the private keys are compromised or an App installation is revoked:

1. Regenerate the `.pem` file on the GitHub App settings page.
2. Replace `~/.chump/keys/chump-{critical,background}.pem` with the new file.
3. `chmod 600 ~/.chump/keys/chump-{critical,background}.pem`
4. Re-run `chump gh-token rotate` to refresh the cached tokens.
5. Restart any fleet workers that cache the token in memory.

For a full re-installation (new App IDs / installation IDs), re-run Steps 1–6.

---

### Out of scope

GitHub's API does not permit programmatic App creation — the GitHub Settings UI
is required for Steps 1–3. There is no `chump` command that automates those
steps.
