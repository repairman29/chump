# Changelog

All notable changes to Chump are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] — 2026-04-16 — Initial public release

First public release. Chump graduates from private development to an open-source project with full community infrastructure.

### Highlights

- **Single-binary Rust agent** on OpenAI-compatible inference (Ollama, vLLM, mistral.rs) with SQLite + FTS5 persistence
- **Four surfaces**: web PWA, CLI, Discord bot, Tauri desktop shell
- **Six-module consciousness framework** (surprise tracker, memory graph, blackboard, neuromodulation, precision controller, phi proxy) with A/B testing harness
- **Procedural skills system** with Bradley-Terry evolution, skill mutation, SHA-256 deterministic caching
- **Three-way retrieval pipeline** (keyword + semantic + graph) merged by RRF with freshness decay
- **Agent Client Protocol (ACP)** stdio server — launchable from Zed, JetBrains IDEs, and any ACP-compatible client
- **Bounded autonomy** with task contracts, graduated escalation, two-bot fleet coordination
- **Security hardening**: leak scanning, SSRF protection, host-boundary secret pinning, `cargo-audit` in CI
- **530+ tests** across 80+ modules; full documentation at [repairman29.github.io/chump](https://repairman29.github.io/chump/)

See detailed feature list and historical changes below.

[0.1.0]: https://github.com/repairman29/chump/releases/tag/v0.1.0

---

## Pre-release history

### Changes

- **Post-Cascade roadmap (Phases 2–6):** Multi-repo tools, quality guards, context window, ops maturity, fleet expansion.
  - **Phase 2:** `set_working_repo` (override repo root); `onboard_repo` (9-step brief + architecture); `repo_authorize` / `repo_deauthorize` + `chump_authorized_repos` table; allowlist in git/gh tools.
  - **Phase 3:** Mandatory `diff_review` before commit (high-severity blocks); `chump_provider_quality` + sanity-fail circuit feedback + slots with >10% sanity-fail skipped; test-aware editing (baseline, regression, auto-stash on failure when `CHUMP_TEST_AWARE=1`).
  - **Phase 4:** `CHUMP_PREFER_LARGE_CONTEXT` + Gemini routing; `codebase_digest` tool + inject in context; summarization threshold doubles for providers with context >32k.
  - **Phase 5:** Per-provider cost tracking + daily Discord summary; latency/tool-call quality + auto-demotion; `warm_probe_all()` + `--warm-probe` CLI + heartbeat pre-round probe.
  - **Phase 6:** `external_work` and `review` round types in heartbeat (multi-repo work; PR review via `gh api /notifications` + `gh_pr_comment`).
- **Phase 1–4 (dogfood & self-improve):** Repo awareness, read/write tools, GitHub read, git commit/push.
  - **Phase 1:** `CHUMP_REPO` / `CHUMP_HOME`; `read_file`, `list_dir` (path under root, no `..`).
  - **Phase 2:** `write_file` (overwrite/append) with path guard and audit in `logs/chump.log`.
  - **Phase 3:** `GITHUB_TOKEN` + `CHUMP_GITHUB_REPOS`; `github_repo_read`, `github_repo_list`; optional `github_clone_or_pull` to sync repos under `CHUMP_HOME/repos/`.
  - **Phase 4:** `git_commit`, `git_push` in CHUMP_REPO for allowlisted repos; full audit; prompt says only push after user says "push" or "commit" unless `CHUMP_AUTO_PUSH=1`.
- **Executive mode:** `CHUMP_EXECUTIVE_MODE=1` skips allowlist/blocklist for `run_cli`, uses `CHUMP_EXECUTIVE_TIMEOUT_SECS` and `CHUMP_EXECUTIVE_MAX_OUTPUT_CHARS`; every run logged with `executive=1`.
- **Super powers:** When repo + GitHub + git are configured, system prompt adds self-improve hint (read docs → edit → test → commit/push when approved). `CHUMP_AUTO_PUSH=1` allows push after commit without a second confirmation.

### Fixes

- None this release.
