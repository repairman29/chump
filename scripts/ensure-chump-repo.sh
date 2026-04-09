#!/usr/bin/env bash
# Verify we're in the Chump repo with origin pointing at the Chump GitHub repo.
# Use before push, or source to set CHUMP_REPO_OK=1. Exit 1 if not.
# Usage: bash scripts/ensure-chump-repo.sh [--push]  (--push = run git push after verify)

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

CHUMP_ORIGIN_URL="https://github.com/repairman29/chump.git"
REPO_NAME="chump"

ok=1
if [[ ! -f "$ROOT/Cargo.toml" ]] || [[ ! -f "$ROOT/run-local.sh" ]]; then
  echo "Not in Chump repo root (missing Cargo.toml or run-local.sh). Current dir: $ROOT"
  ok=0
fi

origin_url=$(git remote get-url origin 2>/dev/null || true)
if [[ "$origin_url" != "$CHUMP_ORIGIN_URL" ]] && [[ "$origin_url" != "git@github.com:repairman29/chump.git" ]]; then
  echo "origin is not the Chump repo. origin=$origin_url (expected repairman29/chump)"
  ok=0
fi

if [[ $ok -eq 0 ]]; then
  echo "Run this script from the Chump repo: cd ~/Projects/Chump && bash scripts/ensure-chump-repo.sh"
  exit 1
fi

echo "OK: Chump repo at $ROOT, origin -> $origin_url"
if [[ "${1:-}" == "--push" ]]; then
  shift
  git push "$@"
fi
