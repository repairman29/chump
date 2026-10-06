#!/usr/bin/env bash
# RESILIENT-1537: the merge-serializer (sole driver) brings GREEN-but-BEHIND PRs
# current with update-branch before merging, pre-warms the next in line, and does it
# without a force-push or a second rebaser. Runs the real script against a local bare
# "origin" and a stub `gh` that records every GitHub call. Never touches the network.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SER="$ROOT/scripts/coord/merge-serializer.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# ── local origin + checkout, with PR branches that fall BEHIND main ─────────────
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/work" 2>/dev/null
G() { git -C "$T/work" -c user.email=ci@chump.test -c user.name=CI -c commit.gpgsign=false "$@"; }
G checkout -q -b main; echo base > "$T/work/base.txt"; G add -A; G commit -q -m base; G push -q origin main
for n in 1 2; do
  G checkout -q -b "pr-$n" main; echo "change $n" > "$T/work/f$n.txt"; G add -A; G commit -q -m "pr $n"; G push -q origin "pr-$n"
done
G checkout -q main; echo more > "$T/work/more.txt"; G add -A; G commit -q -m "main moved"; G push -q origin main   # PR branches now BEHIND
head_of() { git -C "$T/origin.git" rev-parse "refs/heads/$1"; }

# ── stub gh: records mutations, scripted reads ──────────────────────────────────
S="$T/stub"; mkdir -p "$S/bin"
cat > "$S/bin/gh" <<'GH'
#!/usr/bin/env bash
a="$*"
case "$a" in
  *"commits/main/check-runs"*) echo "SUCCESS" ;;
  "pr list"*)                  cat "$STUB/rows" ;;
  *"--json statusCheckRollup"*) n="$(sed -nE 's/^pr view ([0-9]+) .*/\1/p' <<<"$a")"; cat "$STUB/verified-$n" 2>/dev/null || echo SUCCESS ;;
  *"--json mergeStateStatus"*)  n="$(sed -nE 's/^pr view ([0-9]+) .*/\1/p' <<<"$a")"; cat "$STUB/ms-$n" 2>/dev/null || echo BEHIND ;;
  *"--json state"*)             n="$(sed -nE 's/^pr view ([0-9]+) .*/\1/p' <<<"$a")"; [[ -f "$STUB/merged-$n" ]] && echo MERGED || echo OPEN ;;
  *"update-branch"*)            n="$(sed -nE 's#.*/pulls/([0-9]+)/update-branch.*#\1#p' <<<"$a")"; echo "UPDATE_BRANCH $n" >> "$STUB/calls"
                                [[ -f "$STUB/ub-fail" ]] && exit 1; exit 0 ;;
  "pr merge"*"--disable-auto"*) echo "DISABLE_AUTO $(awk '{print $3}' <<<"$a")" >> "$STUB/calls" ;;
  "pr merge"*"--squash"*)       n="$(awk '{print $3}' <<<"$a")"; echo "MERGE $n" >> "$STUB/calls"; touch "$STUB/merged-$n" ;;
esac
exit 0
GH
chmod +x "$S/bin/gh"

rows() { : > "$S/rows"; for n in "$@"; do printf '%s\tpr-%s\tBEHIND\t2026-10-0%sT00:00:00Z\n' "$n" "$n" "$n" >> "$S/rows"; done; }
reset() { rm -f "$S"/calls "$S"/merged-* "$S"/ub-fail "$S"/verified-* "$S"/ms-*; : > "$S/calls"; }
run() { PATH="$S/bin:$PATH" STUB="$S" CHUMP_REPO_ROOT="$T/work" CHUMP_PR_REPO=o/r CHUMP_LOCK_DIR="$T/locks" CHUMP_AMBIENT_LOG="$T/ambient.jsonl" \
        CHUMP_GH_NO_RETRY=1 CHUMP_GH_NO_THROTTLE=1 CHUMP_GH_NO_PREEMPT=1 CHUMP_GH_NO_PATH_INJECT=1 \
        CHUMP_MERGE_SERIALIZER_VERIFY_TIMEOUT_S=3 CHUMP_MERGE_SERIALIZER_POLL_S=1 "$@" bash "$SER" ${SER_ARGS:-} 2>&1; }
calls() { tr '\n' ';' < "$S/calls"; }
mkdir -p "$T/locks"

# 1. Green-but-behind head candidate: update-branch (API), then merge — and NO force-push.
reset; rows 1; before="$(head_of pr-1)"
out="$(run env)"
[[ "$(calls)" == "UPDATE_BRANCH 1;DISABLE_AUTO 1;MERGE 1;" ]] && ok "green-but-behind PR: update-branch -> disable-auto -> squash-merge, in that order" || bad "calls: $(calls) / $out"
[[ "$(head_of pr-1)" == "$before" ]] && ok "no force-push: the PR branch on origin is untouched (GitHub does the update)" || bad "branch was rewritten"
grep -q 'kind":"merge_serializer_update_branch".*"pr":1,"phase":"drive","ok":true' "$T/ambient.jsonl" && ok "kind=merge_serializer_update_branch emitted (phase=drive)" || bad "no update_branch event"

# 2. update-branch fails (e.g. conflict): falls back to the existing rebase path, still merges.
reset; rows 1; touch "$S/ub-fail"; before="$(head_of pr-1)"
out="$(run env)"
grep -q 'falling back to the rebase path' <<<"$out" && [[ "$(calls)" == "UPDATE_BRANCH 1;DISABLE_AUTO 1;MERGE 1;" ]] && [[ "$(head_of pr-1)" != "$before" ]] \
  && ok "failed update-branch falls back to rebase+push (branch rewritten once, by the serializer) and still merges" || bad "fallback: $(calls) / $out"

# 3. BEHIND but verified not green: NOT update-branched (the existing rebase path owns it).
reset; rows 1; echo PENDING > "$S/verified-1"
out="$(run env)"
! grep -q 'UPDATE_BRANCH' "$S/calls" && ok "behind but not green: update-branch path is not used" || bad "update-branched a non-green PR"

# 4. Pre-warm: after merging the head PR, the next green-but-behind PR is update-branched.
reset; rows 1 2
out="$(run env)"
[[ "$(calls)" == "UPDATE_BRANCH 1;DISABLE_AUTO 1;MERGE 1;UPDATE_BRANCH 2;" ]] && ok "pre-warm: next-in-line #2 is brought current after #1 merges (and not merged early)" || bad "prewarm calls: $(calls) / $out"
grep -q '"pr":2,"phase":"prewarm","ok":true' "$T/ambient.jsonl" && ok "pre-warm emits kind=merge_serializer_update_branch phase=prewarm" || bad "no prewarm event"

# 5. Bounded and switchable.
reset; rows 1 2 3
out="$(run env CHUMP_MERGE_SERIALIZER_PREWARM_MAX=1)"
[[ "$(grep -c 'UPDATE_BRANCH' "$S/calls")" == "2" ]] && ok "pre-warm touches at most PREWARM_MAX PRs (#3 left alone)" || bad "unbounded prewarm: $(calls)"
reset; rows 1 2
out="$(run env CHUMP_MERGE_SERIALIZER_PREWARM_MAX=0)"
[[ "$(calls)" == "UPDATE_BRANCH 1;DISABLE_AUTO 1;MERGE 1;" ]] && ok "PREWARM_MAX=0 disables pre-warm" || bad "prewarm=0: $(calls)"
reset; rows 1 2
out="$(run env CHUMP_MERGE_SERIALIZER_UPDATE_BRANCH=0)"
! grep -q 'UPDATE_BRANCH' "$S/calls" && grep -q '^MERGE 1' "$S/calls" && ok "CHUMP_MERGE_SERIALIZER_UPDATE_BRANCH=0 restores the old rebase-only behaviour" || bad "kill switch: $(calls)"

# 6. Sole driver preserved: a second instance never acts while one holds the self-lock.
reset; rows 1
( exec 9>"$T/locks/merge-serializer.lock"; flock -n 9; sleep 6 ) &
holder=$!; sleep 1
out="$(run env)"
[[ ! -s "$S/calls" ]] && grep -q 'another instance holds' <<<"$out" && ok "a second serializer instance exits without touching any PR (no racing rebaser)" || bad "second instance acted: $(calls)"
wait "$holder" 2>/dev/null

# 7. Dry-run mutates nothing and says what it would do.
reset; rows 1
out="$(SER_ARGS=--dry-run run env)"
[[ ! -s "$S/calls" ]] && grep -q 'green-but-behind: would update-branch' <<<"$out" && ok "--dry-run reports the update-branch plan and calls nothing" || bad "dry-run: $(calls) / $out"

echo "=== merge-serializer update-branch: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
