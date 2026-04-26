#!/usr/bin/env bash
# Create a local annotated tag pointing at a superseded remote branch (safe default:
# does not delete the remote branch). See docs/archive/SUPERSEDED_BRANCHES.md.
#
# Usage:
#   ./scripts/coord/archive-superseded-branch.sh origin/claude/heuristic-swanson
# Then: git push origin "archive/..."   # tag name printed at end
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

REMOTE_REF="${1:?usage: $0 <remote-ref>  e.g. origin/claude/heuristic-swanson}"

git fetch origin
if ! git rev-parse --verify -q "${REMOTE_REF}^{commit}" >/dev/null; then
  echo "error: ref not found after fetch: $REMOTE_REF" >&2
  exit 1
fi

branch="${REMOTE_REF#origin/}"
slug="${branch//\//-}"
TAG="archive/${slug}-$(date -u +%Y%m%d)"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "error: tag already exists: $TAG" >&2
  exit 1
fi

git tag -a "$TAG" -m "Archive superseded branch $REMOTE_REF (see docs/archive/SUPERSEDED_BRANCHES.md)" "$REMOTE_REF"
echo "Created annotated tag: $TAG"
echo "Push with: git push origin $TAG"
echo "Optional delete remote branch after push: git push origin --delete ${branch}"
