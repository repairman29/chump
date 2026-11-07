#!/usr/bin/env bash
# scripts/review/mutant-run.sh — CREDIBLE-1650: the sandboxed mutant runner
# the review organ needed to stop holding every gate-file PR for a human.
#
# Applies syntactic mutants (comparison/boolean operator flips — the kind a
# gate-file PR's own test suite should catch) to the lines a PR ADDS to a
# gate file, in a throwaway `git worktree`, running the caller's test command
# against each mutant. Never touches the caller's working tree: the worktree
# is removed on exit, success or failure.
#
# Prints a record in the exact format
# scripts/dispatch/review-organ-tick.sh's mutant_record_satisfies() parses:
#   head: <sha>
#   patch-id: <id>
#   mutant N: <file>:<line> <op>-><op> — KILLED|SURVIVED (test: <cmd>)
#
# Two modes:
#   --self-test   builds its own tiny fixture git repo with one mutant the
#                 fixture test catches (KILLED) and one it doesn't exercise
#                 (SURVIVED), asserts both outcomes, and exits 0/1. This is
#                 the review organ's AVAILABILITY PROBE (CREDIBLE-1650 AC-c)
#                 — no network, no real PR, <2s — and is also the CI fixture
#                 (scripts/ci/test-mutant-run.sh) proving the killed AND
#                 surviving paths both work (AC4).
#   (default)     --repo <path> --head <sha> [--base <ref>] --file <path>
#                 --test <shell command> --patch-id <id> [--pr <n>]
#                 mutates the real diff of <file> between <base> (default
#                 origin/main) and <head>.
#
# Fails CLOSED: any setup error (unreadable diff, no worktree, no recognized
# mutation operator in the added lines) exits non-zero and prints NOTHING on
# stdout — a caller must never treat a failed run as "zero mutants, all
# clear". The organ only posts a record on a zero exit.
set -uo pipefail

MODE="run"
REPO=""
HEAD=""
BASE="origin/main"
FILE=""
TEST_CMD=""
PR=""
PATCH_ID=""

usage() { sed -n '2,36p' "${BASH_SOURCE[0]}"; }

while (( $# )); do
    case "$1" in
        --self-test) MODE="self-test"; shift ;;
        --repo)      REPO="${2:-}"; shift 2 ;;
        --head)      HEAD="${2:-}"; shift 2 ;;
        --base)      BASE="${2:-}"; shift 2 ;;
        --file)      FILE="${2:-}"; shift 2 ;;
        --test)      TEST_CMD="${2:-}"; shift 2 ;;
        --pr)        PR="${2:-}"; shift 2 ;;
        --patch-id)  PATCH_ID="${2:-}"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "[mutant-run] unknown argument '$1'" >&2; exit 2 ;;
    esac
done

# mutate_line <path> <lineno> — rewrites <path> IN PLACE with exactly ONE
# recognized operator flipped on line <lineno>. Prints "<op>-><op>" on
# success. Returns 1 (file left untouched) when the line has no recognized
# operator — the caller skips that line, it is never counted as a mutant.
mutate_line() {
    local path="$1" lineno="$2"
    python3 - "$path" "$lineno" <<'PYEOF'
import re, sys
path, lineno = sys.argv[1], int(sys.argv[2])
with open(path, "r") as f:
    lines = f.readlines()
if lineno < 1 or lineno > len(lines):
    sys.exit(1)
line = lines[lineno - 1]
# Longest/most-specific tokens first so e.g. '-ge' is never clobbered first.
OPS = [
    ("-ge", "-lt"), ("-le", "-gt"), ("-gt", "-le"), ("-lt", "-ge"),
    ("-eq", "-ne"), ("-ne", "-eq"),
    ("==", "!="), ("!=", "=="), (">=", "<"), ("<=", ">"),
    ("&&", "||"), ("||", "&&"),
]
for a, b in OPS:
    idx = line.find(a)
    if idx != -1:
        lines[lineno - 1] = line[:idx] + b + line[idx + len(a):]
        with open(path, "w") as f:
            f.writelines(lines)
        print(f"{a}->{b}")
        sys.exit(0)
for a, b in (("true", "false"), ("false", "true")):
    m = re.search(r"\b" + a + r"\b", line)
    if m:
        lines[lineno - 1] = line[:m.start()] + b + line[m.end():]
        with open(path, "w") as f:
            f.writelines(lines)
        print(f"{a}->{b}")
        sys.exit(0)
sys.exit(1)
PYEOF
}

# added_lines <repo> <base> <head> <file> — prints one new-file line number
# per line the diff ADDS. Mutating only lines the PR itself introduces, never
# pre-existing code the PR didn't touch.
added_lines() {
    local repo="$1" base="$2" head="$3" file="$4"
    git -C "$repo" diff "$base" "$head" -- "$file" 2>/dev/null | python3 -c '
import re, sys
newline = 0
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if line.startswith("@@"):
        m = re.search(r"\+(\d+)", line)
        newline = int(m.group(1)) if m else 0
        continue
    if line.startswith("+++") or line.startswith("---"):
        continue
    if line.startswith("+"):
        print(newline)
        newline += 1
    elif line.startswith("-"):
        continue
    else:
        newline += 1
'
}

# run_mutant <worktree> <file> <lineno> <test-cmd> — applies the mutation,
# runs the test inside the worktree, restores the original line, prints
# "<op>\tKILLED" or "<op>\tSURVIVED" on stdout. Returns 1 (nothing printed)
# when <lineno> has no recognized operator.
run_mutant() {
    local wt="$1" file="$2" lineno="$3" test_cmd="$4"
    local target="$wt/$file" backup op rc
    backup="$(mktemp)"
    cp "$target" "$backup"
    if ! op="$(mutate_line "$target" "$lineno")"; then
        rm -f "$backup"
        return 1
    fi
    rc=0
    ( cd "$wt" && eval "$test_cmd" ) >/dev/null 2>&1 || rc=$?
    cp "$backup" "$target"
    rm -f "$backup"
    if [[ "$rc" != 0 ]]; then
        printf '%s\tKILLED\n' "$op"
    else
        printf '%s\tSURVIVED\n' "$op"
    fi
    return 0
}

run_mode() {
    if [[ -z "$REPO" || -z "$HEAD" || -z "$FILE" || -z "$TEST_CMD" || -z "$PATCH_ID" ]]; then
        echo "[mutant-run] --repo, --head, --file, --test and --patch-id are all required" >&2
        return 2
    fi
    [[ -d "$REPO/.git" || -f "$REPO/.git" ]] || { echo "[mutant-run] '$REPO' is not a git repo" >&2; return 2; }

    local wt
    wt="$(mktemp -d)"
    rmdir "$wt"
    # shellcheck disable=SC2064  # intentional early expansion — REPO/wt are fixed by the time the trap fires
    trap "git -C '$REPO' worktree remove --force '$wt' >/dev/null 2>&1 || true; rm -rf '$wt'" RETURN

    if ! git -C "$REPO" worktree add --detach --force "$wt" "$HEAD" >/dev/null 2>&1; then
        echo "[mutant-run] worktree add failed for head '$HEAD'" >&2
        return 1
    fi
    if [[ ! -f "$wt/$FILE" ]]; then
        echo "[mutant-run] '$FILE' absent at head '$HEAD'" >&2
        return 1
    fi

    local lines
    lines="$(added_lines "$REPO" "$BASE" "$HEAD" "$FILE")"
    if [[ -z "$lines" ]]; then
        echo "[mutant-run] no added lines in '$FILE' between $BASE and $HEAD" >&2
        return 1
    fi

    local n=0 record="" result op outcome ln
    while IFS= read -r ln; do
        [[ -z "$ln" ]] && continue
        result="$(run_mutant "$wt" "$FILE" "$ln" "$TEST_CMD")" || continue
        op="${result%%$'\t'*}"
        outcome="${result##*$'\t'}"
        n=$((n+1))
        record+="mutant $n: $FILE:$ln ${op} — ${outcome} (test: ${TEST_CMD})"$'\n'
    done <<< "$lines"

    if [[ "$n" -eq 0 ]]; then
        echo "[mutant-run] no recognized mutation operator in '$FILE' added lines — nothing to report" >&2
        return 1
    fi

    [[ -n "$PR" ]] && echo "pr: $PR"
    echo "head: $HEAD"
    echo "patch-id: $PATCH_ID"
    printf '%s' "$record"
    return 0
}

self_test() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    trap 'rm -rf "'"$tmp"'"' RETURN

    git -C "$tmp" init -q
    git -C "$tmp" config user.email "mutant-run-self-test@example.com"
    git -C "$tmp" config user.name "mutant-run-self-test"
    : > "$tmp/.keep"
    git -C "$tmp" add .keep
    git -C "$tmp" commit -q -m base
    local base; base="$(git -C "$tmp" rev-parse HEAD)"

    # One comparison the fixture test EXERCISES (check_threshold -gt, n=20 ->
    # "big") and one it does NOT (check_other -eq, never called) — the
    # minimal shape that proves both a KILLED and a SURVIVED outcome.
    cat > "$tmp/calc.sh" <<'FIXEOF'
#!/usr/bin/env bash
check_threshold() {
    local n="$1"
    if [[ "$n" -gt 10 ]]; then
        echo "big"
    else
        echo "small"
    fi
}

check_other() {
    local n="$1"
    if [[ "$n" -eq 5 ]]; then
        echo "five"
    else
        echo "other"
    fi
}
FIXEOF
    cat > "$tmp/test-calc.sh" <<'TESTEOF'
#!/usr/bin/env bash
set -euo pipefail
source ./calc.sh
out="$(check_threshold 20)"
[[ "$out" == "big" ]]
TESTEOF
    chmod +x "$tmp/calc.sh" "$tmp/test-calc.sh"
    git -C "$tmp" add calc.sh test-calc.sh
    git -C "$tmp" commit -q -m "add fixture"
    local head; head="$(git -C "$tmp" rev-parse HEAD)"
    local pid; pid="$(git -C "$tmp" diff "$base" "$head" -- calc.sh | git patch-id --stable | awk '{print $1}')"

    local out
    out="$(bash "${BASH_SOURCE[0]}" --repo "$tmp" --head "$head" --base "$base" \
        --file calc.sh --test "bash test-calc.sh" --patch-id "$pid")" || rc=$?
    if [[ "$rc" != 0 ]]; then
        echo "[mutant-run self-test] FAIL: runner exited $rc" >&2
        return 1
    fi
    local killed survived
    killed="$(grep -c 'KILLED' <<< "$out" || true)"
    survived="$(grep -c 'SURVIVED' <<< "$out" || true)"
    if [[ "$killed" -ge 1 && "$survived" -ge 1 ]]; then
        echo "[mutant-run self-test] OK (killed=$killed survived=$survived)"
        return 0
    fi
    echo "[mutant-run self-test] FAIL: expected >=1 KILLED and >=1 SURVIVED, got killed=$killed survived=$survived" >&2
    printf '%s\n' "$out" >&2
    return 1
}

case "$MODE" in
    self-test) self_test; exit $? ;;
    run)       run_mode;  exit $? ;;
esac
