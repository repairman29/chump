# Changelog

All notable changes to the Chump rust-agent are documented here.

## [Unreleased]

### Changes

- **Phase 1–4 (dogfood & self-improve):** Repo awareness, read/write tools, GitHub read, git commit/push.
  - **Phase 1:** `CHUMP_REPO` / `CHUMP_HOME`; `read_file`, `list_dir` (path under root, no `..`).
  - **Phase 2:** `write_file` (overwrite/append) with path guard and audit in `logs/chump.log`.
  - **Phase 3:** `GITHUB_TOKEN` or `CHUMP_GITHUB_TOKEN` + `CHUMP_GITHUB_REPOS`; `github_repo_read`, `github_repo_list`; optional `github_clone_or_pull` to sync repos under `CHUMP_HOME/repos/`.
  - **Phase 4:** `git_commit`, `git_push` in CHUMP_REPO for allowlisted repos; full audit; prompt says only push after user says "push" or "commit" unless `CHUMP_AUTO_PUSH=1`.
- **Executive mode:** `CHUMP_EXECUTIVE_MODE=1` skips allowlist/blocklist for `run_cli`, uses `CHUMP_EXECUTIVE_TIMEOUT_SECS` and `CHUMP_EXECUTIVE_MAX_OUTPUT_CHARS`; every run logged with `executive=1`.
- **Super powers:** When repo + GitHub + git are configured, system prompt adds self-improve hint (read docs → edit → test → commit/push when approved). `CHUMP_AUTO_PUSH=1` allows push after commit without a second confirmation.

### Fixes

- None this release.
