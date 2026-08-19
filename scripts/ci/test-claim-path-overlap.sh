#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# scripts/ci/test-claim-path-overlap.sh — INFRA-2434
#
# Verifies the claim-time path-overlap-with-open-PR gate:
#   1. `chump claim <GAP> --paths a.sh` is BLOCKED (non-zero, redirect
#      message, kind=claim_path_overlap_blocked) when a mocked open PR
#      already has a.sh in its changed-file set.
#   2. `chump claim <GAP> --paths b.sh` SUCCEEDS past this gate (no
#      overlap — b.sh is disjoint from the mocked PR's files).
#   3. --allow-overlap bypasses the block and emits
#      kind=claim_path_overlap_allowed instead.
#   4. CHUMP_CLAIM_PATH_OVERLAP_OPERATOR=1 skips the check entirely (no
#      event of either kind emitted).
#
# Exits non-zero on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
hdr()  { printf '\n--- %s ---\n' "$*"; }

[[ -f "$SRC" ]] || fail "atomic_claim.rs missing: $SRC"

hdr "Round 1: source-level shape"

grep -q "fn check_claim_path_overlap" "$SRC" \
    || fail "missing fn check_claim_path_overlap"
ok "check_claim_path_overlap defined"

grep -q "fn emit_claim_path_overlap_blocked_event" "$SRC" \
    || fail "missing fn emit_claim_path_overlap_blocked_event"
grep -qE 'kind\\?":\\?"claim_path_overlap_blocked\\?"' "$SRC" \
    || fail "missing canonical kind string claim_path_overlap_blocked"
ok "blocked-event emitter present + uses canonical kind"

grep -q "fn emit_claim_path_overlap_allowed_event" "$SRC" \
    || fail "missing fn emit_claim_path_overlap_allowed_event"
grep -qE 'kind\\?":\\?"claim_path_overlap_allowed\\?"' "$SRC" \
    || fail "missing canonical kind string claim_path_overlap_allowed"
ok "allowed-event emitter present + uses canonical kind"

grep -q '"--allow-overlap"' "$SRC" \
    || fail "missing --allow-overlap flag parsing"
grep -q "allow_overlap" "$SRC" \
    || fail "missing allow_overlap field on ClaimArgs"
ok "--allow-overlap flag wired"

grep -q "CHUMP_CLAIM_PATH_OVERLAP_OPERATOR" "$SRC" \
    || fail "missing CHUMP_CLAIM_PATH_OVERLAP_OPERATOR operator-mode bypass"
ok "CHUMP_CLAIM_PATH_OVERLAP_OPERATOR bypass plumbed"

REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q "kind: claim_path_overlap_blocked" "$REG" \
    || fail "claim_path_overlap_blocked not registered in EVENT_REGISTRY.yaml"
grep -q "kind: claim_path_overlap_allowed" "$REG" \
    || fail "claim_path_overlap_allowed not registered in EVENT_REGISTRY.yaml"
ok "both event kinds registered in EVENT_REGISTRY.yaml"

hdr "Round 2: binary integration (mocked gh)"

if [[ -z "${CHUMP_BIN:-}" ]]; then
    CANDIDATE="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    if [[ -x "$CANDIDATE" ]]; then
        CHUMP_BIN="$CANDIDATE"
    else
        echo "Building chump binary..."
        (cd "$REPO_ROOT" && cargo build --bin chump --quiet) \
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
    && touch README.md \
    && git add . && git commit -q -m init)

cat > "$REPO/docs/gaps/INFRA-PATH-OVERLAP-TEST.yaml" <<'YAML'
- id: INFRA-PATH-OVERLAP-TEST
  domain: INFRA
  title: synthetic test gap for INFRA-2434 path-overlap gate
  status: open
  priority: P1
  effort: xs
  acceptance_criteria:
    - "should never claim with --paths a.sh — open PR mock blocks it"
YAML

# PATH shim for gh: one open PR (#4242, branch chump/infra-other-claim)
# whose changed-file set is exactly [a.sh]. Any other gh invocation
# (open-PR-for-own-branch checks, etc.) returns empty + succeeds.
SHIMDIR="$WORK/bin"
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/gh" <<'SHIM'
#!/usr/bin/env bash
case " $* " in
    *" pull list "*|*" pr list "*)
        # chump calls: gh pr list --state open --json number,headRefName,files --limit 200
        cat <<'JSON'
[{"number":4242,"headRefName":"chump/infra-other-claim","files":[{"path":"a.sh"}]}]
JSON
        exit 0
        ;;
    *" repos/"*"/pulls?state=open&head="*)
        # open-PR-for-own-branch / open-PR-for-own-gap checks: no PR for us.
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
SHIM
chmod +x "$SHIMDIR/gh"

# Round 2a: --paths a.sh must be BLOCKED (overlaps mocked PR #4242).
hdr "Round 2a: overlapping path is blocked"

set +e
OUT="$(PATH="$SHIMDIR:$PATH" \
       CHUMP_WORKTREE_BASE="$WORK/wts-a" \
       CHUMP_REPO="$REPO" \
       "$CHUMP_BIN" claim INFRA-PATH-OVERLAP-TEST \
           --paths a.sh --skip-doctor --skip-import 2>&1)"
RC=$?
set -e

(( RC != 0 )) \
    || { printf '%s\n' "$OUT"; fail "expected non-zero exit for overlapping --paths a.sh; got rc=$RC"; }
ok "claim exited non-zero (rc=$RC) for overlapping path a.sh"

grep -qE "paths overlap with open PR #4242" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must surface 'paths overlap with open PR #4242'"; }
grep -q -- "--allow-overlap" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must mention --allow-overlap escape hatch"; }
ok "diagnostic includes PR number + --allow-overlap hint"

AMBIENT="$REPO/.chump-locks/ambient.jsonl"
[[ -f "$AMBIENT" ]] || fail "ambient.jsonl was not created: $AMBIENT"
grep -q '"kind":"claim_path_overlap_blocked"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient.jsonl missing claim_path_overlap_blocked event"; }
grep -q '"blocking_pr":4242' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient event missing blocking_pr:4242"; }
ok "ambient.jsonl received claim_path_overlap_blocked with full payload"

if [[ -d "$WORK/wts-a/chump-infra-path-overlap-test" ]]; then
    fail "worktree was created despite block — guard must run BEFORE worktree add"
fi
ok "no worktree leaked (block fired before worktree create)"

# Round 2b: --paths b.sh (disjoint from mocked PR's [a.sh]) must NOT be
# blocked by this gate (it may still fail later for unrelated reasons —
# no real state.db seeded — but must get past the overlap check).
hdr "Round 2b: disjoint path succeeds past the gate"

set +e
OUT2="$(PATH="$SHIMDIR:$PATH" \
        CHUMP_WORKTREE_BASE="$WORK/wts-b" \
        CHUMP_REPO="$REPO" \
        "$CHUMP_BIN" claim INFRA-PATH-OVERLAP-TEST \
            --paths b.sh --skip-doctor --skip-import 2>&1)"
set -e

if grep -q "paths overlap with open PR" <<<"$OUT2"; then
    printf '%s\n' "$OUT2"
    fail "disjoint --paths b.sh was incorrectly blocked by the overlap gate"
fi
ok "disjoint --paths b.sh is not blocked by the overlap gate"

BLOCKED_COUNT_AFTER_B=$(grep -c '"kind":"claim_path_overlap_blocked"' "$AMBIENT" || true)
(( BLOCKED_COUNT_AFTER_B == 1 )) \
    || fail "disjoint path run must not add a new claim_path_overlap_blocked event (count=$BLOCKED_COUNT_AFTER_B)"
ok "no spurious claim_path_overlap_blocked event for disjoint path"

# Round 2c: --allow-overlap bypasses the block for the overlapping path.
hdr "Round 2c: --allow-overlap bypass"

set +e
OUT3="$(PATH="$SHIMDIR:$PATH" \
        CHUMP_WORKTREE_BASE="$WORK/wts-c" \
        CHUMP_REPO="$REPO" \
        "$CHUMP_BIN" claim INFRA-PATH-OVERLAP-TEST \
            --paths a.sh --allow-overlap --skip-doctor --skip-import 2>&1)"
set -e

if grep -q "paths overlap with open PR" <<<"$OUT3"; then
    printf '%s\n' "$OUT3"
    fail "--allow-overlap did NOT bypass the path-overlap block"
fi
ok "--allow-overlap bypasses the block (failure downstream, if any, is unrelated)"

grep -q '"kind":"claim_path_overlap_allowed"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient.jsonl missing claim_path_overlap_allowed event from --allow-overlap run"; }
ok "ambient.jsonl received claim_path_overlap_allowed for the bypass"

# Round 2d: CHUMP_CLAIM_PATH_OVERLAP_OPERATOR=1 skips the check entirely.
hdr "Round 2d: CHUMP_CLAIM_PATH_OVERLAP_OPERATOR=1 skips the check"

BLOCKED_BEFORE=$(grep -c '"kind":"claim_path_overlap_blocked"' "$AMBIENT" || true)
ALLOWED_BEFORE=$(grep -c '"kind":"claim_path_overlap_allowed"' "$AMBIENT" || true)

set +e
OUT4="$(PATH="$SHIMDIR:$PATH" \
        CHUMP_WORKTREE_BASE="$WORK/wts-d" \
        CHUMP_REPO="$REPO" \
        CHUMP_CLAIM_PATH_OVERLAP_OPERATOR=1 \
        "$CHUMP_BIN" claim INFRA-PATH-OVERLAP-TEST \
            --paths a.sh --skip-doctor --skip-import 2>&1)"
set -e

if grep -q "paths overlap with open PR" <<<"$OUT4"; then
    printf '%s\n' "$OUT4"
    fail "CHUMP_CLAIM_PATH_OVERLAP_OPERATOR=1 did not skip the block"
fi
ok "operator-mode skips the block entirely"

BLOCKED_AFTER=$(grep -c '"kind":"claim_path_overlap_blocked"' "$AMBIENT" || true)
ALLOWED_AFTER=$(grep -c '"kind":"claim_path_overlap_allowed"' "$AMBIENT" || true)
(( BLOCKED_AFTER == BLOCKED_BEFORE && ALLOWED_AFTER == ALLOWED_BEFORE )) \
    || fail "operator-mode must emit NEITHER event kind ($BLOCKED_BEFORE->$BLOCKED_AFTER blocked, $ALLOWED_BEFORE->$ALLOWED_AFTER allowed)"
ok "operator-mode emits no path-overlap event of either kind"

echo
echo "All INFRA-2434 path-overlap-with-open-PR assertions passed."
