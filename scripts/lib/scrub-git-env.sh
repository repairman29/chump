#!/usr/bin/env bash
# scripts/lib/scrub-git-env.sh — RESILIENT-090 (2026-06-04)
#
# Source from any shell test script that runs `git init` / `git commit`
# in a tmp dir. Removes the GIT_* env vars that git sets and exports for
# child processes of a pre-push hook:
#
#   GIT_DIR          — absolute path to the worktree's .git/worktrees/<name>
#   GIT_WORK_TREE    — absolute path to the worktree root
#   GIT_COMMON_DIR   — absolute path to the main repo's .git
#   GIT_INDEX_FILE   — absolute path to the worktree's index
#   GIT_OBJECT_DIRECTORY  — absolute path to objects (rare; clear for safety)
#   GIT_NAMESPACE    — refs namespace (rare; clear for safety)
#
# Why this exists:
#
# When git invokes the pre-push hook, it exports these vars so the hook can
# operate on the same repo state as the push. The vars survive into every
# subprocess: chump preflight → scripts/ci/test-*.sh → `git init` in mktemp.
#
# `git` ignores `pwd` when GIT_DIR is set in env. So `cd $TMP/repo &&
# git init -q && git commit -m "init"` does NOT create an isolated repo —
# it commits IN the operator's worktree, with HEAD as parent. The push
# then ships those commits.
#
# This bug bit PR #2066 in 2026-04 (INFRA-1352) and PRs #3007/#3006/#2975
# in 2026-06 (RESILIENT-085/089). Each incident produced 4-14 garbage
# commits ("init", "chore: initial commit", "test(INFRA-849)…") on
# operator branches that broke pr-hygiene and fast-checks downstream.
#
# Defense: this scrub. INFRA-1372 + src/repo_path.rs:686 already does it
# for Rust code via a git_cmd! macro. This file is the shell equivalent.
#
# Usage:
#   # At the top of any shell test that runs git operations:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/scrub-git-env.sh"
#
# OR (inline, if sourcing is awkward):
#   unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
#         GIT_OBJECT_DIRECTORY GIT_NAMESPACE
#
# The companion guards from RESILIENT-085 #3027 and RESILIENT-089 #3031
# remain belt; this scrub is the suspenders. Even if a test forgets the
# worktree-safety guard, the env scrub prevents pollution.
#
# Bypass: none (by design). If a test legitimately needs GIT_DIR (very
# rare — debugging hooks-from-hooks), it should set GIT_DIR after this
# source line.

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_NAMESPACE
