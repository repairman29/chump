# Pixel Node — the Android fleet node (RESILIENT-336)

The Pixel 8 Pro runs as a **third fleet node** — an express-lane worker + witness
probe. This doc captures the reproducible install and the resilience model so the
node can be rebuilt (or a second device onboarded) without re-deriving the setup.

> Companion to [`ANDROID_COMPANION.md`](ANDROID_COMPANION.md) (Mabel the Sentinel).
> That doc is the companion-agent role; this one is the **fleet-node** role.

## What runs on the node

| Process | Script | Role |
|---|---|---|
| `pixel-node-supervisor.sh` | `scripts/setup/pixel-node-supervisor.sh` | restarts the two below on death; takes the wake-lock |
| `pixel-worker.sh` | `scripts/setup/pixel-worker.sh` | express-lane gap worker (`chump --execute-gap`, cascade LLM) |
| witness probe | `scripts/setup/witness/probe.py` + `run.sh` | 5-min helsinki/NATS + trunk-age watch; DM-alerts on darkness |
| `sshd` | (boot hook) | SSH :8022 for Mac-side management |

The worker is **express-lane only**: `WORKER_SKILLS=docs,shell,scripts,md` (no
`rust`), effort `xs`/`s`, P1/P2. A failed gap gets a **cooldown** (default 1h) so
the loop advances instead of re-hammering one hard gap — the weak-model failure
saga is documented in [`docs/syntheses/free-tier-dispatch-testing-2026-05-08.md`](../syntheses/free-tier-dispatch-testing-2026-05-08.md)
(0/6 free-tier providers produced a commit).

## LLM model choice (the saga lesson)

Free-tier models fail gap work — even the simplest gap. The node therefore routes
the worker through **`opencode-go/deepseek-v4-pro`** (priority 1 in the cascade),
not the slim free-tier profile:

- cascade slots 12–14 = `deepseek-v4-pro` / `kimi-k2.7-code` / `qwen3.8-max` at
  `https://opencode.ai/zen/go/v1` (key `OPENCODE_API_KEY`), priorities 1–3
- `CHUMP_FREE_TIER_PROVIDERS` is **unset** (that env var switches `execute-gap`
  into the slim 5-tool profile that failed 6/6)
- slots 1–11 remain the free-tier fallbacks (prio 10–35)

## Install (one command)

In Termux on the phone, with `~/chump-repo` checked out:

```bash
bash ~/chump-repo/scripts/setup/setup-pixel-node.sh
```

That installs the scripts into `~/`, stages the boot hook, sets env defaults, and
starts the supervisor. Idempotent.

### Prereqs (done before/once, from the Mac)

1. **Cross-compile + deploy the binary** — `scripts/setup/build-android.sh` builds
   `aarch64-linux-android` with `--no-default-features` + openssl-vendored
   (the `RANLIB_aarch64_linux_android=llvm-ranlib` export is required), then
   `scp` to `~/chump/chump`.
2. **Sync provider keys** — `~/chump/.env` needs the cascade roster
   (`CHUMP_PROVIDER_*`) + `OPENCODE_API_KEY`. These are secrets; sync from the
   Mac, never commit.
3. **Witness creds** — `~/.witness-env` needs `DISCORD_TOKEN` +
   `CHUMP_READY_DM_USER_ID` (chmod 600). The probe reads them at runtime; they
   are never committed.
4. **Fresh gap registry** — the worker picks from
   `~/chump-repo/.chump/state.db`, rebuilt from the committed `.chump/state.sql`
   via `chump gap restore --from-sql`. The committed `state.sql` lags the live
   registry (reaped gaps can linger as `open`), so re-run `git pull` +
   `chump gap restore --from-sql` before a long run.
5. **Termux:Boot (F-Droid)** — the boot hook is staged; the app fires it on boot.
   Note: `adb install` of Termux:Boot v0.8.1 fails (`INSTALL_FAILED_SHARED_USER_INCOMPATIBLE`)
   — its signing key predates the installed Termux 0.119.0-beta.3. Fix = reinstall
   Termux stable v0.118.3 + Termux:Boot v0.8.1 from the same signing era, or
   defer (the node survives normal ops without it).
6. **Phantom-process bypass (Android 14)** — once, over USB:
   ```bash
   adb shell device_config put activity_manager max_phantom_processes 2147483647
   adb shell settings put global settings_enable_monitor_phantom_procs false
   adb shell device_config set_sync_disabled_for_tests persistent
   ```
   Without this Android may kill the loops under memory pressure.

## Resilience model

| Failure | Recovery |
|---|---|
| worker/witness loop dies (OOM, phantom-kill) | `pixel-node-supervisor.sh` respawns within 60s |
| reboot | Termux:Boot hook starts `sshd` + supervisor |
| Doze/sleep | `termux-wake-lock` held by the supervisor |
| gap too hard for the model | worker cooldown (1h) → advances to next gap |
| provider rate-limit/404 | cascade falls through 14 slots |

## Cross-compile path

`scripts/setup/build-android.sh` produces the aarch64 binary from the Mac. The
two changes that made it work again (2026-08-16, RESILIENT-336):
- `--no-default-features` drops `web-push` (which pulls `ece` → `openssl-sys`)
- target-scoped `openssl = { features = ["vendored"] }` in `Cargo.toml` compiles
  OpenSSL from source for `axonerai`'s `native-tls` chain (durable fix =
  [INFRA-3627](gaps/INFRA-3627.yaml): patch axonerai to rustls-tls).
