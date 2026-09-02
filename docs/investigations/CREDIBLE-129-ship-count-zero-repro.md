# CREDIBLE-129: reproducing the intermittent ship-count-zero false-negative

**Slice:** CREDIBLE-597 (reproduce only; the fix itself lives on CREDIBLE-129).
**Repro script:** [`scripts/dev/repro-ship-count-zero.sh`](../../scripts/dev/repro-ship-count-zero.sh)

## Symptom (from CREDIBLE-129)

`fleet-brief.sh` (the SessionStart banner) intermittently printed
`Ships: 0 (24h) | last 1h: 0` + "fleet looks healthy" while ground truth was
2 merges in the last hour, 24 live `worker.sh` procs, 42 `claude -p` procs,
13 in-flight `bot-merge`. ~30 min earlier the *same script* correctly
reported `Ships: 43 | last 1h: 9`. No error was logged anywhere.

## Root cause (reproduced, not theorized)

`fleet-brief.sh`'s ship-count reader:

```bash
_git_log_24h() { git -C "$MAIN_REPO" log --format="%s" --after="24 hours ago" origin/main 2>/dev/null || true; }
...
ships_24h=$(echo "$_subjects_24h" | grep -c . 2>/dev/null || true)
```

`origin/main` is resolved from a **loose ref file**,
`.git/refs/remotes/origin/main`. That file is not permanently stable:

- A real `git fetch` (including the `git fetch origin main --quiet` in
  CLAUDE.md's mandatory pre-flight, run by every worker/session) opportunistically
  triggers `git gc --auto` / `git pack-refs` once loose-ref/object counts cross
  a threshold. That operation migrates the loose ref into `packed-refs` and
  then **removes the loose file** — there is a window where the loose ref is
  gone and any reader hitting that exact moment sees an unresolvable
  `origin/main`.
- A `git fetch` that is killed or times out mid-negotiation (network stall,
  the `timeout 15` wrapper in `ambient-context-inject.sh`'s SessionStart hook,
  a hung SSH transport, etc.) can leave the repo in the same
  ref-momentarily-missing state depending on exactly where in the ref-update
  sequence it was interrupted.

When `origin/main` is unresolvable, `git log ... origin/main` exits 128
(`fatal: ambiguous argument 'origin/main': unknown revision`). The script's
own `2>/dev/null` throws away the fatal error, and `|| true` throws away the
non-zero exit code — so `_subjects_24h` becomes `""`, `grep -c .` on empty
input reports `0`, and `ships_24h=0`. **No error is surfaced at any layer** —
this is the "swallowed subshell error" the gap description names, now
demonstrated end to end rather than assumed.

## Reproduction

```bash
bash scripts/dev/repro-ship-count-zero.sh
```

The script (in a disposable `/tmp` sandbox, never touching the real repo):

1. Builds a fresh bare "origin" repo and pushes 3 commits to `main` — real
   ships.
2. Runs `fleet-brief.sh` against it: **`Ships: 3`** (ground truth, matches).
3. Forces the failure window by removing `.git/refs/remotes/origin/main` —
   this is the exact on-disk state a real fetch transiently produces during
   ref-consolidation, or leaves behind if killed mid-update.
4. Shows the undoctored `git log ... origin/main` call: `fatal: ambiguous
   argument 'origin/main': unknown revision ...`, `exit=128`.
5. Shows the *same* call executed exactly as `_git_log_24h()` invokes it
   (`2>/dev/null || true`): captured output is empty, no error visible.
6. Runs `fleet-brief.sh` again in that state: **`Ships: 0`** — the false
   negative, reproduced on demand, deterministically, no timing race needed.
7. Restores the ref and re-runs `fleet-brief.sh`: back to **`Ships: 3`**,
   confirming the repo/data were never actually damaged — only the *read*
   was transiently wrong. This matches CREDIBLE-129's observation that the
   very same script recovered to a correct count ~30 min later with no
   intervention.

### Observed output (captured 2026-09-02)

```
=== 2. Ground truth: fleet-brief.sh with an intact origin/main ref ===
═══ Fleet brief (last 24h) ═══
Ships: 3 (≈0.1/hr) | last 6h: 3 | last 1h: 3
Pillars: CREDIBLE=3

=== 3. Force the failure window: origin/main transiently unresolvable ===
--- git log against the missing ref (stderr shown, undoctored) ---
fatal: ambiguous argument 'origin/main': unknown revision or path not in the working tree.
Use '--' to separate paths from revisions, like this:
'git <command> [<revision>...] -- [<file>...]'
exit=128

--- same call exactly as fleet-brief.sh's _git_log_24h() runs it (stderr silenced, failure swallowed by || true) ---
captured subjects: '<>' (empty)

=== 4. fleet-brief.sh during the failure window ===
═══ Fleet brief (last 24h) ═══
Ships: 0 (≈0.0/hr) | last 6h: 0 | last 1h: 0
Pillars:

=== 5. Restore the ref — fleet-brief.sh recovers with no state changed ===
═══ Fleet brief (last 24h) ═══
Ships: 3 (≈0.1/hr) | last 6h: 3 | last 1h: 3
Pillars: CREDIBLE=3
```

## Notes for the fix (CREDIBLE-129, out of scope here)

- `src/main.rs`'s `chump fleet brief` Rust path (`count_merges_since`) has the
  **identical** swallow pattern: `.output().ok().filter(|o| o.status.success())
  ... .unwrap_or(0)` — a failed `git log` call collapses to `0` with no
  distinction from "checked, zero ships." Any fix must cover both the shell
  and Rust implementations, or the Rust path (preferred, tried first by
  `ambient-context-inject.sh`) will keep reproducing this after the shell
  script is patched.
- The AC in CREDIBLE-129 wants "unavailable" reported instead of a bare `0`
  when the underlying git call fails — that requires distinguishing
  `git log` exit-128 (ref unresolved) from a genuinely successful call that
  legitimately returned zero commits, which this repro shows is a clean,
  checkable distinction (`$?` / `Command::status()`), not a heuristic.
