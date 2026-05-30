# Self-Hosted Runner — DigitalOcean Droplet

**INFRA-2300 · CI-speed Tier 3 · operator-authorized 2026-05-30T17:00Z**

Adds a persistent +1 Linux runner slot to the chump-fleet CI capacity at
approximately **$24/mo** by provisioning a DigitalOcean s-4vcpu-8gb Ubuntu
24.04 droplet and registering it as a GitHub Actions self-hosted runner for
the `repairman29/chump` repository.

Related: `docs/process/SELF_HOSTED_RUNNERS.md` (macOS local runner setup),
`scripts/setup/install-self-hosted-runner.sh` (macOS launchd path).

---

## Cost

| Resource | Spec | Monthly cost |
|---|---|---|
| Droplet | s-4vcpu-8gb, nyc3 | ~$24/mo |
| Storage | 160 GB SSD (included) | — |
| Bandwidth | 5 TB outbound (included) | — |

The droplet runs 24/7. Destroy it when not needed with the uninstall script to
stop billing. DigitalOcean bills by the hour (~$0.036/hr), so a short-lived
experiment costs very little.

---

## Prerequisites

### 1. DigitalOcean API token

1. Go to <https://cloud.digitalocean.com/account/api/tokens>
2. Click **Generate New Token**
3. Name: `chump-runner-install` (or similar)
4. Scope: **Read + Write**
5. Copy the token — it will only be shown once

### 2. GitHub Personal Access Token

1. Go to <https://github.com/settings/tokens> (classic tokens)
2. Click **Generate new token (classic)**
3. Note: `chump runner registration`
4. Expiration: 90 days (or no expiration if you plan to re-use)
5. Scopes required: **`repo`** (full repo access includes runner registration)
   — OR — **`admin:org`** if registering at the org level in the future
6. Copy the token

> **Security note:** These tokens grant significant access. Store them in
> a password manager or macOS Keychain. Never commit them to the repo.

---

## Install

```bash
DO_API_TOKEN="your-do-token-here" \
GITHUB_PAT="your-github-pat-here" \
bash scripts/setup/install-do-droplet-runner.sh
```

The script runs for approximately 3–5 minutes (droplet boot + package install
+ runner registration).

### Optional overrides

```bash
DO_API_TOKEN="..."   \
GITHUB_PAT="..."     \
DROPLET_NAME="chump-runner-do-2"   \   # default: chump-runner-do-1
DROPLET_REGION="sfo3"              \   # default: nyc3
DROPLET_SIZE="s-8vcpu-16gb"        \   # default: s-4vcpu-8gb (~$24/mo)
DROPLET_IMAGE="ubuntu-24-04-x64"   \   # default: ubuntu-24-04-x64
RUNNER_VERSION="2.319.1"           \   # default: 2.319.1
RUNNER_LABELS="self-hosted,Linux,X64,chump-fleet,linux-burst" \
bash scripts/setup/install-do-droplet-runner.sh
```

---

## Expected output

```
[install-do-runner] Starting DigitalOcean droplet runner install
[install-do-runner]   Droplet name  : chump-runner-do-1
[install-do-runner]   Region        : nyc3
[install-do-runner]   Size          : s-4vcpu-8gb
[install-do-runner]   Image         : ubuntu-24-04-x64
[install-do-runner]   Runner version: 2.319.1
[install-do-runner]   Runner labels : self-hosted,Linux,X64,chump-fleet,linux-burst
[install-do-runner]   Repo          : https://github.com/repairman29/chump
[install-do-runner] doctl found — using doctl for droplet management
[install-do-runner] Creating droplet 'chump-runner-do-1'...
[install-do-runner] Droplet ready: ID=123456789  IP=159.65.12.34
[install-do-runner] Waiting for SSH on 159.65.12.34...
[install-do-runner] SSH reachable on 159.65.12.34
[install-do-runner] Running remote install on 159.65.12.34...
[remote] Updating package lists and installing base dependencies...
[remote] Installing Rust toolchain via rustup...
[remote] Installing sccache from Mozilla releases...
[remote] Creating runner user...
[remote] Downloading GitHub Actions runner v2.319.1...
[remote] Fetching GitHub runner registration token...
[remote] Configuring runner as 'chump-runner-do-1' with labels '...'
[remote] Installing runner as systemd service...
[remote] Service is active.
[remote] Install complete.
[install-do-runner] Remote install finished.
[install-do-runner] Polling GitHub API for runner 'chump-runner-do-1' with status=online (up to 120s)...
[install-do-runner] Runner 'chump-runner-do-1' is ONLINE.

╔══════════════════════════════════════════════════════════════╗
║          DO Droplet Runner — Install Complete                ║
╠══════════════════════════════════════════════════════════════╣
║  Droplet IP   : 159.65.12.34                                 ║
║  Droplet ID   : 123456789                                    ║
║  Runner name  : chump-runner-do-1                            ║
║  Labels       : self-hosted,Linux,X64,chump-fleet,linux-bu   ║
║  Est. cost    : ~$24/mo (s-4vcpu-8gb)                        ║
╠══════════════════════════════════════════════════════════════╣
║  Status       : ONLINE (confirmed via GitHub API)            ║
╚══════════════════════════════════════════════════════════════╝
```

---

## Verify

After install, confirm the runner is online and has the expected labels:

```bash
gh api /repos/repairman29/chump/actions/runners \
  | jq '.runners[] | select(.name=="chump-runner-do-1")'
```

Expected output:
```json
{
  "id": 12345,
  "name": "chump-runner-do-1",
  "os": "Linux",
  "status": "online",
  "labels": [
    { "name": "self-hosted" },
    { "name": "Linux" },
    { "name": "X64" },
    { "name": "chump-fleet" },
    { "name": "linux-burst" }
  ]
}
```

To confirm CI jobs pick it up, look for `Runs on: self-hosted, linux-burst`
in a workflow run that uses the `linux-burst` label.

---

## Uninstall

```bash
DO_API_TOKEN="your-do-token-here" \
GITHUB_PAT="your-github-pat-here" \
bash scripts/setup/uninstall-do-droplet-runner.sh
```

With a custom name:

```bash
DO_API_TOKEN="..." \
GITHUB_PAT="..." \
DROPLET_NAME="chump-runner-do-2" \
bash scripts/setup/uninstall-do-droplet-runner.sh
```

The uninstall script:
1. SSHes into the droplet and stops + uninstalls the systemd service
2. Calls `config.sh remove` to de-register the runner from GitHub
3. Falls back to the GitHub REST API to force-remove the runner registration
4. Destroys the DigitalOcean droplet (billing stops within the hour)

---

## Troubleshooting

### SSH timeout during install

**Symptom:** `SSH not reachable on X.X.X.X after 60s`

**Causes and fixes:**
- DigitalOcean can take 90–120s to provision a droplet and start sshd. The
  script waits 60s. If it fails, the droplet is likely still booting — wait
  2 minutes and SSH manually: `ssh root@<IP>`.
- Check if the droplet is visible in the DO dashboard and its status is
  "active". If stuck in "new" for > 5 min, destroy and recreate.
- The default droplet has no firewall; port 22 should be open. If your local
  network blocks outbound SSH, use `doctl compute ssh <name>` instead.

### Runner registration fails

**Symptom:** `failed to extract registration token from GitHub API response`

**Causes and fixes:**
- The `GITHUB_PAT` lacks sufficient scope. Ensure it has `repo` (classic) or
  `admin:org` if registering at org level.
- The PAT may be expired. Generate a new one at
  <https://github.com/settings/tokens>.
- If you see a 404, verify `CHUMP_REPO_OWNER` and `CHUMP_REPO_NAME` env vars
  or that the defaults (`repairman29` / `chump`) are correct.
- GitHub API rate limit: unlikely for a single install, but check
  `gh api rate_limit` if you are running multiple installs in parallel.

### Cargo build OOM on the droplet

**Symptom:** cargo build or CI step killed with exit code 137 (OOM)

**Causes and fixes:**
- The s-4vcpu-8gb droplet has 8 GB RAM. Heavy Rust workspaces with many
  crates building in parallel can exceed this.
- Add a swap file on the droplet:
  ```bash
  ssh root@<IP>
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ```
- Alternatively, add `CARGO_BUILD_JOBS=2` to the workflow env or upgrade to
  `s-8vcpu-16gb` (~$48/mo).

### doctl not installed

The script falls back to raw `curl` against the DigitalOcean v2 REST API
automatically. No action needed. To install doctl for a better experience:
```bash
brew install doctl          # macOS
snap install doctl          # Ubuntu/Debian
```

### Runner appears offline after install

**Symptom:** script completes but runner shows as "offline" in GitHub

**Fixes:**
- SSH into the droplet and check the service:
  ```bash
  ssh root@<IP>
  systemctl status "$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -1)"
  ```
- Check the runner logs:
  ```bash
  ls /home/runner/actions-runner/_diag/
  cat /home/runner/actions-runner/_diag/Runner_*.log | tail -50
  ```
- Restart the service:
  ```bash
  systemctl restart "$(ls /etc/systemd/system/actions.runner.*.service | head -1)"
  ```

### Ambient telemetry

Successful installs emit `kind=do_droplet_runner_installed` to
`.chump-locks/ambient.jsonl`. Failures emit `kind=do_droplet_runner_install_failed`
with `step` and `reason` fields. Use:
```bash
grep 'do_droplet_runner' .chump-locks/ambient.jsonl | tail -5
```

---

## Why ubuntu-24-04-x64 (not arm64)?

GitHub-hosted runners for `ubuntu-arm64` are a **paid-per-minute** tier with
no free concurrency. The self-hosted droplet approach uses cheap persistent
**x86_64** instead:

- `ubuntu-24-04-x64` is the same base image GitHub's hosted `ubuntu-24.04`
  runners use — maximizes CI script compatibility.
- ARM64 droplets (via DO's Ampere Altra VMs) are available but Rust's
  cross-compilation story is simpler when host arch matches the majority of
  developers' local machines (Intel/AMD).
- The `linux-burst` label allows workflow `runs-on` targeting without touching
  macOS-arm64 runners that serve the Apple-platform build lanes.

If an ARM64 burst lane becomes desirable in the future, change `DROPLET_IMAGE`
to `ubuntu-24-04-aarch64` (or the current DO slug) and `DROPLET_SIZE` to a
`c2-4vcpu-8gb` Ampere droplet; the install script requires no other changes.

---

## Architecture diagram

```
GitHub Actions
  |
  ├── ubuntu-24.04 (GitHub-hosted, free tier, shared concurrency)
  ├── macos-arm64  (self-hosted, M4 Mac, install-self-hosted-runner.sh)
  └── linux-burst  (self-hosted, DO droplet, THIS runbook)
        |
        └── repairman29/chump  ← registered via install-do-droplet-runner.sh
              |
              └── DigitalOcean s-4vcpu-8gb · nyc3 · Ubuntu 24.04
                    - actions/runner v2.319.1 (systemd service)
                    - Rust stable toolchain
                    - sccache (build cache acceleration)
```
