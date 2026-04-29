---
doc_tag: artifact
gap: PRODUCT-017
machine_class: dev (NOT clean — does not satisfy gap acceptance)
recorded_by: claude
recorded_at: 2026-04-28
---

# FTUE Verification — 2026-04-28 (dev-machine baseline)

> **Status: PRODUCT-017 NOT closed.** This run was on the project author's
> active dev machine, not a clean Mac / fresh VM. The gap acceptance
> requires a clean-machine run; this artifact is a sentinel baseline only.
> When someone runs the full `brew install chump → PWA in <60s` flow on a
> wiped or fresh machine, replace `machine_class: dev` with `clean` and
> consider closing PRODUCT-017 if the result passes.

## Result

**PASS — `chump init → PWA` ready in 15.3s** (vs 90s CI budget, 60s UX-001 promise).

```
[ftue] Starting FTUE measurement (budget=90s)
[ftue] PWA target: http://localhost:3000/v2/
🚀  chump init — first-run setup
  [1/4] model detection ... found qwen2.5:7b via Ollama (localhost:11434)
  [2/4] .env already exists — skipping write
         waiting for server............... timeout — server may still be starting
  [3/4] server started on port 3000
  [4/4] opening http://localhost:3000/v2/
  ✓  Setup complete.
     PWA: http://localhost:3000/v2/
[ftue] Waiting for PWA to respond...
[ftue] READY in 15.3s
[ftue] PASS: 15.3s <= 90s budget
```

## Environment

- **macOS:** 26.2 (build 25C56)
- **Repo SHA:** `902f508` (origin/main)
- **chump binary:** `~/.local/bin/chump` content-hash matches today's `target/release/chump` — INFRA-147 fix in effect
- **Ollama:** running, `qwen2.5:7b` already cached
- **Port 3000:** free at start (any prior chump server killed via `pkill`)
- **`.env`:** pre-existing (chump init step `[2/4]` skipped write)

## Why this does NOT close PRODUCT-017

The gap explicitly requires a **clean machine** (fresh VM or wiped Mac):

> Run scripts/measure-ftue.sh on a clean Mac (fresh VM or wiped machine)
> today; (2) commit elapsed time + any failures to
> docs/FTUE-VERIFICATION-YYYY-MM-DD.md; ... Historical passes don't count;
> the gap closes only on a fresh run today.

Specifically NOT verified by this run:
- `brew install chump` (skipped — local binary in PATH already)
- First-ever `chump init` from no `.chump/` and no `.env` (skipped — both pre-existed)
- First-ever Ollama model download (skipped — `qwen2.5:7b` cached)
- Default port 3000 contention on a machine with no prior chump runs

A truly cold start on a fresh box would include:
1. `brew tap repairman29/chump && brew install chump` (variable; depends on Homebrew cache + network)
2. First Ollama model pull (3-5 GB download — typically 30-90s on fast network)
3. Cold `chump init` writing `.env`, `.chump/state.db`, etc.
4. First PWA serve

Items 1-3 likely dominate the wall-clock; the 15.3s observed here measures
only item 4 plus warm `chump init` overhead.

## Observation: bug in `scripts/eval/measure-ftue.sh` — FIXED in INFRA-163

When invoked with `--port 3001` the script sets `PORT=3001` for the
assertion URL but does NOT propagate the port to the underlying
`chump init` invocation. Result: `chump init` still binds to its default
port 3000, the script polls 3001, gets nothing, and fails with
`Hard timeout at 95s`. Worked around by running with default port 3000.

**Resolved in INFRA-163 (2026-04-28).** That change:
- Added real `--port N` and `--no-browser` flags to `chump init`
  (previously `--no-browser` was a non-functional `NO_BROWSER=1` env hack
  the binary never read).
- Propagates both flags from `measure-ftue.sh` so the assertion URL and
  the actual server port stay in sync.
- Stops `measure-ftue.sh` from swallowing `chump init` exit codes
  (`|| true`) — failed inits now report explicitly instead of looking
  like "PWA never responded".
- Fixes `write_minimal_env` writing a hard-coded `CHUMP_WEB_PORT=3000`
  to `.env` even when the user passed a different port.
- Replaces the `bc` fractional-second formatter with `awk` so machines
  without `bc` (minimal Linux images) still report `15.3s`, not `15s`.

Whoever runs the next clean-machine verification won't trip on these.

## Next step (does NOT belong on this dev-machine artifact)

A genuine clean-machine run is still required to satisfy
PRODUCT-017's acceptance. Possible vehicles:
- Fresh OrbStack macOS VM (lightweight on Apple Silicon)
- UTM macOS guest
- A teammate's freshly-wiped or new Mac
- CI runner that starts from a near-clean image

When that run lands, replace this file (or land alongside it as
`docs/FTUE-VERIFICATION-YYYY-MM-DD.md`) and ship the PRODUCT-017
closure if the result is `<60s`.
