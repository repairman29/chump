#!/usr/bin/env bash
# W3.3 — Repo health sweep: diagnostics + optional safe auto-fix (chmod +x on scripts/*.sh only).
# Run from repo root. Exits 0 always unless a fatal error (e.g. not a git repo).
#
# Checks: git worktree dirty, .git size hint, large files, scripts/*.sh executable bits,
#         cargo metadata quick parse.
#
# Optional: REPO_HEALTH_JSONL=path to append one JSON summary line.
# Safe auto-fix: REPO_HEALTH_AUTOFIX=1 — chmod +x only on top-level scripts/*.sh missing +x.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== repo-health-sweep: $ROOT =="

if [[ ! -d .git ]]; then
  echo "WARN: not a git checkout (no .git)"
fi

echo "-- git status (short)"
git status -sb 2>/dev/null || echo "(git status failed)"

echo "-- .git disk (du -sh)"
du -sh .git 2>/dev/null || true

echo "-- large files (>= 8 MiB, excluding .git)"
find . -path "./.git" -prune -o -type f -size +8M -print 2>/dev/null | head -25 || true

echo "-- shell scripts missing executable bit (top-level scripts/*.sh)"
missing_exec=$(find scripts -maxdepth 1 -name "*.sh" ! -perm -111 2>/dev/null | head -50 || true)
if [[ -z "${missing_exec//[$'\n\r']/}" ]]; then
  echo "(none)"
else
  echo "$missing_exec"
  if [[ "${REPO_HEALTH_AUTOFIX:-0}" == "1" ]]; then
    echo "-- AUTOFIX: chmod +x (REPO_HEALTH_AUTOFIX=1)"
    echo "$missing_exec" | while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      chmod +x "$f" && echo "  fixed: $f"
    done
  fi
fi

echo "-- cargo metadata (no network)"
if command -v cargo >/dev/null; then
  cargo metadata --no-deps --format-version 1 >/dev/null && echo "OK: cargo metadata" || echo "WARN: cargo metadata failed"
else
  echo "SKIP: cargo not in PATH"
fi

if [[ -n "${REPO_HEALTH_JSONL:-}" ]]; then
  dirty=0
  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && dirty=1
  git_bytes=$(du -sk .git 2>/dev/null | awk '{print $1}' || echo 0)
  printf '{"ts":"%s","repo":"%s","git_dirty":%s,"git_kb":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROOT" "$dirty" "$git_bytes" >>"$REPO_HEALTH_JSONL"
  echo "Appended summary to $REPO_HEALTH_JSONL"
fi

fix_note="read-only"
[[ "${REPO_HEALTH_AUTOFIX:-0}" == "1" ]] && fix_note="autofix chmod applied where needed"
echo "== repo-health-sweep done ($fix_note) =="
