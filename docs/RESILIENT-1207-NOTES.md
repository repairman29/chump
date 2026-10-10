# RESILIENT-1207: Why the auto-converge organ failed to install/fire on CJ

> Analysis slice of RESILIENT-1205 (depends on RESILIENT-1206's reproducible
> local test env). Root cause was found and fixed in RESILIENT-1205
> (f7ecc113a, #4641); this note is the design-note deliverable for that
> analysis so it survives as a standing reference instead of only living in
> a commit message.

## AC-1: functions/modules responsible for organ merge + wired install/fire on CJ

| Role | File | Entry point |
|---|---|---|
| Node auto-converge organ (keeps SOURCE tree current) | `scripts/ops/node-converge.sh` | top-level script body; sources `converge_mirror_hard_reset` |
| Node binary refresh (keeps BINARY current, pinned to green) | `scripts/ops/node-refresh-chump.sh` | top-level script body; `_find_green_main_sha`, `_try_artifact_pull`, `_try_release_pull`, `_install_binary` |
| Shared "advance without a merge" primitive | `scripts/coord/lib/converge-mirror.sh` | `converge_mirror_hard_reset <ref>` |
| Organ roster (what CJ's deploy loop installs) | `scripts/ops/organ-manifest.txt` | manifest line for `chump-node-converge` |
| Installer that reads the roster and writes systemd units on CJ | `scripts/setup/install-helsinki-atc.sh` | organ-array entries for `chump-node-converge` |

Both `node-converge.sh` and `node-refresh-chump.sh` advance a working tree.
Per RESILIENT-001, neither may use a `git merge`/`git pull` — fleet nodes
drop untracked generated files (`docs/gaps/*.yaml` mirrors, `chore(backlog)`
auto-commits) into the tree, and a merge-based advance aborts outright on
"untracked working tree files would be overwritten by merge," silently
leaving the node stale. Both scripts instead call the shared
`converge_mirror_hard_reset` primitive (`git reset --hard <ref>`), which
overwrites colliding untracked files and discards local regenerable
commits while never touching gitignored paths (`.chump/state.db`,
`.chump-locks/`, worktrees).

## AC-2: root cause and intended fix

**Root cause (Problem A and B are one bug).** `node-refresh-chump.sh`
reset the *working tree itself* to the last-known-**green** main pointer
(RESILIENT-327), not to raw `origin/main` HEAD. Green lags HEAD whenever
the newest commit has no CI build artifact (e.g. a `chore(backlog):
coherence sync` commit) — which is routine. On CJ this meant the checkout
was reset back to the PR #4640 merge's *parent* commit every ~5 minutes:

```
green-main = 85f7d38c53e9  (raw origin/main HEAD = 57d85ce13fa2)
PIN: raw HEAD (57d8) is ahead of green-main (85f7) — staying pinned at green
HEAD is now at 85f7d38c5 chore(backlog): coherence sync
```

Because the tree never advanced past that parent, it had zero trace of the
node-converge organ added in #4640 — `organ-manifest.txt` and
`install-helsinki-atc.sh` greps returned 0, and
`/etc/systemd/system/chump-node-converge.*` never existed. The organ's own
install code was not in the tree the deploy loop reads, so it structurally
could not install or fire (**Problem A**). Simultaneously, `node-refresh`
(reset-to-green) and `node-converge` (reset-to-HEAD) were fighting over the
*same* working tree every cycle (**Problem B**) — a two-organs-racing-the-
checkout condition that made the symptom look like a flaky merge failure
rather than a deterministic pin-lag.

**Intended fix (shipped, RESILIENT-1205 / f7ecc113a / #4641):** decouple
*where the source tree sits* from *where the binary is built*.

- `node-refresh-chump.sh` now converges the **working tree** to raw
  `origin/main` HEAD every cycle, through the same `converge_mirror_hard_reset`
  primitive node-converge uses — so the two organs target the same ref and can
  never race (fixes Problem B), and a bash-only merge reaches the iron even
  when the binary hash is unchanged.
- The **binary** stays pinned to green (RESILIENT-327): `BUILD_PIN_SHA` is
  tracked independently of the tree's HEAD; a local cold-build builds the
  green pin from a *detached* worktree (reusing the warm `CARGO_TARGET_DIR`)
  so the main checkout stays at HEAD and the installed binary is never an
  unverified HEAD build.
- Once the tree tracks HEAD, the organ's manifest line and installer entries
  are present on disk, so `chump-organ-deploy` installs `chump-node-converge`
  normally (fixes Problem A).

Regression coverage: `scripts/ci/test-node-refresh-green-main.sh` asserts the
source tree lands on `origin/main` HEAD while the installed binary still
reports the green SHA (built from the detached worktree) — the exact
tree/binary split this fix introduced. `scripts/ci/test-node-converge.sh`
covers the sibling organ's `converge_mirror_hard_reset` behavior.

## Status

Fix is live on `main`. This note exists so the analysis remains a durable
reference rather than only a PR description — see RESILIENT-1206 for the
reproducible local harness that exercises this failure mode.

## RESILIENT-1215 (re-decomposition slice) — closed as duplicate

A later re-decomposition of the RESILIENT-1205 umbrella filed RESILIENT-1215
("wire organ merge into the auto-converge code path") as a fresh slice. On
investigation, its 3 acceptance criteria are already satisfied by the fix
described above:

1. *Organ merge correctly invoked during auto-converge* — `node-refresh-chump.sh`
   lines 589-611 unconditionally call `converge_mirror_hard_reset origin/main`
   every cycle, before the binary-idempotency skip, deferring only when a git
   operation (`rebase-merge`/`MERGE_HEAD`/etc.) is already in progress.
2. *Compiles with no new warnings* — no Rust surface was touched by the
   original fix; it's a bash wiring change already on `main`.
3. *Merge step executes without panics* — `scripts/ci/test-node-refresh-green-main.sh`
   (added for RESILIENT-1209, #5226) exercises exactly this path and passes.

RESILIENT-1215 is closed `superseded` (same disposition as its sibling
RESILIENT-1214, superseded by RESILIENT-1207) rather than re-implemented, to
avoid duplicating RESILIENT-1208's (#5224) already-shipped work.
