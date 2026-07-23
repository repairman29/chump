# Add a Fleet Node — bare Linux box → shipping, NATS-coordinated worker

> **Provenance:** this runbook captures the `closetjunky` bringup (2026-07-23) so it
> never has to be re-derived. Every step below was a real thing that had to happen;
> the gotcha callouts are real bugs we hit. Gaps: RESILIENT-191 (umbrella),
> RESILIENT-185/186/189/190.

A "fleet node" is a headless Linux box running `chumpd`, which supervises N worker
loops that claim gaps and ship PRs. Nodes coordinate through a shared **NATS** broker
so two machines never pick the same gap. This doc takes you from a bare box to a
shipping node in one pass.

**Two backends, same runbook:**
- `claude` — dispatches `claude -p` on your Claude subscription. Reliable shipper. Needs the Claude Code CLI + an OAuth token.
- `chump-local` — open models via OpenRouter (the EFFECTIVE-314 cost ladder). ~$0 to run; lower land-rate on thin-spec gaps. Needs OpenRouter keys.

**Legend:** 🧑 = operator-only step (identity/secret/click — cannot be scripted).
🤖 = scriptable (the provisioner or a helper does it).

---

## 0. Prerequisites (🧑 operator, ~5 min)

On the **new box** (fresh Ubuntu Server 22.04/24.04/26.04, ≥4 GB RAM, ≥30 GB disk):

1. 🧑 **Create a user** during install (or `adduser`). Note the username.
2. 🧑 **Authorize your workstation's SSH key** so you (and Claude) get in passwordless:
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<box-ip>
   ```
3. 🧑 **Passwordless sudo** (single-purpose fleet box — the provisioner needs root for apt):
   ```bash
   echo "<user> ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/<user>-nopasswd && sudo chmod 440 /etc/sudoers.d/<user>-nopasswd
   ```
4. 🧑 **Deploy key for git** (repo is private). On the box:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/chump_deploy -N "" -C "<hostname>-chump-deploy"
   printf 'Host github.com\n  IdentityFile ~/.ssh/chump_deploy\n  IdentitiesOnly yes\n' > ~/.ssh/config && chmod 600 ~/.ssh/config
   cat ~/.ssh/chump_deploy.pub
   ```
   Then add that pubkey at `github.com/<owner>/<repo>/settings/keys/new` with **✅ Allow write access** (workers push branches).

> **Gotcha — credentials never go in chat or argv (RESILIENT-173).** Passwords, tokens,
> and OAuth keys are entered by the operator directly on the box or streamed
> machine-to-machine (see §4). Claude will refuse to type your password into `sudo`
> or `ssh-copy-id` — that's the rule, not a limitation.

---

## 1. Provision the box (🤖, ~15–40 min)

```bash
git clone git@github.com:<owner>/<repo>.git ~/chump-host --depth=1
cd ~/chump-host
bash scripts/setup/provision-chumpd-host.sh --install-deps
```

This installs the toolchain (build-essential, **libssl-dev**, GTK libs, pkg-config,
sqlite3, gh, rustup), adds swap on low-RAM boxes, builds `chump` + `chumpd`, installs
`chump` on `~/.local/bin`, installs the **Claude Code CLI** (for the `claude` backend),
writes the `~/.chump/chumpd.env` template, and installs the `--user` systemd service
with linger (survives logout).

> **Gotcha — low RAM.** Boxes < 12 GB build with LTO off / 16 codegen-units / 3 jobs to
> avoid OOM. The provisioner detects this automatically and adds an 8 GB swapfile.
>
> **Gotcha — `CHUMP_REPO`.** The env template pins `CHUMP_REPO=<checkout>`. Without it
> chumpd defaults to `$HOME/Projects/Chump` and drives a **phantom path** (the
> root-of-roots bug from the EU migration). The provisioner sets it; don't remove it.

---

## 2. Materialize the backlog (🤖)

`state.db` is gitignored; the registry travels as `.chump/state.sql` (a YAML export).
Rebuild the local DB from it:

```bash
cd ~/chump-host && chump restore --from-sql
sqlite3 .chump/state.db "SELECT COUNT(*) FROM gaps WHERE status='open';"   # expect thousands
```

> **Gotcha — restore probes the LLM.** `chump restore --from-sql` currently tries to
> reach a model endpoint at startup and errors if none is reachable. Run it **after**
> §4 (secrets filled) so it uses your configured backend, or copy a known-good
> `state.db` from another node/laptop as a fallback:
> `scp <src>:~/chump-host/.chump/state.db ~/chump-host/.chump/state.db`.
> Tracked for a durable fix (restore should not need an LLM).

---

## 3. Join the private mesh — Tailscale (🧑 + 🤖, security-critical)

**Do not expose NATS on the public internet.** Put every node on your Tailscale tailnet;
the broker binds to the tailnet interface only.

```bash
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo tailscale up --hostname=<hostname>          # prints an auth URL
```

🧑 **Open the auth URL** in your browser (your Tailscale login authorizes the machine).
Then grab the stable tailnet IP — this also fixes dynamic home-IP churn for ChumpBar:

```bash
tailscale ip -4      # e.g. 100.108.53.105
```

---

## 4. Credentials (🧑, never in chat)

Fill `~/.chump/chumpd.env` (mode 0600). Stream secrets machine-to-machine to keep them
out of chat/argv — e.g. copy the two Claude/GitHub lines from an existing node:

```bash
ssh <hub> "grep -E '^(CLAUDE_CODE_OAUTH_TOKEN|GH_TOKEN)=' ~/.chump/providers.env" \
  | ssh <newbox> "cat >> ~/.chump/chumpd.env"
```

Required keys by backend:

| Key | claude | chump-local |
|---|---|---|
| `CHUMP_REPO` | ✅ (set by provisioner) | ✅ |
| `CHUMPD_FLEET_BACKEND` | `claude` | `chump-local` |
| `GH_TOKEN` | ✅ (PR ops) | ✅ |
| `CLAUDE_CODE_OAUTH_TOKEN` | ✅ (`claude setup-token`) | — |
| `CHUMP_AUTH_MODE` | `oauth` | — |
| `OPENAI_API_BASE` / `OPENROUTER_API_KEY` / `CHUMP_FREE_TIER_PROVIDERS` | — | ✅ |

> **Gotcha — `CLAUDE_CODE_OAUTH_TOKEN` is the whole auth story** for the claude backend
> (long-lived, from `claude setup-token`). There is **no** refreshing token file to
> manage. Set `CHUMP_AUTH_MODE=oauth` so a stale/absent API key can't outrank it.

---

## 5. Wire NATS coordination

**Hub (once, on the always-on box):**
```bash
bash scripts/setup/nats-broker-install.sh      # nats-server + JetStream + auth, bound to the tailnet IP
```

**Each node** (`~/.chump/chumpd.env`), pointed at the hub's **tailnet** IP:
```
CHUMP_NATS_URL=nats://chump:<secret>@<hub-tailnet-ip>:4222
CHUMP_NATS_TIMEOUT_MS=8000
```

> **Gotcha — connect timeout.** The default is 500 ms. A home-NAT link to a cloud hub is
> often DERP-relayed at 300–800 ms RTT, and the NATS handshake is multi-roundtrip — set
> `CHUMP_NATS_TIMEOUT_MS=8000` or claims silently fall back to local-only (collision risk).
>
> **Gotcha — async_nats ignores URL credentials.** Fixed in-code (RESILIENT-190): creds
> are parsed from the URL and passed via `ConnectOptions`. If you see `authorization
> violation`, your `chump` binary predates that fix — rebuild.
>
> **Verify coordination:** claim a throwaway gap from node A, then from node B — B must
> print `already claimed … on another machine (NATS-KV) — skipping`.

---

## 6. Start shipping (🧑 opt-in)

Autonomy is **fail-closed**: a node does nothing until you opt in.

```bash
echo 5 > ~/.chump/AUTONOMY_LEVEL          # ≥1 = run; 0/absent = stop (kill switch)
echo grind > ~/.chump/fleet-mode          # grind|travel = 2 workers; off = 0
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user restart chumpd
```

Confirm it's working:
```bash
systemctl --user is-active chumpd
tail -f /tmp/chumpd-fleet-*/agent-*.log    # workers pick gaps, spawn claude -p
git log origin/main --since='1 hour ago'   # ground truth: is it actually shipping?
```

> **Gotcha — PATH.** Workers need `chump` and `claude` on PATH. The provisioner installs
> `chump` to `~/.local/bin` and drops an `Environment=PATH=…` into the service. If you
> see `chump binary not on PATH` in agent logs, the drop-in is missing.

---

## 7. Add to ChumpBar (🧑, optional)

Show the node in your menu bar next to the others (EFFECTIVE-315):
```bash
export CHUMPBAR_HOSTS="hub=root@<hub-tailnet-ip>,<name>=<user>@<node-tailnet-ip>"
```
Use **tailnet** IPs so the menu bar works from anywhere, not just your home LAN.

---

## Operator checkpoint summary

Only these five need you personally; everything else is scripted:

1. 🧑 SSH key + passwordless sudo on the box
2. 🧑 Deploy key added to the repo (write access)
3. 🧑 Tailscale auth URL clicked
4. 🧑 Secrets into `~/.chump/chumpd.env`
5. 🧑 `AUTONOMY_LEVEL` set (the go switch)

## See also
- [`scripts/setup/provision-chumpd-host.sh`](../../scripts/setup/provision-chumpd-host.sh) — the toolchain + build + service installer
- [`scripts/setup/nats-broker-install.sh`](../../scripts/setup/nats-broker-install.sh) — hub broker setup
- [`docs/process/OFF_LAPTOP_SUBSTRATE.md`](./OFF_LAPTOP_SUBSTRATE.md) — the off-laptop cutover strategy
