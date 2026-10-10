# RESILIENT-406 — closed as duplicate of already-shipped self-healing

RESILIENT-406 ("Implement self-healing for almanac binary and index",
RESILIENT-367 slice) restates acceptance criteria that `scripts/ops/almanac-liveness-refresh.sh`
already satisfies in full, verified against current `main`:

1. *A revivable gate detects missing binary / empty or stale index* —
   `scripts/ops/almanac-liveness-refresh.sh` is registered as a systemd oneshot
   (`scripts/dispatch/chump-almanac-liveness.service`, paired with
   `chump-almanac-liveness.timer`) deployed by
   `scripts/setup/install-helsinki-atc.sh`, and wired into the per-user node
   installer via `scripts/setup/install-almanac-organ.sh` (INFRA-3710). Section
   1 of the script detects a missing/drifted binary; section 2b detects an
   empty or stale fleet index (`indexed_files==0` or the fleet-index sweep
   marker older than `CHUMP_ALMANAC_STALE_FLOOR_S`).
2. *Missing binary triggers an automatic rebuild from origin/main* —
   `almanac-liveness-refresh.sh` lines 110-174 (INFRA-8038) clone/fetch/reset a
   dedicated build checkout (`~/.almanac/almanac-build-src`) to `origin/main`
   and `cargo build --release --bin almanac --bin almanac-mcp` whenever the
   binary is missing or has drifted from the tracked commit — this is the
   "rebuild almanac from origin/main" install path the gap asks for, run
   automatically rather than requiring a separate manual install-script
   invocation.
3. *Empty/stale index triggers re-indexing* — lines 213-268 (INFRA-3639)
   detect `indexed_files==0` or a missing/stale fleet-index marker and drive
   `scripts/ops/index-almanac.sh` directly in the same cycle, re-probing
   `almanac stats` afterward so the recovery is visible immediately.
4. *Self-healing is logged, and the health probe reports healthy metrics
   after recovery* — every rebuild/reindex emits a scanner-anchored ambient
   event (`almanac_liveness_binary_built`, `almanac_liveness_binary_rebuilt`,
   `almanac_liveness_reindex_triggered`, and failure counterparts), and the
   `almanac_health` probe (INFRA-3638/TREK-13, emitted every cycle at line
   279) reports the post-heal `indexed_files` / `binary_present` /
   `last_index_age_s` in the same run — proven by
   `scripts/ci/test-almanac-liveness-reindex.sh` case 1 (empty index
   self-heals to `indexed_files>0` in one cycle) and
   `scripts/ci/test-refresh-almanac-binary.sh` (missing/drifted binary
   rebuild).
5. *The exact blindness scenario (binary vanished or index stale) is handled
   without human intervention* — RESILIENT-405 (#5230) closed the remaining
   gap here: the probe now exits non-zero (`exit 2`) only when the binary is
   *still* missing or the index is *still* stale **after** the self-heal
   attempts above, mirroring `almanac-summarize-watchdog.sh`'s
   attempt-then-alert posture — so a supervisor only pages when the automatic
   recovery genuinely failed, not on every transient blip.

RESILIENT-406 is closed as a duplicate rather than re-implemented, to avoid
shipping a second, parallel self-healing path next to the one already
covering every AC above (INFRA-3643 / INFRA-3639 / INFRA-8038 / RESILIENT-405).
