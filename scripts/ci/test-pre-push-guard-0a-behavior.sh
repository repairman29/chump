#!/usr/bin/env bash
# RESILIENT-1625: behavioral test for pre-push Guard 0a against stub chump
# binaries. 8 cases = {new,stale --help} x {bot-merge on,off} x {pass,fail}.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

awk '/^# Guard 0a:/{f=1} /^# Guard 0: cargo fmt/{f=0} f' "$HOOK" >"$WORK/guard.sh"
[[ -s "$WORK/guard.sh" ]] || { echo "FAIL: could not extract Guard 0a"; exit 1; }

mkdir -p "$WORK/bin" "$WORK/repo"
cat >"$WORK/bin/chump" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "preflight" ]]; then
    shift
    if [[ "${1:-}" == "--help" ]]; then
        echo "chump preflight [--full]"
        [[ "${STUB_HELP:-new}" == "new" ]] && echo "  --structural  structural subset"
        exit 0
    fi
    echo "called $*" >>"$STUB_LOG"
    exit "${STUB_RC:-0}"
fi
exit 0
STUB
chmod +x "$WORK/bin/chump"

cd "$WORK/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t
echo a >a.txt && git add a.txt && git commit -qm base
git update-ref refs/remotes/origin/main HEAD
mkdir scripts && echo 'true' >scripts/x.sh && git add scripts/x.sh && git commit -qm change
SHA="$(git rev-parse HEAD)"
mkdir -p .chump-locks
STDIN="refs/heads/b $SHA refs/heads/b 0000000000000000000000000000000000000000"

PASS=0; FAIL=0
check() { # name help botmerge rc expect_exit expect_args(none|plain|structural)
    local name="$1" help="$2" bm="$3" rc="$4" want_exit="$5" want_args="$6"
    : >"$WORK/log"; rm -f .chump-locks/ambient.jsonl
    local env_bm=()
    [[ "$bm" == "on" ]] && env_bm=(CHUMP_BOT_MERGE_IN_PROGRESS=1)
    env PATH="$WORK/bin:$PATH" STUB_HELP="$help" STUB_RC="$rc" STUB_LOG="$WORK/log" \
        "${env_bm[@]}" _HOOK_STDIN="$STDIN" CHUMP_PREFLIGHT_CI_AGREEMENT=0 \
        bash "$WORK/guard.sh" >/dev/null 2>&1
    local got_exit=$?
    local args; args="$(cat "$WORK/log")"
    local got_args=plain
    [[ -z "$args" ]] && got_args=none
    [[ "$args" == *--structural* ]] && got_args=structural
    if [[ "$got_exit" == "$want_exit" && "$got_args" == "$want_args" ]]; then
        echo "  PASS: $name"; PASS=$((PASS+1))
    else
        echo "  FAIL: $name (exit=$got_exit want=$want_exit; args=$got_args want=$want_args)"; FAIL=$((FAIL+1))
    fi
}

echo "=== RESILIENT-1625 pre-push Guard 0a behavior ==="
check "plain push, new binary, pass"        new off 0 0 plain
check "plain push, new binary, fail blocks" new off 1 1 plain
check "plain push, stale binary, pass"      stale off 0 0 plain
check "plain push, stale binary, fail"      stale off 1 1 plain
check "bot-merge, new binary, pass"         new on 0 0 structural
check "bot-merge, new binary, fail blocks"  new on 1 1 structural
check "bot-merge, stale binary, pass (skip)" stale on 0 0 none
check "bot-merge, stale binary, fail (skip, no run)" stale on 1 0 none

# subset-run event is distinct from the skip event
: >"$WORK/log"; rm -f .chump-locks/ambient.jsonl
env PATH="$WORK/bin:$PATH" STUB_HELP=new STUB_RC=0 STUB_LOG="$WORK/log" CHUMP_BOT_MERGE_IN_PROGRESS=1 \
    _HOOK_STDIN="$STDIN" CHUMP_PREFLIGHT_CI_AGREEMENT=0 bash "$WORK/guard.sh" >/dev/null 2>&1
if grep -q prepush_structural_subset_ran .chump-locks/ambient.jsonl 2>/dev/null \
   && ! grep -q prepush_preflight_skipped_botmerge .chump-locks/ambient.jsonl 2>/dev/null; then
    echo "  PASS: subset run emits prepush_structural_subset_ran only"; PASS=$((PASS+1))
else
    echo "  FAIL: subset run event kind wrong"; FAIL=$((FAIL+1))
fi

echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
