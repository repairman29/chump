#!/usr/bin/env bash
# provider-matrix.sh — EVAL-089
#
# Run a single chump dispatch (`chump --execute-gap <GAP-ID>`) across every
# OpenAI-compatible provider configured in .env. Captures one JSON status row
# per provider so we can grade model/provider behaviour on the same task.
#
# Each provider declares three env vars:
#   <PFX>_API_BASE   — OpenAI-compatible base URL (e.g. .../v1)
#   <PFX>_API_KEY    — auth token (empty / unset = skip)
#   <PFX>_MODEL      — model id to send
#
# Currently-known prefixes (must also be on the PROVIDERS list below):
#   GROQ CEREBRAS OPENROUTER GITHUBMODELS GEMINI HYPERBOLIC NVIDIA
#   TOGETHER DEEPSEEK
#
# Each run gets its own linked worktree under
# .claude/worktrees/eval-089-bake-<provider>-<gap>/, claims the gap there,
# runs the dispatch, then releases the lease + removes the worktree on exit.
#
# Status logs land at .chump/bakeoff/<gap>/<provider>.json. Aggregate them
# with provider-matrix-summary.sh.
#
# Usage:
#   scripts/eval/provider-matrix.sh <GAP-ID> [PROVIDER1 PROVIDER2 ...]
#
#   No provider list = run every provider whose KEY is non-empty.
#   With a provider list = only those providers (case-insensitive prefix names).
#
# Honest scope: this is a one-shot grading rig, not a long-running service. It
# does NOT recover from rate-limit 429s by retrying — it records the 429 and
# moves on so the operator sees provider-saturation as data, not as a hidden
# success.

set -uo pipefail

PROVIDERS=(GROQ CEREBRAS OPENROUTER GITHUBMODELS GEMINI HYPERBOLIC NVIDIA TOGETHER DEEPSEEK)

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <GAP-ID> [PROVIDER1 PROVIDER2 ...]

Known providers: ${PROVIDERS[*]}

Examples:
  $(basename "$0") INFRA-080                         # all configured
  $(basename "$0") INFRA-080 GROQ NVIDIA             # subset
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
GAP_ID="$1"
shift
[[ "$GAP_ID" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || {
  echo "[provider-matrix] bad gap id: $GAP_ID" >&2
  usage
}

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "[provider-matrix] must run inside a git checkout" >&2
  exit 1
}
cd "$REPO_ROOT"

# Source .env for provider keys. Tolerate missing file — caller may export
# the vars another way.
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

# Resolve which providers to run.
if [[ $# -gt 0 ]]; then
  REQUESTED=()
  for p in "$@"; do
    REQUESTED+=("$(echo "$p" | tr '[:lower:]' '[:upper:]')")
  done
else
  REQUESTED=("${PROVIDERS[@]}")
fi

# Resolve chump release binary (must exist; we don't build for the operator).
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/release/chump}"
if [[ ! -x "$CHUMP_BIN" ]]; then
  echo "[provider-matrix] $CHUMP_BIN not found — build with 'cargo build --release --bin chump' first" >&2
  exit 1
fi

OUT_DIR="$REPO_ROOT/.chump/bakeoff/$GAP_ID"
mkdir -p "$OUT_DIR"

run_one() {
  local pfx="$1"
  local lower
  lower="$(echo "$pfx" | tr '[:upper:]' '[:lower:]')"

  local base_var="${pfx}_API_BASE"
  local key_var="${pfx}_API_KEY"
  local model_var="${pfx}_MODEL"
  local base="${!base_var:-}"
  local key="${!key_var:-}"
  local model="${!model_var:-}"

  local status_file="$OUT_DIR/${lower}.json"

  # Skip if anything is missing (KEY usually the operator-owned blank).
  if [[ -z "$base" || -z "$key" || -z "$model" ]]; then
    printf '[provider-matrix] %-12s SKIP — empty config (set %s_{API_BASE,API_KEY,MODEL} in .env)\n' \
      "$pfx" "$pfx" >&2
    write_status "$status_file" "$pfx" "$model" "skip" "missing config" 0
    return 0
  fi

  local wt_path="$REPO_ROOT/.claude/worktrees/eval-089-bake-${lower}-${GAP_ID,,}"
  local wt_branch="claude/eval-089-bake-${lower}-${GAP_ID,,}"
  local stdout_log="$OUT_DIR/${lower}.stdout.log"
  local stderr_log="$OUT_DIR/${lower}.stderr.log"

  # Idempotent setup: if a leftover worktree from a prior run exists, nuke it.
  if [[ -d "$wt_path" ]]; then
    rm -rf "$wt_path/.chump-locks"/*.json 2>/dev/null || true
    git worktree remove "$wt_path" --force 2>/dev/null || true
  fi
  git branch -D "$wt_branch" 2>/dev/null || true

  printf '[provider-matrix] %-12s START — base=%s model=%s\n' "$pfx" "$base" "$model" >&2

  if ! git worktree add -b "$wt_branch" "$wt_path" origin/main >/dev/null 2>&1; then
    write_status "$status_file" "$pfx" "$model" "error" "worktree add failed" 0
    return 1
  fi

  # Claim the gap inside the worktree. The harness owns the worktree lifecycle.
  if ! ( cd "$wt_path" && CHUMP_AMBIENT_GLANCE=0 scripts/coord/gap-claim.sh "$GAP_ID" ) >/dev/null 2>&1; then
    write_status "$status_file" "$pfx" "$model" "error" "gap-claim failed" 0
    cleanup_worktree "$wt_path" "$wt_branch"
    return 1
  fi

  # Run the dispatch with OPENAI_* mapped from this provider's triple.
  local started ended elapsed exit_code
  started=$(date +%s)
  set +e
  (
    cd "$wt_path"
    export OPENAI_API_BASE="$base"
    export OPENAI_API_KEY="$key"
    export OPENAI_MODEL="$model"
    export CHUMP_DISPATCH_DEPTH=1
    export GIT_AUTHOR_NAME="Chump Dispatched ($pfx)"
    export GIT_AUTHOR_EMAIL="chump-dispatch@chump.bot"
    export GIT_COMMITTER_NAME="Chump Dispatched ($pfx)"
    export GIT_COMMITTER_EMAIL="chump-dispatch@chump.bot"
    "$CHUMP_BIN" --execute-gap "$GAP_ID"
  ) >"$stdout_log" 2>"$stderr_log"
  exit_code=$?
  set -e
  ended=$(date +%s)
  elapsed=$((ended - started))

  # Classify the run from logs. Order matters — first match wins.
  local outcome detail pr_number=""
  if grep -qE "Too Many Requests|429|rate.?limit|queue_exceeded" "$stderr_log" 2>/dev/null; then
    outcome="rate_limited"
    detail="provider returned 429 (not a model verdict)"
  elif grep -qE "consecutive tool batches" "$stdout_log" "$stderr_log" 2>/dev/null; then
    outcome="tool_storm"
    detail="circuit-breaker tripped on bad tool inputs"
  elif pr_number=$(grep -oE "#[0-9]{2,5}" "$stdout_log" 2>/dev/null | head -1); then
    outcome="ship"
    detail="PR $pr_number"
  elif [[ $exit_code -eq 0 ]]; then
    outcome="exit0_no_pr"
    detail="agent exited cleanly without a PR"
  else
    outcome="error"
    detail="exit=$exit_code; see $stderr_log"
  fi

  write_status "$status_file" "$pfx" "$model" "$outcome" "$detail" "$elapsed"
  printf '[provider-matrix] %-12s DONE  — %s (%ss) %s\n' "$pfx" "$outcome" "$elapsed" "$detail" >&2

  cleanup_worktree "$wt_path" "$wt_branch"
}

cleanup_worktree() {
  local wt_path="$1" wt_branch="$2"
  rm -rf "$wt_path/.chump-locks"/*.json 2>/dev/null || true
  git worktree remove "$wt_path" --force 2>/dev/null || true
  git branch -D "$wt_branch" 2>/dev/null || true
}

write_status() {
  local file="$1" provider="$2" model="$3" outcome="$4" detail="$5" elapsed="$6"
  cat >"$file" <<EOF
{
  "provider": "$provider",
  "model": "$model",
  "outcome": "$outcome",
  "detail": $(printf '%s' "$detail" | jq -Rs .),
  "elapsed_seconds": $elapsed,
  "gap_id": "$GAP_ID",
  "ran_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# Drive the matrix. Serial — providers should not race for the same gap claim
# even though we worktree-isolate them; gap-preflight.sh would fail the second
# claim because the lease is per-gap, not per-worktree.
trap 'echo "[provider-matrix] interrupted — leaving partial logs in $OUT_DIR" >&2' INT TERM

for pfx in "${REQUESTED[@]}"; do
  case " ${PROVIDERS[*]} " in
    *" $pfx "*) run_one "$pfx" || true ;;
    *)
      echo "[provider-matrix] WARN unknown provider '$pfx' — skipping (known: ${PROVIDERS[*]})" >&2
      ;;
  esac
done

echo "[provider-matrix] done — status files in $OUT_DIR" >&2
echo "[provider-matrix] aggregate: scripts/eval/provider-matrix-summary.sh $GAP_ID" >&2
