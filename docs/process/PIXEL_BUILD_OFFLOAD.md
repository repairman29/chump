# Owned-iron build offload — the Pixel is the fleet's aarch64 build box (RESILIENT-1044)

## Why this exists

The 2-core Oracle nodes (cuphead = brain, mugman) are aarch64/glibc-2.35 with
11 GB RAM. A local `cargo build --release` on one of them starves the live fleet
— it caused a ~3 h stall once — so an **on-node cold build is FORBIDDEN**.

Until now the only prebuilt-binary source was `build-fleet-binaries.yml` on
**GitHub-hosted runners, which are rented**. When that artifact was missing for a
green-main SHA (doc-only commit, gh unauthed, CI slow), `node-refresh-chump.sh`
fell through to a cold cargo build on the node itself — the forbidden path.

We already **own** ample build capacity that was sitting unwired: the **Pixel**
(`ssh termux`) — aarch64, **8 real cores**, 11.5 GB RAM, 4× the brain's cores.
This organ makes the Pixel the owned builder so nodes never cold-build.

## The load-bearing fact: same arch is not enough — libc ABI differs

The Pixel's native rustc host is **`aarch64-linux-android`** (Termux = Android
**bionic** libc). A binary built natively there links bionic and **will not run**
on the Oracle nodes (Ubuntu glibc). Same CPU arch, different C ABI.

The fix: build inside an **Ubuntu 22.04 proot-distro container (glibc 2.35)** on
the Pixel, producing a genuine `aarch64-unknown-linux-gnu` binary whose glibc
floor **matches the nodes** (and matches CI's pinned `ubuntu-22.04`, chosen for
the same RESILIENT-1038 reason). Building in a newer distro (24.04 = glibc 2.39,
26.04 = glibc 2.43) would reproduce the `GLIBC_x not found` trap that makes the
binary refuse to run on the nodes.

## The three binary sources a node tries, in order

`scripts/ops/node-refresh-chump.sh`, when the installed binary is stale:

1. **CI artifact** — `build-fleet-binaries.yml` per-SHA Actions artifact
   (GitHub-hosted, **rented**, $0 while the repo is public). `_try_artifact_pull`.
2. **Owned Pixel-built release asset** — this organ. `_try_release_pull` pulls
   `chump-<target>-<sha>` from the `fleet-binaries` GitHub Release. **← new, OWNED.**
3. **Local cargo build on the node** — last resort, forbidden on 2-core nodes,
   now only reachable if BOTH owned/free sources miss.

All three install through the same sha256 + `--version` SHA checks, so a node is
never worse off — only faster and cold-build-free when an owned asset exists.

## Components (all in `scripts/ops/`)

| File | Runs on | Does |
|------|---------|------|
| `pixel-build-and-publish.sh` | the Pixel (Termux) | build in the glibc proot → publish `chump-<target>-<sha>` (+ `.sha256`) to the `fleet-binaries` release. Idempotent (skips if the asset already exists). Bootstraps the proot + toolchain on first run. |
| `build-on-pixel.sh` | brain / any ops host | resolve green-main SHA, ship the worker to the Pixel, ssh-run it, verify the asset landed. **Does NO local cargo — only ssh's the Pixel, so it is brain-safe.** |
| `chump-pixel-builder.{service,timer}` + `install-pixel-builder-systemd.sh` | brain / ops host | run `build-on-pixel.sh` every 30 min so a Pixel-built binary is usually waiting before a node's refresh looks for it. |
| `node-refresh-chump.sh` (`_try_release_pull`) | every Linux node | pull the owned-built asset before ever cold-building. |

## Run it

```bash
# One-shot: build green-main on the Pixel + publish (from the brain or any ops host)
scripts/ops/build-on-pixel.sh                 # green-main SHA, auto-resolved
scripts/ops/build-on-pixel.sh --sha <sha>     # a specific commit
scripts/ops/build-on-pixel.sh --force         # rebuild + re-upload even if present

# Install the 30-min timer on the brain (no local cargo; ssh-drives the Pixel)
scripts/ops/install-pixel-builder-systemd.sh
```

Preconditions: the ops host can `ssh termux` non-interactively (key-based) and
the Pixel has `gh auth login` done (for the release upload).

## Node-side knobs (`node-refresh-chump.sh`)

- `CHUMP_NODE_RELEASE_TAG` — release to pull owned-built assets from (default `fleet-binaries`).
- `CHUMP_NODE_SKIP_RELEASE_PULL=1` — skip the owned source (force the next path).

## HARDEN-THE-OS

This provisions the missing capability so the wrong thing becomes impossible: a
node reaches the forbidden on-node cold build only when the rented CI artifact
**and** the owned Pixel-built asset are both absent — instead of the moment CI
happens not to have an artifact. Ownership of the builder moves off rented
runners onto Jeff's own iron.
