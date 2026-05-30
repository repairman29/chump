#!/usr/bin/env bash
# test-bot-merge-mode-routing.sh — INFRA-2133: META-124/C5 Mode A/B/C routing
#
# Tests (8 cases per AC):
#   1. REVIEW: title prefix → Mode B (existing flow, no early-exit)
#   2. external-collab in skills_required → Mode B
#   3. --review flag → Mode B
#   4. --hot-fix flag → Mode C (existing flow, no early-exit)
#   5. P0 + TRUNK-RED title keyword → Mode C
#   6. Normal gap (no routing signals) → Mode A (routes to batched, exits 0)
#   7. NATS down (work-board post fails) → falls back to Mode B
#   8. Mode A correctly marks gap status=ready_to_ship via chump gap set

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILURES=$(( FAILURES + 1 )); }
FAILURES=0

[[ -f "$BOT_MERGE" ]] || { printf '[FAIL] bot-merge.sh not found at %s\n' "$BOT_MERGE" >&2; exit 1; }

TMP="$(mktemp -d -t test-bm-mode-routing.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

AMBIENT="$TMP/ambient.jsonl"
touch "$AMBIENT"

# ─── Shared mock factory ──────────────────────────────────────────────────────
# make_mocks <dir> <gap_title> <gap_priority> <gap_domain> <gap_skills>
#            <chump_coord_exit> <chump_gap_set_log>
# Writes fake: git, gh, chump, chump-coord, cargo into <dir>/bin
make_mocks() {
    local bin_dir="$1"
    local gap_title="$2"
    local gap_priority="${3:-P1}"
    local gap_domain="${4:-INFRA}"
    local gap_skills="${5:-}"
    local coord_exit="${6:-0}"     # chump-coord work-board post exit code
    local gap_set_log="${7:-$TMP/gap_set.log}"

    mkdir -p "$bin_dir"
    local _wt="$bin_dir/worktree"

    # git stub — embed real path (double-quoted heredoc so $_wt expands now)
    cat > "$bin_dir/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  "symbolic-ref --short HEAD")    echo "chump/infra-9999-claim" ;;
  "rev-parse --abbrev-ref HEAD")  echo "chump/infra-9999-claim" ;;
  "rev-parse --show-toplevel")    echo "${_wt}" ;;
  "rev-parse --git-dir")          echo "${_wt}/.git" ;;
  "rev-parse --absolute-git-dir") echo "${_wt}/.git" ;;
  "-C ${_wt} rev-parse --absolute-git-dir") echo "${_wt}/.git" ;;
  *) exit 0 ;;
esac
GITEOF
    chmod +x "$bin_dir/git"

    # gh stub — returns a minimal open PR so Mode B/C flow doesn't abort
    cat > "$bin_dir/gh" <<GHEOF
#!/usr/bin/env bash
cmd="\${1:-}"; shift || true
case "\$cmd" in
  auth)   exit 0 ;;
  pr)
    sub="\${1:-}"; shift || true
    case "\$sub" in
      view)   printf '{"number":42,"state":"OPEN","autoMergeRequest":null}\n' ;;
      create) printf 'https://github.com/test/repo/pull/42\n' ;;
      merge)  exit 0 ;;
      checks) exit 0 ;;
      list)   printf '[]' ;;
      diff)   exit 0 ;;
      edit)   exit 0 ;;
      comment) exit 0 ;;
      *)      exit 0 ;;
    esac ;;
  repo)   printf '{"defaultBranchRef":{"name":"main"}}\n' ;;
  label)  exit 0 ;;
  api)    printf '{"items":[]}\n' ;;
  *)      exit 0 ;;
esac
GHEOF
    chmod +x "$bin_dir/gh"

    # chump stub — returns gap metadata for routing detection
    local skills_line=""
    [[ -n "$gap_skills" ]] && skills_line="  skills_required: $gap_skills"
    cat > "$bin_dir/chump" <<CHUMPEOF
#!/usr/bin/env bash
cmd="\${1:-}"; shift || true
case "\$cmd" in
  gap)
    sub="\${1:-}"; shift || true
    case "\$sub" in
      show)
        printf '- id: INFRA-9999\n'
        printf '  domain: %s\n' "$gap_domain"
        printf '  title: "%s"\n' "$gap_title"
        printf '  priority: %s\n' "$gap_priority"
        printf '  status: open\n'
        [[ -n "$skills_line" ]] && printf '%s\n' "$skills_line"
        ;;
      set)
        printf 'chump gap set %s\n' "\$*" >> "$gap_set_log"
        ;;
      preflight) exit 0 ;;
      *)  exit 0 ;;
    esac ;;
  ambient) exit 0 ;;
  ship)    exit 0 ;;
  *)       exit 0 ;;
esac
CHUMPEOF
    chmod +x "$bin_dir/chump"

    # chump-coord stub — work-board post exits $coord_exit
    cat > "$bin_dir/chump-coord" <<COORDEOF
#!/usr/bin/env bash
cmd="\${1:-}"; shift || true
case "\$cmd" in
  work-board)
    sub="\${1:-}"; shift || true
    case "\$sub" in
      post) exit $coord_exit ;;
      *)    exit 0 ;;
    esac ;;
  *)  exit 0 ;;
esac
COORDEOF
    chmod +x "$bin_dir/chump-coord"

    # cargo stub — do nothing (fast)
    cat > "$bin_dir/cargo" <<'CARGOEOF'
#!/usr/bin/env bash
exit 0
CARGOEOF
    chmod +x "$bin_dir/cargo"

    # flock stub
    cat > "$bin_dir/flock" <<'FLOCKEOF'
#!/usr/bin/env bash
shift; shift; "$@"
FLOCKEOF
    chmod +x "$bin_dir/flock"
}

# Minimal worktree skeleton so bot-merge path guards don't abort.
# Takes an optional path arg; defaults to $TMP/worktree.
make_worktree() {
    local wt="${1:-$TMP/worktree}"
    rm -rf "$wt"
    mkdir -p "$wt/.git/hooks" "$wt/.chump-locks" "$wt/bin"
    echo "ref: refs/heads/chump/infra-9999-claim" > "$wt/.git/HEAD"
    touch "$wt/.git/hooks/pre-commit"
    chmod +x "$wt/.git/hooks/pre-commit"
    echo "$wt"   # return path
}

# ─── Shared env for all test runs ─────────────────────────────────────────────
BASE_ENV=(
    env
    CHUMP_AGENT_HARNESS=test
    CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=1
    CHUMP_IGNORE_WASTE_PAUSE=1
    CHUMP_AUTO_INSTALL_HOOKS=0
    CHUMP_INSTALL_HOOKS=0
    CHUMP_BOT_MERGE_SHADOW_PLAN=0
    CHUMP_BOT_MERGE_ALLOW_UNTRACKED=0
    CHUMP_BOT_MERGE_AUTO_COMMIT_M=0
    CHUMP_SHIP_RUST=0
    CHUMP_BOT_MERGE_NO_TEE=1
    CHUMP_GH_PROBE_SKIP=1
    CHUMP_RL_GATE_SKIP=1
    "CHUMP_AMBIENT_LOG=$AMBIENT"
    BASE_BRANCH=main
    REMOTE=origin
    BM_LEGACY_MODE=0
    BM_FORCE_REVIEW=0
    BM_FORCE_HOTFIX=0
    CHUMP_FORCE_REVIEW=
)

# Helper: extract routing mode from bot-merge stdout
extract_mode() {
    grep -oE 'routing mode=[ABC]' "$1" 2>/dev/null | grep -oE '[ABC]$' || true
}

# ─── Test helpers ─────────────────────────────────────────────────────────────
# run_routing_test: runs bot-merge and captures output; returns exit code
# Usage: run_routing_test <out_file> <bin_dir> [extra env] -- [bot-merge args]
run_routing_test() {
    local out_file="$1" bin_dir="$2"; shift 2
    local extra_env=()
    while [[ "${1:-}" != "--" && $# -gt 0 ]]; do
        extra_env+=("$1"); shift
    done
    [[ "${1:-}" == "--" ]] && shift
    local bm_args=("$@")

    # Each test gets its own worktree dir so REPO_ROOT is always a real path.
    local _wt
    _wt="$(make_worktree "$bin_dir/worktree")"

    local _rc=0
    PATH="$bin_dir:$PATH" \
        REPO_ROOT="$_wt" \
        "${BASE_ENV[@]}" \
        ${extra_env[@]+"${extra_env[@]}"} \
        bash "$BOT_MERGE" --gap INFRA-9999 "${bm_args[@]}" \
        > "$out_file" 2>&1 || _rc=$?
    return $_rc
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: REVIEW: title prefix → Mode B (does NOT exit 0 before PR create)
# ══════════════════════════════════════════════════════════════════════════════
T=1; OUT="$TMP/t${T}.out"; BIN="$TMP/bin${T}"
make_mocks "$BIN" "REVIEW: external partner integration" "P1" "INFRA" ""
set +e; run_routing_test "$OUT" "$BIN" -- --auto-merge; RC=$?; set -e
MODE="$(extract_mode "$OUT")"
if [[ "$MODE" == "B" ]]; then
    pass "T${T}: REVIEW: title → Mode B (mode=${MODE})"
else
    fail "T${T}: REVIEW: title should give Mode B, got mode=${MODE} (rc=${RC})"
    cat "$OUT" >&2 || true
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: skills_required contains external-collab → Mode B
# ══════════════════════════════════════════════════════════════════════════════
T=2; OUT="$TMP/t${T}.out"; BIN="$TMP/bin${T}"
make_mocks "$BIN" "EFFECTIVE: partner API surface" "P1" "INFRA" "external-collab"
set +e; run_routing_test "$OUT" "$BIN" -- --auto-merge; RC=$?; set -e
MODE="$(extract_mode "$OUT")"
if [[ "$MODE" == "B" ]]; then
    pass "T${T}: external-collab skill → Mode B (mode=${MODE})"
else
    fail "T${T}: external-collab skill should give Mode B, got mode=${MODE} (rc=${RC})"
    cat "$OUT" >&2 || true
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: --review flag → Mode B
# ══════════════════════════════════════════════════════════════════════════════
T=3; OUT="$TMP/t${T}.out"; BIN="$TMP/bin${T}"
make_mocks "$BIN" "EFFECTIVE: normal work item" "P1" "INFRA" ""
set +e; run_routing_test "$OUT" "$BIN" -- --review --auto-merge; RC=$?; set -e
MODE="$(extract_mode "$OUT")"
if [[ "$MODE" == "B" ]]; then
    pass "T${T}: --review flag → Mode B (mode=${MODE})"
else
    fail "T${T}: --review flag should give Mode B, got mode=${MODE} (rc=${RC})"
    cat "$OUT" >&2 || true
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: --hot-fix flag → Mode C
# ══════════════════════════════════════════════════════════════════════════════
T=4; OUT="$TMP/t${T}.out"; BIN="$TMP/bin${T}"
make_mocks "$BIN" "RESILIENT: some work item" "P1" "INFRA" ""
set +e; run_routing_test "$OUT" "$BIN" -- --hot-fix --auto-merge; RC=$?; set -e
MODE="$(extract_mode "$OUT")"
if [[ "$MODE" == "C" ]]; then
    pass "T${T}: --hot-fix flag → Mode C (mode=${MODE})"
else
    fail "T${T}: --hot-fix flag should give Mode C, got mode=${MODE} (rc=${RC})"
    cat "$OUT" >&2 || true
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 5: P0 + TRUNK-RED keyword in title → Mode C
# ══════════════════════════════════════════════════════════════════════════════
T=5; OUT="$TMP/t${T}.out"; BIN="$TMP/bin${T}"
make_mocks "$BIN" "RESILIENT P0 trunk-RED: fix CI blocker now" "P0" "INFRA" ""
set +e; run_routing_test "$OUT" "$BIN" -- --auto-merge; RC=$?; set -e
MODE="$(extract_mode "$OUT")"
if [[ "$MODE" == "C" ]]; then
    pass "T${T}: P0+TRUNK-RED title → Mode C (mode=${MODE})"
else
    fail "T${T}: P0+TRUNK-RED title should give Mode C, got mode=${MODE} (rc=${RC})"
    cat "$OUT" >&2 || true
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 6: Normal gap (no routing signals) + NATS up → Mode A, exits 0
# ══════════════════════════════════════════════════════════════════════════════
T=6; OUT="$TMP/t${T}.out"; BIN="$TMP/bin${T}"
make_mocks "$BIN" "EFFECTIVE: add feature X" "P1" "INFRA" "" "0"
set +e; run_routing_test "$OUT" "$BIN" -- --auto-merge; RC=$?; set -e
MODE="$(extract_mode "$OUT")"
if [[ "$MODE" == "A" && "$RC" == "0" ]]; then
    pass "T${T}: normal gap → Mode A, exits 0 (mode=${MODE} rc=${RC})"
else
    fail "T${T}: normal gap should give Mode A exit 0, got mode=${MODE} rc=${RC}"
    cat "$OUT" >&2 || true
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 7: NATS down (work-board post returns 1) → fallback to Mode B
# ══════════════════════════════════════════════════════════════════════════════
T=7; OUT="$TMP/t${T}.out"; BIN="$TMP/bin${T}"
# coord_exit=1 simulates NATS unavailable
make_mocks "$BIN" "EFFECTIVE: add feature Y" "P1" "INFRA" "" "1"
set +e; run_routing_test "$OUT" "$BIN" -- --auto-merge; RC=$?; set -e
MODE="$(extract_mode "$OUT")"
# After fallback it should attempt Mode B (not exit 0 with "routed to batched")
ROUTED_MSG="$(grep -c 'routed to batched' "$OUT" 2>/dev/null || true)"
if [[ "$MODE" == "A" && "$ROUTED_MSG" == "0" ]]; then
    pass "T${T}: NATS down → Mode A detected but fallback to B (mode=${MODE}, no 'routed' exit)"
else
    fail "T${T}: NATS down fallback unexpected: mode=${MODE} routed_msg=${ROUTED_MSG} rc=${RC}"
    cat "$OUT" >&2 || true
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 8: Mode A correctly calls chump gap set --status ready_to_ship
# ══════════════════════════════════════════════════════════════════════════════
T=8; OUT="$TMP/t${T}.out"; BIN="$TMP/bin${T}"
GAP_SET_LOG="$TMP/t${T}_gap_set.log"; touch "$GAP_SET_LOG"
make_mocks "$BIN" "EFFECTIVE: add feature Z" "P1" "INFRA" "" "0" "$GAP_SET_LOG"
set +e; run_routing_test "$OUT" "$BIN" -- --auto-merge; RC=$?; set -e
MODE="$(extract_mode "$OUT")"
STATUS_CALL="$(grep -c 'ready_to_ship' "$GAP_SET_LOG" 2>/dev/null || true)"
if [[ "$MODE" == "A" && "$STATUS_CALL" -ge 1 && "$RC" == "0" ]]; then
    pass "T${T}: Mode A calls chump gap set --status ready_to_ship (calls=${STATUS_CALL})"
else
    fail "T${T}: Mode A should set ready_to_ship: mode=${MODE} status_calls=${STATUS_CALL} rc=${RC}"
    cat "$OUT" >&2 || true
    cat "$GAP_SET_LOG" >&2 || true
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
printf '\n'
if [[ "$FAILURES" -eq 0 ]]; then
    printf '[PASS] All 8 mode-routing tests passed.\n'
    exit 0
else
    printf '[FAIL] %d test(s) failed.\n' "$FAILURES" >&2
    exit 1
fi
