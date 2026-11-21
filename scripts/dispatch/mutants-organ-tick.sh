#!/usr/bin/env bash
# mutants-organ-tick.sh — RESILIENT-2219: the mutant-capable reviewer the review
# organ (scripts/dispatch/review-organ-tick.sh) holds gate-file PRs for.
#
# ONE bounded tick. For each open PR labeled `review-needs-mutants`:
#   1. compute the PR-diff patch-id (`gh pr diff | git patch-id --stable`);
#   2. skip it if a record for THAT patch-id by this login is already posted;
#   3. check the head out in a throwaway worktree and run
#      `cargo mutants --file <.rs files the head touches>` under a wall-clock
#      budget (PRs whose gate files are not Rust get no record: nothing to mutate);
#   4. post a record comment in the exact shape review-organ-tick.sh's
#      mutant_record_satisfies parses: `head:`, `patch-id:`, one
#      `- <mutant>: KILLED|SURVIVED` line per mutant, NO `VERDICT:` line.
# The review organ then clears the hold on its next tick and runs its own model
# review; this organ never approves, arms, or labels.
#
# The record author is whoever `gh` is authenticated as; it counts only when that
# equals the review organ's login (one account per node). No env var changes a
# safety input: the budget is a CLI arg, the record shape is fixed here.
#
# Usage: mutants-organ-tick.sh [--pr N]... [--repo OWNER/REPO] [--budget-secs N]
#        [--cargo-mutants-bin PATH] [--checkout DIR] [--dry-run]
#
# Rust-First-Bypass: thin gh + git + cargo-mutants glue, no canonical-state mutation.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
CHECKOUT="$HOME/chump"
REPO=""
BUDGET_SECS=1500
MUTANTS_BIN="cargo-mutants"
DRY_RUN=0
declare -a ONLY_PRS=()
LABEL="review-needs-mutants"

while (( $# )); do
    case "$1" in
        --pr)                ONLY_PRS+=("${2:-}"); shift 2 ;;
        --repo)              REPO="${2:-}"; shift 2 ;;
        --budget-secs)       BUDGET_SECS="${2:-}"; shift 2 ;;
        --cargo-mutants-bin) MUTANTS_BIN="${2:-}"; shift 2 ;;
        --checkout)          CHECKOUT="${2:-}"; shift 2 ;;
        --dry-run)           DRY_RUN=1; shift ;;
        -h|--help)           sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "[mutants-organ] unknown argument '$1'" >&2; exit 2 ;;
    esac
done

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[mutants-organ %s] %s\n' "$(ts)" "$*"; }
emit() { printf '%s\n' "$1" >> "$AMBIENT" 2>/dev/null || true; }
GH() { if declare -F chump_gh >/dev/null 2>&1; then chump_gh "$@"; else gh "$@"; fi; }

# scanner-anchor: "kind":"mutants_organ_tick"
# scanner-anchor: "kind":"mutants_record_posted"
# scanner-anchor: "kind":"mutants_organ_skipped"

# shellcheck source=scripts/coord/lib/ship-gate-files.sh
source "$REPO_ROOT/scripts/coord/lib/ship-gate-files.sh"

# The heartbeat fleet-doctor reads. Emitted even when nothing was labeled so a
# live organ is distinguishable from a dead one.
POSTED=0; SKIPPED=0; SEEN=0
finish() {
    emit "$(printf '{"ts":"%s","kind":"mutants_organ_tick","seen":%s,"posted":%s,"skipped":%s}' "$(ts)" "$SEEN" "$POSTED" "$SKIPPED")"
    log "tick done (seen=$SEEN posted=$POSTED skipped=$SKIPPED)"
}

# format_record <head> <patch-id> <caught.txt> <missed.txt> — the exact record shape.
format_record() {
    local head="$1" pid="$2" caught="$3" missed="$4" line
    printf 'mutants record (cargo-mutants)\n\nhead: %s\npatch-id: %s\n\n' "$head" "$pid"
    [[ -f "$caught" ]] && while IFS= read -r line; do [[ -n "$line" ]] && printf -- '- %s: KILLED\n' "$line"; done < "$caught"
    [[ -f "$missed" ]] && while IFS= read -r line; do [[ -n "$line" ]] && printf -- '- %s: SURVIVED\n' "$line"; done < "$missed"
    return 0
}

# Sourced by the test to reuse format_record without running a tick.
[[ "${MUTANTS_ORGAN_SOURCE_ONLY:-0}" == "1" ]] && return 0 2>/dev/null

if ! command -v "$MUTANTS_BIN" >/dev/null 2>&1 && [[ ! -x "$MUTANTS_BIN" ]]; then
    emit "$(printf '{"ts":"%s","kind":"mutants_organ_skipped","reason":"cargo-mutants-missing"}' "$(ts)")"
    log "cargo-mutants not installed ($MUTANTS_BIN) — run scripts/setup/chump-fleet-bootstrap.sh"
    exit 0
fi

SELF_LOGIN="$(CHUMP_GH_CALL_CRITICALITY=background GH api user --jq '.login' 2>/dev/null || true)"

patch_id_of() {
    GH pr diff "$1" ${REPO:+--repo "$REPO"} 2>/dev/null | git patch-id --stable 2>/dev/null | awk 'NR==1{print $1}'
}

# record_exists <pr> <patch-id> — a record by this login already covers the diff.
record_exists() {
    local payload
    payload="$(CHUMP_GH_CALL_CRITICALITY=background GH pr view "$1" ${REPO:+--repo "$REPO"} --json comments 2>/dev/null || true)"
    [[ -n "$payload" && -n "$SELF_LOGIN" ]] || return 1
    PID="$2" LOGIN="$SELF_LOGIN" python3 -c '
import json, os, re, sys
d = json.loads(sys.argv[1])
pid, login = os.environ["PID"].lower(), os.environ["LOGIN"].lower()
for c in d.get("comments") or []:
    if ((c.get("author") or {}).get("login") or "").lower() != login:
        continue
    b = c.get("body") or ""
    m = re.search(r"^[ \t]*patch-id:[ \t]*([0-9a-fA-F]{12,40})", b, re.M)
    if m and pid.startswith(m.group(1).lower()) and re.search(r"\b(KILLED|SURVIVED)\b", b):
        sys.exit(0)
sys.exit(1)
' "$payload" 2>/dev/null
}

process_pr() {
    local pr="$1" head pid files rs wt out f g
    head="$(GH pr view "$pr" ${REPO:+--repo "$REPO"} --json headRefOid --jq '.headRefOid' 2>/dev/null || true)"
    if [[ ! "$head" =~ ^[0-9a-fA-F]{40}$ ]]; then log "PR #$pr: no head — skip"; SKIPPED=$((SKIPPED+1)); return 0; fi
    pid="$(patch_id_of "$pr")"
    if [[ -z "$pid" ]]; then log "PR #$pr: patch-id uncomputable — skip"; SKIPPED=$((SKIPPED+1)); return 0; fi
    if record_exists "$pr" "$pid"; then log "PR #$pr: record for patch-id ${pid:0:12} already posted"; SKIPPED=$((SKIPPED+1)); return 0; fi

    files="$(GH pr diff "$pr" ${REPO:+--repo "$REPO"} --name-only 2>/dev/null || true)"
    rs=""
    while IFS= read -r f; do
        [[ "$f" == *.rs ]] || continue
        for g in "${CHUMP_SHIP_GATE_GLOBS[@]}"; do
            # shellcheck disable=SC2053  # glob match is intended
            [[ "$f" == $g ]] && { rs+="$f"$'\n'; break; }
        done
    done <<< "$files"
    if [[ -z "$rs" ]]; then
        log "PR #$pr: touches no Rust ship-gate file — nothing for cargo-mutants to mutate"
        emit "$(printf '{"ts":"%s","kind":"mutants_organ_skipped","pr":%s,"reason":"no-rust-files"}' "$(ts)" "$pr")"
        SKIPPED=$((SKIPPED+1)); return 0
    fi
    if (( DRY_RUN )); then log "PR #$pr: dry-run — would mutate: $(printf '%s' "$rs" | tr '\n' ' ')"; SKIPPED=$((SKIPPED+1)); return 0; fi

    wt="$(mktemp -d)"
    if ! git -C "$CHECKOUT" fetch origin "pull/$pr/head" --quiet 2>/dev/null \
       || ! git -C "$CHECKOUT" worktree add --detach "$wt/src" "$head" --quiet 2>/dev/null; then
        log "PR #$pr: cannot check out head ${head:0:12} — skip"; rm -rf "$wt"; SKIPPED=$((SKIPPED+1)); return 0
    fi
    local -a fargs=()
    while IFS= read -r f; do [[ -n "$f" && -f "$wt/src/$f" ]] && fargs+=(--file "$f"); done <<< "$rs"
    if (( ${#fargs[@]} == 0 )); then
        log "PR #$pr: no changed Rust file exists at head — skip"
        git -C "$CHECKOUT" worktree remove --force "$wt/src" 2>/dev/null; rm -rf "$wt"; SKIPPED=$((SKIPPED+1)); return 0
    fi

    out="$wt/out"
    log "PR #$pr: cargo mutants ${fargs[*]} (budget ${BUDGET_SECS}s)"
    ( cd "$wt/src" && timeout "$BUDGET_SECS" "$MUTANTS_BIN" mutants --no-shuffle --output "$out" "${fargs[@]}" >"$wt/mutants.log" 2>&1 ) || true

    local dir body
    dir="$(find "$out" -maxdepth 2 \( -name caught.txt -o -name missed.txt \) -printf '%h\n' 2>/dev/null | head -1)"
    body="$(format_record "$head" "$pid" "${dir:-$out}/caught.txt" "${dir:-$out}/missed.txt")"
    if ! grep -qE ': (KILLED|SURVIVED)$' <<< "$body"; then
        log "PR #$pr: cargo-mutants produced no mutant outcomes (see $wt/mutants.log) — no record posted"
        emit "$(printf '{"ts":"%s","kind":"mutants_organ_skipped","pr":%s,"reason":"no-outcomes"}' "$(ts)" "$pr")"
        git -C "$CHECKOUT" worktree remove --force "$wt/src" 2>/dev/null; SKIPPED=$((SKIPPED+1)); return 0
    fi
    if GH pr comment "$pr" ${REPO:+--repo "$REPO"} --body "$body" >/dev/null 2>&1; then
        POSTED=$((POSTED+1))
        emit "$(printf '{"ts":"%s","kind":"mutants_record_posted","pr":%s,"patch_id":"%s"}' "$(ts)" "$pr" "$pid")"
        log "PR #$pr: posted mutants record for patch-id ${pid:0:12}"
    else
        log "PR #$pr: failed to post record"; SKIPPED=$((SKIPPED+1))
    fi
    git -C "$CHECKOUT" worktree remove --force "$wt/src" 2>/dev/null; rm -rf "$wt"
}

if (( ${#ONLY_PRS[@]} )); then
    PRS=("${ONLY_PRS[@]}")
else
    mapfile -t PRS < <(GH pr list ${REPO:+--repo "$REPO"} --state open --label "$LABEL" --limit 30 --json number --jq '.[].number' 2>/dev/null || true)
fi
for pr in "${PRS[@]}"; do
    [[ -n "$pr" ]] || continue
    SEEN=$((SEEN+1))
    process_pr "$pr"
done
finish
exit 0
