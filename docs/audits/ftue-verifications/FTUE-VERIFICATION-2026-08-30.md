---
doc_tag: audit
gap: CREDIBLE-354
machine_class: reference-node-CJ (STATIC audit — NOT a fresh-box run)
recorded_by: claude
recorded_at: 2026-08-30
head_sha: bc78ef88
---

# FTUE / factory-reproducibility verification — 2026-08-30

> **Scope note — which FTUE this is.** This file sits beside the older
> `FTUE-VERIFICATION-2026-0{4,5}-*.md` docs, but it measures a **different**
> first-run experience. Those measure the **end-user product FTUE**
> (`brew install chump → PWA in <60s`, PRODUCT-017, still run weekly by
> `.github/workflows/ftue-clean-machine.yml`). **This one measures the
> factory-node / ribbon FTUE**: *fresh owned box → one command → working
> ChumpOS node.* The two share a folder and a name; they do not share a
> subject. Keep them distinct.

> **Status — this is a GROUNDED STATIC audit, not a live fresh-box proof.**
> Every claim below is read from the actual repo at HEAD `bc78ef88`
> (`scripts/ops/organ-manifest.txt`, `scripts/setup/install-fleet-node.sh`,
> `scripts/setup/chump-node-install.sh`, and the dedicated `install-*.sh`),
> not from a running install and not from vibes. **A LIVE fresh-box proof is
> still owed** and cannot honestly be produced on CJ — see
> [§5 The box problem](#5-the-box-problem).

---

## 1. The ribbon being measured

The commercial ribbon's install promise is: **a fresh, owned box becomes a
working ChumpOS factory node from one command.** Two scripts carry that
promise, and they cover **different, non-overlapping** organ sets:

| Installer | Privilege | What it installs | Invoked how |
|---|---|---|---|
| `scripts/setup/chump-node-install.sh` | user | binary (CI-artifact/release/build, provenance-gated) · minimal organs (`node-heartbeat`, `worker`, `process-organ-heal`) · SEED (gap store) · SUBSTRATE (`postgrest` via `install-gap-substrate.sh`) · EYES (`almanac-liveness` via `install-almanac-organ.sh`) · node-housekeeping (`install-node-housekeeping.sh`) · user `node-refresh` timer | the "one command" — `curl … \| bash -s -- --role …` |
| `scripts/setup/install-fleet-node.sh` | **root** | the **ATC roster** — 18 `chump-*` timers + service siblings (pr-lander, farmer, integrator, gap-drain, merge-serializer, nba-dispatch, …) copied into `/etc/systemd/system` and `enable --now`'d, then `organ-reconcile --apply` | `sudo bash …` by hand, **or** `node-refresh --auto` after a merge |

**Finding F1 — "one command" does not install the factory.**
`chump-node-install.sh` **never calls** `install-fleet-node.sh`
(confirmed: `grep -n helsinki-atc scripts/setup/chump-node-install.sh` → no
match). The 16 ATC-roster organs that make the box an actual *shipping
factory* (lander, farmer, integrator, drain, merge-flow) come **only** from
the root-privileged ATC installer. The auto-path that would run it
(`node-refresh-chump.sh` → `install-fleet-node.sh --auto`) **skips the
system-unit deploy when not root** (`install-fleet-node.sh:221-231`, emits
`organ_units_deploy_failed reason=not_root`), and `node-refresh` is a *user*
unit. So on a fresh owned box the operator must **manually**
`sudo bash scripts/setup/install-fleet-node.sh` — a hand-step the "one
command" ribbon does not cover.

---

## 2. The reproducibility metric (CREDIBLE-354 `fresh_install_reproducible`)

```
reproducible_pct = (manifest-enabled organs in the installer roster)
                   / (manifest-enabled organs)
```

- **manifest(enabled)** = `enabled` lines in `scripts/ops/organ-manifest.txt`
  = **29** units @ HEAD `bc78ef88`.
- **installer-roster** = a unit is rostered if it (or its `.service`/`.timer`
  sibling) is in `install-fleet-node.sh`'s `SYSTEM_UNITS` array, **or** it is
  installed by a dedicated `scripts/setup/install-*.sh` the node bring-up
  invokes.

**Static reading @ `bc78ef88`: 20 / 29 = 69% reproducible.**

Prior art / natural home for the live instrument:
`scripts/ci/test-resilient-366-organ-roll-call.sh` already asserts **both**
roll-call directions — installer-roster ⊆ manifest (RESILIENT-366) and the
reverse manifest→installer (INFRA-3826, pinned to
`chump-gap-closure-reconcile.timer`). `reproducible_pct` is the **quantified
generalization** of that reverse roll-call; it should be computed + printed
in `scripts/dev/build-capabilities-registry.sh` alongside `live_pct` so a
Debt Index reading reports **ribbon-readiness beside node-liveness**.

---

## 3. What WOULD vs WOULD NOT reproduce on a clean box

### Reproduces under its manifest unit (20)

| Organ | Via |
|---|---|
| chump-pr-lander.timer | ATC roster |
| chump-pr-approval.timer | ATC roster |
| chump-farmer.timer | ATC roster |
| chump-rot-reaper.timer | ATC roster |
| chump-integrator.timer | ATC roster |
| chump-backlog-sync-writer.timer | ATC roster |
| chump-organ-watchdog.timer | ATC roster |
| chump-conflict-resolution-consumer.timer | ATC roster |
| chump-gap-closure-reconcile.timer | ATC roster |
| chump-armed-rebaser.timer | ATC roster |
| chump-merge-serializer.timer | ATC roster |
| chump-board-cycle.timer | ATC roster |
| chump-fleet-server.service | ATC roster |
| chump-race-control.timer | ATC roster |
| chump-gap-drain.timer | ATC roster |
| chump-nba-dispatch.timer | ATC roster |
| chump-discord-gateway.service | install-discord-gateway.sh |
| chump-almanac-liveness.timer | install-almanac-organ.sh (ensure_eyes) |
| chump-postgrest.service | install-gap-substrate.sh (ensure_substrate) |
| chump-cj-disk-monitor.service | install-node-housekeeping.sh |

> Caveat: 16 of these ride the **root** ATC installer (F1). "Reproducible"
> here means *an installer would place + enable the unit* — it does **not**
> mean the user-level one-command path does so without `sudo`.

### Does NOT reproduce under its manifest unit (9)

| Organ | Why | Class |
|---|---|---|
| chump-ci-flake-rerun.timer | no systemd installer (only `install-ci-flake-rerun-launchd.sh`, macOS) | no-installer |
| chump-outcome-verify-heal-consumer.timer | no installer / not rostered | no-installer |
| chump-faculty-collector.timer | no installer / not rostered | no-installer |
| chump-pr-book-settle.timer | no installer / not rostered | no-installer |
| chump-next-best-action.timer | no installer (its *consumer* nba-dispatch IS rostered; the producer is not) | no-installer |
| chump-cj-sync.service | no installer / not rostered | no-installer |
| chump-organ-deploy.timer | only referenced in `install-fleet-node.sh`'s `_KEEP_ROOT_ORGANS` map, **not** in the `SYSTEM_UNITS` copy/enable roster → never actually cp'd/enabled on a fresh Linux box | phantom-roster |
| chump-process-organ-heal.timer | `chump-node-install.sh` installs a `process-organ-heal` **capability** as a supervised while-true service, but under a **different unit shape** than the manifest's `.timer` | unit-shape mismatch |
| chump-cj-worker.service | `chump-node-install.sh` installs the **worker capability** (`muscle_organs` → `chump-worker`), but not under the manifest's `chump-cj-worker.service` name | unit-shape mismatch |

**These 9 are the honest reproducibility gaps.** Six are the exact
same-class organs `test-resilient-366-organ-roll-call.sh` itself names as a
filed follow-up ("ci-flake-rerun, process-organ-heal,
outcome-verify-heal-consumer, faculty-collector, pr-book-settle,
organ-deploy … not asserted broken here"). This audit confirms that
follow-up is still open and adds `cj-sync` and `next-best-action` to the list.

---

## 4. Parts / nodes / needs — what a fresh owned node actually requires

Grounded in `chump-node-install.sh` (phases DETECT → HOME → CREDS → BINARY →
SEED → ORGANS → SUBSTRATE → EYES → SUPERVISE → SELF-TEST) and
`crates/chump-fleet-server/src/mission.rs`.

### Provisioned by the installer (reproducible)

- **chump binary** — pulled HEAD-exact from the fleet's free CI artifact
  (`build-fleet-binaries.yml`), else opt-in release tarball, else built from
  the cloned repo; every path is **provenance-gated** (release-sha OR
  built-from-repo-HEAD) so a stray/stale `chump` can never pass as INSTALLED.
- **repo checkout, toolchain preflight** (git/jq/curl + rustup), **gap-store
  seed** from `docs/gaps/*.yaml`, **substrate** (Postgres+PostgREST), **eyes**
  (almanac), **node-housekeeping**, **reboot supervision**.

### Per-node / hand-set — NOT installer-provisioned (the FTUE friction)

| Secret | Read by | Provisioning status |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | claude backend (whole auth story) | **required**; operator supplies via `--creds-file` / `$CHUMP_BOOTSTRAP_CREDS`, or interactive `claude setup-token`. Never from a shared store. |
| `GH_TOKEN` | PR ops, authenticated clone, CI-artifact fetch | **required**; operator supplies (same channels) or `gh auth login` device flow. |
| `DISCORD_TOKEN` | walk-away pager (`scripts/discord.sh`) | optional; installer **warns** if absent — "pager dead without DISCORD_TOKEN". |
| `CHUMP_BATPHONE_TOKEN` | `chump-fleet-server` bat-phone intake (`mission.rs:34`, fail-closed) | **not required, not provisioned** by any `scripts/setup/*.sh` (`grep BATPHONE scripts/setup` → none). `fleet-server` installs, but the bat-phone stays disabled ("bat-phone disabled: CHUMP_BATPHONE_TOKEN not set") until hand-set. |
| `OPENROUTER_API_KEY` / `GROQ` / `GEMINI` / `OPENAI_API_BASE` | the DeepSeek/open-model floor (`chump-local` backend) | **not required, not provisioned** by `chump-node-install.sh` (it enforces only OAuth+GH). Hand-added to `providers.env` for the $0-inference floor. |

**Finding F2 — the FTUE friction is the secret set, not the organs.** A fresh
user cannot reach a working *shipping* node from the installer alone: they
must hand-supply at minimum `CLAUDE_CODE_OAUTH_TOKEN` + `GH_TOKEN`, and — for
the pager, the bat-phone, and the cheap-model floor — `DISCORD_TOKEN`,
`CHUMP_BATPHONE_TOKEN`, and the OpenRouter/Groq/Gemini keys. None of these are
installer-provisioned; all are per-node hand-set. This is the honest FTUE
wall.

---

## 5. The box problem

**A LIVE fresh-box proof cannot honestly be run on CJ.** CJ (`closetjunky`)
*is* the reference node — it already has `~/.chumpnode`, `~/.chump`, the ATC
roster in `/etc/systemd/system`, a live PostgREST, and a running almanac. A
`chump-node-install.sh` run on CJ would collide with the existing install and
would **self-verify against state it already has** — precisely the "instrument
that tests itself always passes" trap. The reference node cannot be its own
fresh-box control.

**Recommendation (Jeff's decision — not paged):** stand up a genuinely fresh
box for the live proof. Two options, both cheap:

- **Cloud VM** — a fresh Ubuntu 24.04 droplet/instance (≥4 GB RAM). Fastest to
  wipe-and-retry; matches the `linux-systemd` install path directly; ~pennies/hr.
- **Spare owned hardware** — a wiped mini-PC / spare box already on the
  tailnet. Zero marginal cost; exercises real owned-iron bring-up (the actual
  ribbon), including the root ATC step F1 flags.

The live run should: (1) supply only the two required creds; (2) run the one
command; (3) record what is and is not up **before** any hand-fix; (4)
confirm F1 (ATC roster absent until `sudo install-fleet-node.sh`) and F2
(bat-phone/floor dark until hand-set) on a truly cold box.

---

## 6. Verdict

| Dimension | Reading |
|---|---|
| Node-liveness (running on CJ) | measured elsewhere (Debt Index `live_pct`) |
| **fresh_install_reproducible** | **20/29 = 69%** (static, HEAD `bc78ef88`) |
| One-command → working *factory* | **NO** — ATC roster needs a separate root step (F1) |
| One-command → working *node* (binary+minimal organs+substrate+eyes) | **YES**, given the two required creds |
| Live fresh-box proof | **OWED** — needs a genuinely fresh box (§5) |

**Honest gaps to close (filed, not fixed here):**
1. 9 manifest-enabled organs not reproducible under their manifest unit (§3).
2. F1: the one-command path does not install the ATC roster (needs root).
3. F2: 5 per-node secrets are hand-set, none installer-provisioned.
4. `reproducible_pct` is not yet computed by any live instrument — wire it
   into `build-capabilities-registry.sh` (CREDIBLE-354).

---

*Generated as a grounded static audit for CREDIBLE-354. No fresh-box install
was performed; every count is traceable to the repo at HEAD `bc78ef88`.*
