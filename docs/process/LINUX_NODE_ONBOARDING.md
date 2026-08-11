# Linux node onboarding — fresh x86_64 box → shipping ChumpOS node

> **Provenance:** condensed from the 2026-08-09 Helsinki bring-up. A single-machine
> onboarding SOP for fresh x86_64 Linux (Ubuntu Server 22.04/24.04/26.04) that needs
> to become a **standalone shipping node** running Claude-dispatched work (not part of
> a NATS-coordinated fleet — see [`ADD_A_FLEET_NODE.md`](./ADD_A_FLEET_NODE.md) for that).
>
> **When to use this doc:**
> - You have a fresh Linux x86_64 box (cloud droplet, bare metal, VM).
> - You want to run `chump dispatch <GAP> --backend headless --prompt "..."` to work on gaps.
> - You do NOT need cross-machine NATS coordination (single node, or coordination happens at a layer above).
> - You are **not** setting up a fleet hub or joining an existing mesh.
>
> **When to use [`ADD_A_FLEET_NODE.md`](./ADD_A_FLEET_NODE.md) instead:**
> - You need NATS-coordinated multi-node fleet work (collision-safe gap claiming).
> - The node is part of a wider ecosystem (`chumpd` daemon + systemd service).

---

## 1. Prerequisites — before you touch the box

On your **workstation**, prepare credentials and SSH access:

| Item | How | Why |
|---|---|---|
| SSH key | `ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<box-ip>` | Passwordless login (required for Claude to work) |
| GH_TOKEN | Create a GitHub personal access token with `repo` scope at github.com/settings/tokens | Git clone + PR operations |
| CLAUDE_CODE_OAUTH_TOKEN | Run `claude setup-token` on your workstation, note the token | Claude API access for `claude -p` dispatch |

**Do NOT share, paste, or echo tokens in chat/logs.** Stream them directly to the box via SSH.

---

## 2. System prep — Node.js, git, and toolchain

SSH into the box as root or with passwordless sudo:

```bash
# Add Node.js 20 via NodeSource
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get update && sudo apt-get install -y \
  nodejs \
  build-essential \
  libssl-dev \
  pkg-config \
  sqlite3 \
  git

# Install Claude CLI globally
sudo npm install -g @anthropic-ai/claude-code

# Verify
claude --version
node --version
git --version
```

**Why these packages:**
- `nodejs` / `claude-code` — the dispatch backend.
- `build-essential`, `libssl-dev`, `pkg-config` — Rust build deps (chump binary).
- `sqlite3` — gap registry backend.

---

## 3. Git and GitHub setup

**On the box**, authenticate git:

```bash
# Option A: via GH_TOKEN (recommended for headless)
export GH_TOKEN="ghp_your_token_here"
gh auth login --with-token < <(echo "$GH_TOKEN")
gh auth status   # should show "Logged in to github.com"

# Option B: if using SSH key (slower, but works offline)
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

**Never paste tokens into interactive shells.** Stream them via `cat << EOF` or pipe.

Clone the repo:
```bash
cd /root/Projects
git clone git@github.com:anthropics/chump.git chump
cd chump
git fetch origin main
```

---

## 4. Model auth — Claude Code OAuth token

Create `~/.chump/providers.env` (mode 0600):

```bash
mkdir -p ~/.chump
cat > ~/.chump/providers.env << 'EOF'
# Source this file to load credentials for dispatch
export CLAUDE_CODE_OAUTH_TOKEN="paste_your_token_here"
export GH_TOKEN="ghp_your_token_here"
export CHUMP_AUTH_MODE="oauth"
EOF
chmod 600 ~/.chump/providers.env
```

**Source it before any dispatch work:**
```bash
source ~/.chump/providers.env
```

**Why `CHUMP_AUTH_MODE=oauth`:** prevents a stale/absent API key from outranking the valid OAuth token. See Linux substrate lessons lesson §3.

---

## 5. Build chump — release binary

```bash
cd ~/chump
PATH=$HOME/.cargo/bin:$PATH cargo build --release --bin chump

# Install to all three locations (PATH resolves .cargo/bin first — stale binaries there bite)
cp target/release/chump ~/.cargo/bin/chump
sudo cp target/release/chump /usr/local/bin/chump
sudo cp target/release/chump /root/bin/chump

# Verify
which chump          # should be ~/.cargo/bin/chump first
chump --version
```

**Why three locations:** PATH resolution order matters when multiple `chump` binaries exist. The `.cargo/bin` entry shadows `/usr/local/bin` and `/root/bin`, so stale binaries in `.cargo/bin` silently override newer ones elsewhere.

---

## 6. Set autonomy level and sandbox mode

```bash
echo 5 > ~/.chump/AUTONOMY_LEVEL         # ≥1 = authorized to claim/dispatch
chmod 0600 ~/.chump/AUTONOMY_LEVEL

# If running as root (common in cloud droplets):
export IS_SANDBOX=1                      # allows claude -p --dangerously-skip-permissions
```

**Autonomy level** is a kill-switch:
- `0` or absent → all dispatch/claim operations refuse.
- `≥ 1` → dispatch is authorized.
- `5` → full autonomy (for scripted/headless nodes).

---

## 7. Test dispatch — verify the setup works

```bash
source ~/.chump/providers.env

# Test 1: can we reach the Claude API?
claude -p --dry-run "echo hello" 2>&1 | head -20

# Test 2: can we access git and GitHub?
gh pr list --state open --limit 1

# Test 3: run a trivial chump command
chump gap list --status open | head -3
```

If all three pass, you're ready to dispatch.

---

## 8. Dispatch a gap (headless mode)

The **headless backend** does NOT require Claude Code IDE; it runs `claude -p` directly:

```bash
source ~/.chump/providers.env

# Dispatch a gap for the Claude backend to execute
chump dispatch INFRA-NNNN \
  --backend headless \
  --prompt "Fix the bug described in the gap acceptance criteria"

# Monitor the work
tail -f ~/.chump-locks/ambient.jsonl | jq '.' | grep -E 'kind|status'
```

**Backends:**
- `headless` — runs `claude -p --dangerously-skip-permissions` (requires `IS_SANDBOX=1` if root).
- `claude` — **NOT** valid here (alias for interactive Claude Code IDE, a no-op on headless).
- `chump-local` — open models via OpenRouter (separate auth, see `ADD_A_FLEET_NODE.md`).

**Output:**
- Work lands on a new git branch `chump/<gap-id>-claim`.
- Logs appear in `~/.chump-locks/ambient.jsonl` (kind: `gap_work_started`, `gap_work_completed`, etc.).
- On success, a PR is opened on `main`; `gh pr merge` merges it.

---

## 9. Daemon mode (optional) — long-lived loop

For an always-on node that auto-claims and ships work:

**If you have `chumpd` binary** (MISSION-051, shipped after this doc):
```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user start chumpd
systemctl --user status chumpd
tail -f /tmp/chumpd-fleet-*/agent-*.log
```

**If you only have the CLI** (this doc's minimum scope):
```bash
# Manual polling loop (replace with your cron / systemd timer)
while true; do
  source ~/.chump/providers.env
  AUTONOMY=$(cat ~/.chump/AUTONOMY_LEVEL 2>/dev/null || echo 0)
  [ "$AUTONOMY" -lt 1 ] && { sleep 60; continue; }
  
  gap=$(chump gap list --status open --priority P0,P1 --class xs,s | head -1 | cut -d' ' -f1)
  [ -z "$gap" ] && { sleep 300; continue; }
  
  chump dispatch "$gap" --backend headless --prompt "..." || true
  sleep 30
done
```

---

## Reference: env file template

Save this as `~/.chump/providers.env` (mode 0600):

```bash
# Linux node dispatch auth
export CLAUDE_CODE_OAUTH_TOKEN="<paste_token_from_claude_setup-token>"
export GH_TOKEN="<github_personal_access_token_with_repo_scope>"
export CHUMP_AUTH_MODE="oauth"

# For root users only (allows dangerously-skip-permissions)
# export IS_SANDBOX=1

# Optional: custom paths
# export CHUMP_REPO="/root/Projects/chump"
# export PATH="$HOME/.cargo/bin:/usr/local/bin:/root/bin:$PATH"
```

---

## Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| `claude: command not found` | npm install didn't work or PATH is wrong | `sudo npm list -g @anthropic-ai/claude-code`, check `/usr/lib/node_modules/` |
| `chump: command not found` | Build failed or install didn't land | `ls -la ~/.cargo/bin/chump /usr/local/bin/chump`, rebuild if missing |
| `401 Unauthorized` on dispatch | OAuth token expired or env var not loaded | `source ~/.chump/providers.env`, check `echo $CLAUDE_CODE_OAUTH_TOKEN` |
| `denied: repository does not exist` | GH_TOKEN missing or wrong scope | `gh auth status`, re-issue token with `repo` scope |
| `dispatch: autonomy check failed` | AUTONOMY_LEVEL = 0 or missing | `echo 5 > ~/.chump/AUTONOMY_LEVEL`, verify with `cat ~/.chump/AUTONOMY_LEVEL` |
| `IS_SANDBOX not set` (if root) | Running as root without sandbox flag | `export IS_SANDBOX=1` before dispatch |
| `NATS: connection timeout` (on fleet nodes) | Trying to coordinate with broker, but you're standalone | Not applicable to this doc; use `ADD_A_FLEET_NODE.md` for NATS setup |

---

## Bake in the PR-lander (so green PRs actually merge) — RESILIENT-288

The workers open PRs; something has to *land* them. `bot-merge --auto-merge` arms
auto-merge at ship time, but if a worker's turn ends before that step finishes, the
PR sits green-but-unarmed until the reaper closes it (the 2026-08-10 #3584 orphan:
CLEAN + all-green + 3.5h, never merged). The durable fix is a node timer that arms
any stranded green PR every ~10 min — **not an agent remembering to sweep.**

Install on the primary (always-on) node — root paths shown; adjust for a non-root node:

```bash
sudo cp scripts/dispatch/chump-pr-lander.service /etc/systemd/system/
sudo cp scripts/dispatch/chump-pr-lander.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now chump-pr-lander.timer
```

Verify it is baked in and actually working (don't assume — read the `armed=N` line):

```bash
systemctl list-timers chump-pr-lander.timer     # next run is scheduled
sudo systemctl start chump-pr-lander.service     # fire once now
journalctl -u chump-pr-lander.service -n 20      # look for "beat done — armed=N"
```

The beat is `scripts/dispatch/pr-lander-beat.sh` (idempotent, `--dry-run` supported);
it only arms PRs the node's `gh` user authored and never force-pushes or closes.
Global off-switch: `CHUMP_PR_LANDER_SKIP=1`. It emits `kind=pr_lander_beat` to
ambient every run so the sweep is observable, not assumed.

## Bake in the full ATC roster (armed-rebaser + node-refresh) — RESILIENT-300

pr-lander alone isn't enough: once a PR is armed and bot-merge exits, nothing
re-rebases it when main advances, so it drifts to BEHIND/DIRTY and stalls until
the reaper closes it (INFRA-3473's `armed-pr-rebaser.sh`) — and none of this
runs unless the *node's own `chump` binary* stays current with origin/main
(RESILIENT-200's `node-refresh-chump.sh`). Before this gap, both were
live-hacked directly into `/etc/systemd/system` / `~/.config/systemd/user` —
not tracked anywhere — so a node rebuild silently lost ATC.

One idempotent script installs the whole roster (pr-lander + armed-rebaser +
node-refresh) from tracked repo files:

```bash
sudo bash scripts/setup/install-helsinki-atc.sh          # install + enable all 3
sudo bash scripts/setup/install-helsinki-atc.sh --check   # exit 0 iff all 3 timers active
```

**Two gotchas that will otherwise waste an hour re-discovering them:**

1. **`CHUMP_REPO_ROOT` is case-sensitive and has no safe default.** The
   scripts' fallback (`$HOME/Projects/Chump`) is capital-C — that path does
   not exist on a case-sensitive Linux filesystem, only the lowercase
   `~/Projects/chump` clone does. Every ATC unit hardcodes
   `CHUMP_REPO_ROOT=/root/Projects/chump` (or passes `CHUMP_NODE_REPO`
   explicitly for node-refresh) for exactly this reason — don't let a future
   edit drop back to the default and silently break on the next rebuild.
2. **`/usr/local/bin/chump` is a symlink, not a copy, and it must point at
   node-refresh's install target.** `node-refresh-chump.sh` installs to
   `CHUMP_NODE_BIN` (default `~/.local/bin/chump`) and swaps it in atomically;
   it never touches `/usr/local/bin/chump` directly. On helsinki,
   `/usr/local/bin/chump -> /root/.local/bin/chump` so that PATH resolution
   (`/usr/local/bin` ahead of `~/.cargo/bin` for non-login shells, cron, and
   systemd units) picks up each refresh automatically. If you ever `cp` a
   binary to `/usr/local/bin/chump` on this node (as step 5 above suggests for
   a fresh box) you **replace the symlink with a stale copy** — node-refresh
   will keep updating `~/.local/bin/chump` underneath it while
   `/usr/local/bin/chump` silently drifts. Re-point it once ATC is installed:
   `ln -sf ~/.local/bin/chump /usr/local/bin/chump`.

## Next: join a NATS fleet (optional)

If you later need **cross-machine coordination** (multiple nodes sharing work):
1. Follow [`ADD_A_FLEET_NODE.md`](./ADD_A_FLEET_NODE.md) to join an existing mesh.
2. Set up Tailscale and point `CHUMP_NATS_URL` at the hub.
3. Migrate from CLI-based dispatch to the `chumpd` daemon.

---

## See also

- [`ADD_A_FLEET_NODE.md`](./ADD_A_FLEET_NODE.md) — multi-node NATS-coordinated fleet setup.
- [`OFF_LAPTOP_SUBSTRATE.md`](./OFF_LAPTOP_SUBSTRATE.md) — provisioning inventory and runbook context.
- [`docs/syntheses/linux-substrate-lessons-2026-07-28.md`](../syntheses/linux-substrate-lessons-2026-07-28.md) — real bugs and fixes from the Helsinki / closetjunky deployments.
