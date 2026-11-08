#!/usr/bin/env bash
# scripts/ci/test-resilient-1625-guard0a-stub-chump.sh — RESILIENT-1625 (a).
#
# Behavioral test for pre-push Guard 0a (chump preflight). Extracts the real
# Guard 0a block from scripts/git-hooks/pre-push and runs it in a scratch git
# repo against STUB `chump` binaries (new help advertising --structural, and a
# stale help without it) over 8 cases: bot-merge on/off x help new/stale x
# preflight pass/fail. Asserts a plain push never gets --structural, a failing
# preflight/subset blocks, a stale binary under bot-merge is skipped, and the
# subset run emits its own kind (prepush_structural_subset_ran).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"
[[ -f "$HOOK" ]] || { echo "[FAIL] missing $HOOK"; exit 1; }

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BLOCK="$(awk '/^# Guard 0a:/,/^# Guard 0: cargo fmt/' "$HOOK")"
[[ -n "$BLOCK" ]] || { echo "[FAIL] could not extract Guard 0a"; exit 1; }

REPO="$TMP/repo"
git init -q -b main "$REPO"
(
    cd "$REPO"
    git config user.email t@t; git config user.name t
    echo base > README; git add README; git commit -qm base
    git update-ref refs/remotes/origin/main HEAD
    git checkout -qb feat
    mkdir -p scripts .chump-locks
    echo 'echo hi' > scripts/x.sh; git add scripts/x.sh; git commit -qm feat
)
SHA="$(git -C "$REPO" rev-parse HEAD)"
ZEROS="0000000000000000000000000000000000000000"
STDIN_LINE="refs/heads/feat $SHA refs/heads/feat $ZEROS"

mkstub() { # <dir> <help: new|stale> <rc>
    mkdir -p "$1"
    cat > "$1/chump" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == preflight && "\${2:-}" == --help ]]; then
    echo "usage: chump preflight [--full]$([[ "$2" == new ]] && echo ' [--structural]')"
    exit 0
fi
echo "\$*" >> "$1/calls"
exit $3
STUB
    chmod +x "$1/chump"
}

run_case() { # <name> <botmerge 0|1> <help> <pf_rc> <expect_block 0|1> <expect_args: none|plain|structural>
    local name="$1" bm="$2" help="$3" rc="$4" want_block="$5" want_args="$6"
    local d="$TMP/stub-$name"
    mkstub "$d" "$help" "$rc"
    : > "$REPO/.chump-locks/ambient.jsonl"
    local got_rc=0
    (
        cd "$REPO"
        export PATH="$d:$PATH"
        if [[ "$bm" == 1 ]]; then export CHUMP_BOT_MERGE_IN_PROGRESS=1; else unset CHUMP_BOT_MERGE_IN_PROGRESS; fi
        export CHUMP_PREFLIGHT_CI_AGREEMENT=0
        _HOOK_STDIN="$STDIN_LINE"
        eval "$BLOCK"
    ) >"$d/out" 2>&1 || got_rc=$?
    local calls=""; [[ -f "$d/calls" ]] && calls="$(cat "$d/calls")"

    local blocked=0; [[ "$got_rc" -ne 0 ]] && blocked=1
    [[ "$blocked" == "$want_block" ]] && ok "$name: blocked=$blocked" || fail "$name: blocked=$blocked want=$want_block (rc=$got_rc)"
    case "$want_args" in
        none)       [[ -z "$calls" ]] && ok "$name: preflight not run" || fail "$name: preflight ran with '$calls'" ;;
        plain)      [[ -n "$calls" && "$calls" != *--structural* ]] && ok "$name: plain preflight, no --structural" || fail "$name: calls='$calls'" ;;
        structural) [[ "$calls" == "preflight --structural" || "$calls" == "--structural" ]] && ok "$name: ran --structural" || fail "$name: calls='$calls'" ;;
    esac
    # The stub is invoked as `chump preflight ...`; normalise by also accepting "preflight" prefix.
    if [[ "$bm" == 1 && "$help" == new && "$want_args" == structural ]]; then
        grep -q '"kind":"prepush_structural_subset_ran"' "$REPO/.chump-locks/ambient.jsonl" \
            && ok "$name: emits prepush_structural_subset_ran" || fail "$name: missing subset-ran event"
        grep -q 'prepush_preflight_skipped_botmerge' "$REPO/.chump-locks/ambient.jsonl" \
            && fail "$name: wrongly emits the skip kind" || ok "$name: no skip kind when subset runs"
    fi
    if [[ "$bm" == 1 && "$help" == stale ]]; then
        grep -q 'prepush_preflight_skipped_botmerge' "$REPO/.chump-locks/ambient.jsonl" \
            && ok "$name: stale binary emits skip kind" || fail "$name: stale skip event missing"
    fi
}

echo "=== RESILIENT-1625: Guard 0a against stub chump (8 cases) ==="
#        name              bm help  rc block args
run_case plain-new-pass     0 new   0 0 plain
run_case plain-new-fail     0 new   1 1 plain
run_case plain-stale-pass   0 stale 0 0 plain
run_case plain-stale-fail   0 stale 1 1 plain
run_case bm-new-pass        1 new   0 0 structural
run_case bm-new-fail        1 new   1 1 structural
run_case bm-stale-pass      1 stale 0 0 none
run_case bm-stale-fail      1 stale 1 0 none

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
