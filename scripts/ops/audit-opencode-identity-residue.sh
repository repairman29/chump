#!/usr/bin/env bash
# Audit linked-worktree git configs for t@t.t / placeholder identity stamps
# left by the pre-fix opencode-bigpickle harness.
#
# Usage: audit-opencode-identity-residue.sh [--apply]
#   --apply   unset the bogus identity values (dry-run otherwise)
#
# INFRA-1020 — one-shot cleanup; opencode has since been fixed so residue is bounded.
set -euo pipefail

APPLY=0
for arg in "$@"; do
  [[ "$arg" == "--apply" ]] && APPLY=1
done

# Resolve REPO_ROOT: follow the linked worktree's .git file to find main repo
# (INFRA-779: git rev-parse --show-toplevel can return wrong path in /tmp worktrees)
_script_dir="$(cd "$(dirname "$0")" && pwd)"
_wt_root="$(cd "$_script_dir/../.." && pwd)"  # scripts/ops -> scripts -> repo root
_git_ptr="$_wt_root/.git"
if [[ -f "$_git_ptr" ]]; then
  # .git is a file in a linked worktree — e.g. "gitdir: /path/to/.git/worktrees/X"
  _gitdir="$(awk '/^gitdir:/{print $2}' "$_git_ptr")"
  # .git/worktrees/<name> -> repo root is three levels up
  REPO_ROOT="$(cd "$_gitdir/../../.." && pwd)"
else
  REPO_ROOT="$_wt_root"
fi
WORKTREES_DIR="$REPO_ROOT/.git/worktrees"
AMBIENT_LOG="$REPO_ROOT/.chump-locks/ambient.jsonl"

if [[ ! -d "$WORKTREES_DIR" ]]; then
  echo "[INFRA-1020] No worktrees directory at $WORKTREES_DIR — nothing to audit."
  exit 0
fi

found=0
swept=0

while IFS= read -r -d '' config_file; do
  wt_name="$(basename "$(dirname "$config_file")")"

  # Read email and name from this worktree's config.worktree (local overrides only)
  email="$(git config --file "$config_file" user.email 2>/dev/null || true)"
  name="$(git config --file "$config_file" user.name 2>/dev/null || true)"

  bogus_email=0
  bogus_name=0

  # Flag canonical opencode pre-fix stamps: t@t.t or any 1–3 char email/name
  if [[ -n "$email" ]]; then
    if [[ "$email" == "t@t.t" ]] || [[ "${#email}" -le 3 ]]; then
      bogus_email=1
    fi
  fi
  if [[ -n "$name" ]]; then
    if [[ "$name" == "t" ]] || [[ "${#name}" -le 2 ]]; then
      bogus_name=1
    fi
  fi

  if [[ $bogus_email -eq 0 && $bogus_name -eq 0 ]]; then
    continue
  fi

  found=$((found + 1))
  mtime="$(stat -f "%Sm" -t "%Y-%m-%dT%H:%M:%SZ" "$config_file" 2>/dev/null || stat -c "%y" "$config_file" 2>/dev/null || echo "unknown")"

  echo "[INFRA-1020] FOUND residue in worktree: $wt_name"
  [[ $bogus_email -eq 1 ]] && echo "  user.email = $email"
  [[ $bogus_name -eq 1 ]]  && echo "  user.name  = $name"
  echo "  config file: $config_file"
  echo "  mtime: $mtime"

  if [[ $APPLY -eq 1 ]]; then
    [[ $bogus_email -eq 1 ]] && git config --file "$config_file" --unset user.email && echo "  [APPLY] unset user.email"
    [[ $bogus_name -eq 1 ]]  && git config --file "$config_file" --unset user.name  && echo "  [APPLY] unset user.name"

    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"identity_residue_swept","worktree":"%s","removed_email":"%s","removed_name":"%s","count":1}\n' \
      "$ts" "$wt_name" "${email:-}" "${name:-}" \
      >> "$AMBIENT_LOG" 2>/dev/null || true

    swept=$((swept + 1))
  fi
done < <(find "$WORKTREES_DIR" -name "config.worktree" -print0 2>/dev/null)

# Also check main .git/config for any lingering user.email / user.name
main_email="$(git -C "$REPO_ROOT" config --local user.email 2>/dev/null || true)"
main_name="$(git -C "$REPO_ROOT" config --local user.name 2>/dev/null || true)"
main_bogus=0
if [[ -n "$main_email" ]] && { [[ "$main_email" == "t@t.t" ]] || [[ "${#main_email}" -le 3 ]]; }; then
  echo "[INFRA-1020] FOUND residue in main .git/config: user.email=$main_email"
  main_bogus=1
  found=$((found + 1))
fi
if [[ -n "$main_name" ]] && { [[ "$main_name" == "t" ]] || [[ "${#main_name}" -le 2 ]]; }; then
  echo "[INFRA-1020] FOUND residue in main .git/config: user.name=$main_name"
  main_bogus=1
  found=$((found + 1))
fi
if [[ $main_bogus -eq 1 && $APPLY -eq 1 ]]; then
  [[ -n "$main_email" ]] && git -C "$REPO_ROOT" config --unset user.email 2>/dev/null || true
  [[ -n "$main_name" ]]  && git -C "$REPO_ROOT" config --unset user.name  2>/dev/null || true
  echo "[INFRA-1020] [APPLY] cleared main .git/config identity"

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","kind":"identity_residue_swept","worktree":"main","removed_email":"%s","removed_name":"%s","count":1}\n' \
    "$ts" "${main_email:-}" "${main_name:-}" \
    >> "$AMBIENT_LOG" 2>/dev/null || true

  swept=$((swept + 1))
fi

if [[ $found -eq 0 ]]; then
  echo "[INFRA-1020] No identity residue found — all worktree configs are clean."
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","kind":"identity_residue_swept","worktree":"all","removed_email":"","removed_name":"","count":0}\n' \
    "$ts" >> "$AMBIENT_LOG" 2>/dev/null || true
  exit 0
fi

echo ""
if [[ $APPLY -eq 0 ]]; then
  echo "[INFRA-1020] Found $found residue(s). Re-run with --apply to clear."
  exit 1
else
  echo "[INFRA-1020] Swept $swept residue(s)."
fi
