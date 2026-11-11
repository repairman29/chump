# RESILIENT-1648 — close: already fixed by RESILIENT-1652

The gap asked for `compute()` to take the pause state explicitly so farmer_status tests
don't read the host `CHUMP_NODE_MODE` / `node.env`. RESILIENT-1652 (#5610) already did this:

- `compute_at(repo_root, state_dir)` in `src/farmer_status.rs` takes an explicit node state
  dir; `compute()` is only the production wrapper.
- `node_is_paused` no longer consults the `CHUMP_NODE_MODE` env var at all.
- `heartbeat_stale_fails_and_explains_why` uses `compute_at` with a clean temp state dir;
  `compute_at_reads_passed_state_dir_not_host` pins the hermetic guarantee.
- No assertions were removed; `stale_token_reds_by_default` is untouched.

No code change. Closed as superseded.
