# COTG — the "installed node" experience

**Goal (Jeff, 2026-08-17):** make "installed" a real, reproducible experience, not the
hand-assembly helsinki (and the current Pixel) grew into. One command turns an OWNED box
into a clean, self-supervising, self-testing ChumpOS node — host-agnostic (Termux / systemd
Linux / macOS). This is what RESILIENT-318 actually is.

## Why this exists
The 2026-08-17 helsinki teardown proved helsinki was ~half *installed* (reproducible from
`install-fleet-node.sh`) and ~half *built* — 11 load-bearing organs (worker@, keep-mergeable,
discord-gateway, electrician, …) were hand-placed with no installer, so a rebuild couldn't
reproduce them. The Pixel is the same disease one layer down: a RESILIENT-336 node accumulated
across `~/chump` (binary + junk), `~/chump-repo`, `~/chump-brain`, a boot supervisor, an
organs runner, and a now-dead-helsinki witness — none of it reproducible, half of it obsolete.
"Installed" must mean: **fresh box + one command + green self-test → a node that runs.**

## The one command
```
chump-node-install.sh --role brain|muscle|all [--home DIR] [--self-test-only]
```

## Phases (each idempotent, logged, verified)
1. **DETECT** — host kind (termux / linux-systemd / macos), arch, supervisor (runit `sv` /
   systemd / launchd), canonical paths. (Extends `node-describe.sh` to be Termux-aware.)
2. **HOME** — ONE canonical layout under `$NODE_DIR` (default `~/.chumpnode`): `repo/` (clean
   checkout), `bin/chump`, `organs/`, `logs/`. State stays at the established `~/.chump/`
   (providers.env, state.db, AUTONOMY_LEVEL, heartbeat). No junk-drawer, no multi-checkout.
3. **CREDS** — `~/.chump/providers.env` must exist with the required keys (OAuth, GH). Fail loud.
4. **BINARY** — a working `chump` binary at `$NODE_DIR/bin/chump` that passes a WARM smoke
   (answers a prompt). Termux builds on-device or via `deploy-pixel-node.sh` cross-compile.
4b. **SEED** (INFRA-3633) — one-shot `chump gap sync --pull` loading the canonical
   `$CHUMP_STATE_DB` (pinned at `$NODE_DIR`'s `$STATE_DIR/state.db`, never a repo-local
   `.chump/state.db`) from the git-tracked `docs/gaps/*.yaml` backlog, so a fresh box boots
   with the real gap queue instead of an empty store. Idempotent — respects the INFRA-3606
   terminal-status guard on re-run; no-op with a warning if no binary is installed yet or the
   store is unreachable.
5. **ORGANS** — install the role's organ set under the host supervisor, from a manifest.
   *brain*: heartbeat, node-describe-register, discord-gateway, coordination.
   *muscle*: worker, build/CI. Reproducible — the organ list is data, not hand-`cp`.
6. **SUPERVISE** — survive reboot: termux-boot hook (Termux) / systemd enable (Linux).
7. **SELF-TEST** — the canary that defines "installed": host detected, creds valid, binary
   answers, canonical store has a non-empty, docs/gaps-matching pickable gap count (INFRA-3633),
   every role organ's supervisor entry is UP, heartbeat is fresh. GREEN → INSTALLED ✓.

## Role → node (settled architecture)
- **Pixel = brain** (always-on, owned, in-pocket): coordination, registry, heartbeat,
  Discord (operator channel), witness. Credential home (providers.env, incl. Hetzner).
- **CJ = muscle**: worker, Rust builds, CI. Ships work; brain coordinates.
- CI compiles Rust, so the brain never needs to out-build anything.

## Non-negotiable: reproducible, not bespoke
Every organ is installed from the manifest by the installer. If an organ runs, an installer
created it — no hand-placed unit/service ever again. That is the one lesson from the helsinki
teardown, encoded.
