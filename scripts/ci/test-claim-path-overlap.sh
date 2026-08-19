#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# scripts/ci/test-claim-path-overlap.sh — INFRA-2434
#
# Verifies the claim-time path-overlap-with-open-PR gate: `chump claim
# <ID> --paths ...` scans every open PR's changed-file set and refuses the
# claim when a declared path overlaps one already in flight. Mocks the `gh`
# CLI via a PATH shim so the test runs offline / unauthenticated.
#
# Coverage:
#   1. SOURCE-level shape checks (helpers, ambient emitters, flag plumbing)
#   2. BINARY-level: mock one open PR with files=[a.sh]; claim --paths a.sh
#      is refused (non-zero, redirect message, ambient event, no worktree);
#      claim --paths b.sh (disjoint file) succeeds past this gate.
#   3. --allow-overlap bypass proceeds despite the overlap and emits
#      claim_path_overlap_allowed instead of _blocked.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
hdr()  { printf '\n--- %s ---\n' "$*"; }

[[ -f "$SRC" ]] || fail "atomic_claim.rs missing: $SRC"

hdr "Round 1: source-level shape"

grep -q "fn check_pr_path_overlap" "$SRC" \
    || fail "missing fn check_pr_path_overlap"
ok "check_pr_path_overlap helper defined"

grep -q "fn emit_claim_path_overlap_blocked" "$SRC" \
    || fail "missing fn emit_claim_path_overlap_blocked"
grep -qE 'kind\\?":\\?"claim_path_overlap_blocked\\?"' "$SRC" \
    || fail "missing canonical kind string claim_path_overlap_blocked"
ok "blocked-event emitter present + uses canonical kind"

grep -q "fn emit_claim_path_overlap_allowed" "$SRC" \
    || fail "missing fn emit_claim_path_overlap_allowed"
grep -qE 'kind\\?":\\?"claim_path_overlap_allowed\\?"' "$SRC" \
    || fail "missing canonical kind string claim_path_overlap_allowed"
ok "allowed-event emitter present + uses canonical kind"

grep -q '"--allow-overlap"' "$SRC" \
    || fail "missing --allow-overlap flag parsing"
grep -q "allow_overlap" "$SRC" \
    || fail "missing allow_overlap field on ClaimArgs"
ok "--allow-overlap flag wired"

grep -q "CHUMP_CLAIM_PATH_OVERLAP_OPERATOR" "$SRC" \
    || fail "missing CHUMP_CLAIM_PATH_OVERLAP_OPERATOR env-var bypass"
ok "CHUMP_CLAIM_PATH_OVERLAP_OPERATOR operator bypass plumbed"

REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q "kind: claim_path_overlap_blocked" "$REG" \
    || fail "claim_path_overlap_blocked not registered in EVENT_REGISTRY.yaml"
grep -q "kind: claim_path_overlap_allowed" "$REG" \
    || fail "claim_path_overlap_allowed not registered in EVENT_REGISTRY.yaml"
ok "both event kinds registered in EVENT_REGISTRY.yaml"

hdr "Round 2: binary integration (mocked gh)"

# Resolve chump binary: prefer CHUMP_BIN env, then the Cargo target dir
# (may be redirected via CARGO_TARGET_DIR, e.g. a shared target across
# worktrees), then fall back to building.
if [[ -z "${CHUMP_BIN:-}" ]]; then
    CANDIDATE="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    if [[ -x "$CANDIDATE" ]]; then
        CHUMP_BIN="$CANDIDATE"
    else
        (cd "$REPO_ROOT" && cargo build --bin chump --quiet 2>&1 | tail -20) \
            || fail "cargo build --bin chump failed; cannot run integration"
        CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    fi
fi
[[ -x "$CHUMP_BIN" ]] || fail "no debug chump binary at $CHUMP_BIN"

WORK="$(mktemp -d -t chump-2434-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO"
(cd "$REPO" \
    && git init -q -b main \
    && git config user.email "test@example.com" \
    && git config user.name  "Test" \
    && git remote add origin https://github.com/test-owner/test-repo.git \
    && mkdir -p .chump .chump-locks docs/gaps \
    && echo '{}' > .chump/state.db.placeholder \
    && touch README.md \
    && git add . && git commit -q -m init)

cat > "$REPO/docs/gaps/INFRA-PATH-OVERLAP-TEST.yaml" <<'YAML'
- id: INFRA-PATH-OVERLAP-TEST
  domain: INFRA
  title: synthetic test gap for INFRA-2434 overlap gate
  status: open
  priority: P1
  effort: xs
  acceptance_criteria:
    - "claim --paths a.sh must be blocked by mock open PR #4242"
YAML

# PATH shim for gh: mocks exactly one open PR (#4242, title unrelated to our
# gap-id so it never trips the earlier INFRA-1982/INFRA-1503 open-PR gates)
# whose changed files are [a.sh]. Any other gh invocation (the earlier
# --search based gates, `gh pr diff`, etc.) returns empty/success so this
# test isolates the INFRA-2434 gate specifically.
SHIMDIR="$WORK/bin"
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/gh" <<'SHIM'
#!/usr/bin/env bash
case " $* " in
    *" pr list "*"--json number,title,files"*)
        cat <<'JSON'
[{"number":4242,"title":"INFRA-9999: unrelated fix","files":[{"path":"a.sh"}]}]
JSON
        exit 0
        ;;
    *" pr diff "*)
        # No matching a.sh section -> parse_diff_hunks_for_path finds nothing,
        # same_file_ranges_disjoint stays conservative (false).
        printf 'diff --git a/other.sh b/other.sh\n@@ -1,1 +1,1 @@\n'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
SHIM
chmod +x "$SHIMDIR/gh"

hdr "Round 2a: overlapping path (a.sh) is blocked"

set +e
OUT="$(PATH="$SHIMDIR:$PATH" \
       CHUMP_WORKTREE_BASE="$WORK/wts" \
       CHUMP_REPO="$REPO" \
       "$CHUMP_BIN" claim INFRA-PATH-OVERLAP-TEST --paths a.sh \
           --skip-doctor --skip-import 2>&1)"
RC=$?
set -e

(( RC != 0 )) \
    || { printf '%s\n' "$OUT"; fail "expected non-zero exit when path overlaps open PR"; }
ok "claim exited non-zero (rc=$RC) when --paths overlaps open PR #4242"

grep -qE "open PR #4242" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must surface PR #4242"; }
grep -q "INFRA-9999" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must surface blocking gap id parsed from PR title"; }
grep -q -- "--allow-overlap" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must list --allow-overlap escape hatch"; }
ok "diagnostic includes PR number + blocking gap id + override hint"

AMBIENT="$REPO/.chump-locks/ambient.jsonl"
[[ -f "$AMBIENT" ]] || fail "ambient.jsonl was not created: $AMBIENT"
grep -q '"kind":"claim_path_overlap_blocked"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient.jsonl missing claim_path_overlap_blocked event"; }
grep -q '"blocking_pr":4242' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient event missing blocking_pr:4242"; }
grep -q '"overlapping_paths":\["a.sh"\]' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient event missing overlapping_paths:[a.sh]"; }
ok "ambient.jsonl received claim_path_overlap_blocked with full payload"

if [[ -d "$WORK/wts/chump-infra-path-overlap-test" ]]; then
    fail "worktree was created despite block — guard must run BEFORE worktree add"
fi
ok "no worktree leaked (block fired before worktree create)"

hdr "Round 2b: disjoint path (b.sh) is not blocked by this gate"

set +e
OUT2="$(PATH="$SHIMDIR:$PATH" \
        CHUMP_WORKTREE_BASE="$WORK/wts2" \
        CHUMP_REPO="$REPO" \
        "$CHUMP_BIN" claim INFRA-PATH-OVERLAP-TEST --paths b.sh \
            --skip-doctor --skip-import 2>&1)"
RC2=$?
set -e

if grep -q '"kind":"claim_path_overlap_blocked"' <<<"$(tail -1 "$AMBIENT")"; then
    fail "disjoint path b.sh incorrectly triggered claim_path_overlap_blocked"
fi
grep -qE "open PR #4242" <<<"$OUT2" \
    && fail "diagnostic mentions PR #4242 for a disjoint path — false positive"
ok "claim with --paths b.sh (rc=$RC2) is not refused by the INFRA-2434 gate"

hdr "Round 2c: --allow-overlap bypasses the block and audits it"

EVENT_COUNT_BEFORE=$(grep -c '"kind":"claim_path_overlap_allowed"' "$AMBIENT" || true)

set +e
OUT3="$(PATH="$SHIMDIR:$PATH" \
        CHUMP_WORKTREE_BASE="$WORK/wts3" \
        CHUMP_REPO="$REPO" \
        "$CHUMP_BIN" claim INFRA-PATH-OVERLAP-TEST --paths a.sh --allow-overlap \
            --skip-doctor --skip-import 2>&1)"
RC3=$?
set -e

if grep -qE "open PR #4242 \(gap INFRA-9999" <<<"$OUT3" && grep -q "^\[claim\] paths overlap" <<<"$OUT3"; then
    printf '%s\n' "$OUT3"
    fail "--allow-overlap did NOT bypass the path-overlap block"
fi
ok "--allow-overlap bypasses the block (rc=$RC3; any failure now is downstream)"

EVENT_COUNT_AFTER=$(grep -c '"kind":"claim_path_overlap_allowed"' "$AMBIENT" || true)
(( EVENT_COUNT_AFTER > EVENT_COUNT_BEFORE )) \
    || { cat "$AMBIENT"; fail "--allow-overlap path did not emit claim_path_overlap_allowed"; }
ok "ambient.jsonl received claim_path_overlap_allowed for the bypass"

echo
echo "All INFRA-2434 claim-path-overlap assertions passed."
