# COTG — the "installed node" experience

**Goal (Jeff, 2026-08-17):** make "installed" a real, reproducible experience, not the
hand-assembly helsinki (and the current Pixel) grew into. One command turns an OWNED box
into a clean, self-supervising, self-testing ChumpOS node — host-agnostic (Termux / systemd
Linux / macOS). This is what RESILIENT-318 actually is.

## Why this exists
The 2026-08-17 helsinki teardown proved helsinki was ~half *installed* (reproducible from
`install-helsinki-atc.sh`) and ~half *built* — 11 load-bearing organs (worker@, keep-mergeable,
discord-gateway, electrician, …) were hand-placed with no installer, so a rebuild couldn't
reproduce them. The Pixel is the same disease one layer down: a RESILIENT-336 node accumulated
across `~/chump` (binary + junk), `~/chump-repo`, `~/chump-brain`, a boot supervisor, an
organs runner, and a now-dead-helsinki witness — none of it reproducible, half of it obsolete.
"Installed" must mean: **fresh box + one command + green self-test → a node that runs.**

## The one command
```
chump-node-install.sh --role factory|data|embed [--home DIR] [--with-embeds] [--self-test-only]
```

**Roles (RESILIENT-320, role-aware — supersedes the earlier role-blind
`brain|muscle|all` split, which would have installed pr-lander + PR-reapers
onto a data node):**
- **factory** — workers (sized by `worker_count()`, no hand-placed units) +
  pr-lander + reapers (rot-reaper/worktree-reaper/cargo-sweep-gc) + integrator
  + orchestrator + disk-monitor + main-health-watchdog. (was: muscle/CJ)
- **data** — orchestrator + disk-monitor + main-health-watchdog + Postgres.
  **No pr-lander, no PR-reapers** — a data node never lands PRs. (was: brain/Pixel)
- **embed** — orchestrator + disk-monitor only. Lightest footprint.
- `--with-embeds` — a factory node that *also* runs local embedding inference
  gets one fewer worker (capacity formula below accounts for the shared load).

Old `--role brain|muscle|all` invocations still work — they map to
`data`/`factory`/`factory` respectively with a deprecation note on stderr.

## Phases (each idempotent, logged, verified)
1. **DETECT** — host kind (termux / linux-systemd / macos), arch, supervisor (runit `sv` /
   systemd / launchd), canonical paths. (Extends `node-describe.sh` to be Termux-aware.)
2. **HOME** — ONE canonical layout under `$NODE_DIR` (default `~/.chumpnode`): `repo/` (clean
   checkout), `bin/chump`, `organs/`, `logs/`. State stays at the established `~/.chump/`
   (providers.env, state.db, AUTONOMY_LEVEL, heartbeat). No junk-drawer, no multi-checkout.
3. **CREDS** — `~/.chump/providers.env` must exist with the required keys (OAuth, GH). Fail loud.
4. **BINARY** — a working `chump` binary at `$NODE_DIR/bin/chump` that passes a WARM smoke
   (answers a prompt). Termux builds on-device or via `deploy-pixel-node.sh` cross-compile.
5. **ORGANS** — install the role's organ set under the host supervisor, role-FILTERED from a
   manifest (`install-node-housekeeping.sh --role <role>`, RESILIENT-320). Reproducible — the
   organ list is data, not hand-`cp`, and a data/embed node can never end up with pr-lander.
6. **SUPERVISE** — survive reboot: termux-boot hook (Termux) / systemd enable (Linux).
7. **SELF-TEST** — the canary that defines "installed": host detected, creds valid, binary
   answers, every role organ's supervisor entry is UP, heartbeat is fresh, (factory) worker
   count matches target, (data) Postgres reachable. GREEN → INSTALLED ✓.

## Role → node (settled architecture, RESILIENT-320 / docs/strategy/DATA_HOME_PLAN.md)
- **CJ = factory**: workers (sized by cores-1, minus embeds if colocated), Rust builds, CI,
  pr-lander, reapers, integrator. Ships work.
- **Pixel = data**: Postgres (fleet registry/telemetry home), orchestrator, disk-monitor,
  main-health-watchdog. Never lands PRs — no pr-lander, no PR-reapers.
- CI compiles Rust, so the data node never needs to out-build anything.

## Non-negotiable: reproducible, not bespoke
Every organ is installed from the manifest by the installer. If an organ runs, an installer
created it — no hand-placed unit/service ever again. That is the one lesson from the helsinki
teardown, encoded.
