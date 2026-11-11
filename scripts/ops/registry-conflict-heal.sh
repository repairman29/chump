#!/usr/bin/env bash
# registry-conflict-heal.sh — RESILIENT-1480
#
# Union-rebase organ: auto-heal CONFLICTING PRs whose ONLY conflicts are
# append-only registry files (env-vars-internal.txt, event-registry-reserved.txt,
# organ-manifest.txt, EVENT_REGISTRY.yaml). Any conflict outside that set is left
# untouched and flagged (kind=registry_heal_flagged). Also watches for pile-ups
# (kind=registry_dirty_pileup) so the class cannot rot silently.
#
# Safety: every rebase happens in an ephemeral worktree under $WT_ROOT; the
# shared checkout is never edited; nothing is ever pushed to main.
#
# Env:
#   CHUMP_REGISTRY_HEAL=0          bypass (exit 0)
#   REGISTRY_HEAL_MAX_PRS          cap PRs per run (default 10)
#   REGISTRY_HEAL_PILEUP_N         pile-up threshold, PR count (default 3)
#   REGISTRY_HEAL_PILEUP_HOURS     pile-up age threshold in hours (default 6)
#   REGISTRY_HEAL_STATE_DIR        first-seen state dir (default /tmp/chump-registry-heal)
#   REGISTRY_HEAL_DRY_RUN=1        classify only, no rebase/push
#   REGISTRY_HEAL_PR_JSON          test hook: JSON file replacing `gh pr list`
set -uo pipefail

[[ "${CHUMP_REGISTRY_HEAL:-1}" == "0" ]] && { echo "[registry-heal] bypass"; exit 0; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "[registry-heal] not a git checkout" >&2; exit 1; }
cd "$REPO_ROOT"
COMMON_DIR="$(git rev-parse --git-common-dir)"
if [[ "$COMMON_DIR" == ".git" || "$COMMON_DIR" == "$REPO_ROOT/.git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$COMMON_DIR/.." && pwd)"; fi
AMBIENT="$MAIN_REPO/.chump-locks/ambient.jsonl"
DRIVER="$REPO_ROOT/scripts/git/merge-driver-union.sh"
MAX_PRS="${REGISTRY_HEAL_MAX_PRS:-10}"
PILEUP_N="${REGISTRY_HEAL_PILEUP_N:-3}"
PILEUP_HOURS="${REGISTRY_HEAL_PILEUP_HOURS:-6}"
STATE_DIR="${REGISTRY_HEAL_STATE_DIR:-/tmp/chump-registry-heal}"
WT_ROOT="${REGISTRY_HEAL_WT_ROOT:-/tmp/chump-registry-heal-wt}"
mkdir -p "$STATE_DIR" "$WT_ROOT"

REGISTRY_FILES=(
  scripts/ci/env-vars-internal.txt
  scripts/ci/event-registry-reserved.txt
  scripts/ops/organ-manifest.txt
  docs/observability/EVENT_REGISTRY.yaml
)

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() { # $1 kind, $2 json body without braces
  [[ -d "$(dirname "$AMBIENT")" ]] || return 0
  printf '{"ts":"%s","kind":"%s",%s}\n' "$(ts)" "$1" "$2" >> "$AMBIENT"
}
is_registry() { local f; for f in "${REGISTRY_FILES[@]}"; do [[ "$1" == "$f" ]] && return 0; done; return 1; }

# Validate EVENT_REGISTRY.yaml parses and has no duplicate `kind:` entries.
validate_registry_yaml() {
  python3 - "$1" <<'PY'
import sys, collections
try:
    import yaml
except ImportError:
    yaml = None
p = sys.argv[1]
txt = open(p).read()
if "<<<<<<<" in txt or ">>>>>>>" in txt:
    sys.exit("conflict markers present")
if yaml:
    d = yaml.safe_load(txt)
    items = d if isinstance(d, list) else next((v for v in (d or {}).values() if isinstance(v, list)), [])
    kinds = [i.get("kind") for i in items if isinstance(i, dict) and "kind" in i]
else:
    import re
    kinds = re.findall(r"^\s*-\s*kind:\s*(\S+)", txt, re.M)
dups = [k for k, c in collections.Counter(kinds).items() if c > 1]
if dups:
    sys.exit("duplicate kind keys: " + ",".join(dups[:5]))
PY
}

# Resolve current rebase-step conflicts via the union driver. Returns 1 if any
# unmerged file is outside the registry set or cannot be cleanly unioned.
resolve_step() {
  local f t
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_registry "$f" || return 1
    t="$(mktemp -d)"
    git show ":1:$f" > "$t/o" 2>/dev/null || : > "$t/o"
    git show ":2:$f" > "$t/a" 2>/dev/null || return 1
    git show ":3:$f" > "$t/b" 2>/dev/null || return 1
    bash "$DRIVER" "$t/o" "$t/a" "$t/b" 7 "$f" >/dev/null 2>&1 || { rm -rf "$t"; return 1; }
    grep -q -E '^(<<<<<<<|>>>>>>>)' "$t/a" && { rm -rf "$t"; return 1; }
    cp "$t/a" "$f"; rm -rf "$t"
    [[ "$f" == *EVENT_REGISTRY.yaml ]] && { validate_registry_yaml "$f" 2>/dev/null || return 1; }
    git add "$f"
  done < <(git diff --name-only --diff-filter=U)
  return 0
}

# Echo conflicted files for merging $1 (PR head) into origin/main; empty if clean.
conflict_set() {
  git merge-tree --write-tree --name-only --no-messages origin/main "$1" 2>/dev/null | sed '1d;/^$/,$d'
}

if [[ -n "${REGISTRY_HEAL_PR_JSON:-}" ]]; then
  PRS_JSON="$(cat "$REGISTRY_HEAL_PR_JSON")"
else
  command -v gh >/dev/null || { echo "[registry-heal] gh missing" >&2; exit 1; }
  PRS_JSON="$(gh pr list --state open --limit 100 --json number,headRefName,mergeable,mergeStateStatus 2>/dev/null || echo '[]')"
fi
git fetch origin main --quiet 2>/dev/null || true

TARGETS="$(printf '%s' "$PRS_JSON" | python3 -c '
import json,sys
try: prs=json.load(sys.stdin)
except Exception: prs=[]
for p in prs:
    if p.get("mergeable")=="CONFLICTING" or p.get("mergeStateStatus")=="DIRTY":
        print("%s|%s"%(p["number"],p["headRefName"]))
')"

HEALED=0; FLAGGED=0; FAILED=0; REGISTRY_DIRTY=0; PROCESSED=0
NOW="$(date +%s)"; OLDEST=0

while IFS='|' read -r PR BRANCH; do
  [[ -z "${PR:-}" ]] && continue
  (( PROCESSED >= MAX_PRS )) && break
  PROCESSED=$((PROCESSED + 1))
  git fetch origin "$BRANCH" --quiet 2>/dev/null || { FAILED=$((FAILED+1)); continue; }
  CSET="$(conflict_set "origin/$BRANCH")"
  if [[ -z "$CSET" ]]; then
    echo "[registry-heal] PR #$PR: no textual conflict vs main — skip"; continue
  fi
  OUTSIDE=0
  while IFS= read -r f; do [[ -n "$f" ]] && ! is_registry "$f" && OUTSIDE=1; done <<< "$CSET"
  if (( OUTSIDE )); then
    echo "[registry-heal] PR #$PR: conflicts outside registry set — flag for human"
    emit registry_heal_flagged "\"pr\":$PR,\"files\":\"$(printf '%s' "$CSET" | tr '\n' ',' | sed 's/,$//')\""
    FLAGGED=$((FLAGGED+1)); continue
  fi

  REGISTRY_DIRTY=$((REGISTRY_DIRTY+1))
  SEEN="$STATE_DIR/pr$PR.first_seen"
  [[ -f "$SEEN" ]] || echo "$NOW" > "$SEEN"
  AGE=$(( NOW - $(cat "$SEEN") )); (( AGE > OLDEST )) && OLDEST=$AGE

  if [[ "${REGISTRY_HEAL_DRY_RUN:-0}" == "1" ]]; then
    echo "[registry-heal] PR #$PR: registry-only conflict (dry-run)"; continue
  fi

  WT="$WT_ROOT/pr$PR-$$"
  if ! git worktree add -B "tmp-registry-heal-pr$PR" "$WT" "origin/$BRANCH" >/dev/null 2>&1; then
    FAILED=$((FAILED+1)); continue
  fi
  ok=0
  (
    cd "$WT" || exit 1
    git -c rebase.autoStash=false rebase origin/main >/dev/null 2>&1 && exit 0
    for _ in $(seq 1 50); do
      [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]] || exit 0
      resolve_step || { git rebase --abort >/dev/null 2>&1; exit 1; }
      GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 && exit 0
    done
    git rebase --abort >/dev/null 2>&1; exit 1
  ) && ok=1
  if (( ok )) && ( cd "$WT" && { [[ ! -f docs/observability/EVENT_REGISTRY.yaml ]] || validate_registry_yaml docs/observability/EVENT_REGISTRY.yaml 2>/dev/null; } ); then
    if ( cd "$WT" && git push --force-with-lease="$BRANCH:origin/$BRANCH" origin "HEAD:refs/heads/$BRANCH" >/dev/null 2>&1 ); then
      mergeable="UNKNOWN"
      for _ in 1 2 3 4 5; do
        sleep 4
        mergeable="$(gh pr view "$PR" --json mergeable -q .mergeable 2>/dev/null || echo UNKNOWN)"
        [[ "$mergeable" != "UNKNOWN" ]] && break
      done
      echo "[registry-heal] PR #$PR: healed, mergeable=$mergeable"
      emit registry_heal_healed "\"pr\":$PR,\"mergeable\":\"$mergeable\""
      rm -f "$SEEN"; HEALED=$((HEALED+1))
    else
      echo "[registry-heal] PR #$PR: push failed"; FAILED=$((FAILED+1))
    fi
  else
    echo "[registry-heal] PR #$PR: union rebase failed validation — flag"
    emit registry_heal_flagged "\"pr\":$PR,\"files\":\"union-rebase-failed\""
    FLAGGED=$((FLAGGED+1))
  fi
  git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
  git branch -D "tmp-registry-heal-pr$PR" >/dev/null 2>&1 || true
done <<< "$TARGETS"

# Pile-up watcher: too many registry-DIRTY PRs for too long.
if (( REGISTRY_DIRTY >= PILEUP_N && OLDEST >= PILEUP_HOURS * 3600 )); then
  emit registry_dirty_pileup "\"count\":$REGISTRY_DIRTY,\"oldest_hours\":$((OLDEST/3600)),\"threshold_n\":$PILEUP_N"
  echo "[registry-heal] PILEUP: $REGISTRY_DIRTY registry-DIRTY PRs, oldest $((OLDEST/3600))h"
fi

echo "[registry-heal] done: processed=$PROCESSED healed=$HEALED flagged=$FLAGGED failed=$FAILED registry_dirty=$REGISTRY_DIRTY"
exit 0
