#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# scripts/ci/test-claim-path-overlap.sh — INFRA-2434
#
# Verifies that `chump claim <ID> --paths <csv>` refuses (non-zero) when the
# declared paths overlap the changed-file set of a currently OPEN PR
# (scanned via `gh pr list --json ...,files`), and proceeds cleanly when the
# declared paths do NOT overlap any open PR. Mocks the `gh` CLI via a PATH
# shim so the test runs offline / unauthenticated.
#
# Coverage:
#   1. SOURCE-level shape checks (helpers, ambient emitter, flag/env plumbing)
#   2. BINARY-level integration: claim --paths a.sh against a mocked open PR
#      that touched a.sh — must abort with the redirect message + emit
#      kind=claim_path_overlap_blocked.
#   3. claim --paths b.sh (disjoint from the mocked PR's files) must NOT hit
#      the path-overlap gate.
#   4. --allow-overlap proceeds past the gate despite the overlap and emits
#      kind=claim_path_overlap_allowed instead of _blocked.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
hdr()  { printf '\n--- %s ---\n' "$*"; }

[[ -f "$SRC" ]] || fail "atomic_claim.rs missing: $SRC"

hdr "Round 1: source-level shape"

grep -q "fn check_open_pr_path_overlap" "$SRC" \
    || fail "missing fn check_open_pr_path_overlap"
ok "check_open_pr_path_overlap helper defined"

grep -q "fn emit_claim_path_overlap_event" "$SRC" \
    || fail "missing fn emit_claim_path_overlap_event"
grep -q '"claim_path_overlap_blocked"' "$SRC" \
    || fail "missing claim_path_overlap_blocked kind string"
grep -q '"claim_path_overlap_allowed"' "$SRC" \
    || fail "missing claim_path_overlap_allowed kind string"
ok "ambient emitter present + canonical kinds referenced"

grep -q '"--allow-overlap"' "$SRC" \
    || fail "missing --allow-overlap flag parsing"
grep -q "allow_overlap" "$SRC" \
    || fail "missing allow_overlap field on ClaimArgs"
ok "--allow-overlap flag wired"

grep -q "CHUMP_CLAIM_PATH_OVERLAP_OPERATOR" "$SRC" \
    || fail "missing CHUMP_CLAIM_PATH_OVERLAP_OPERATOR env-var bypass"
ok "CHUMP_CLAIM_PATH_OVERLAP_OPERATOR operator-mode bypass plumbed"

REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q "kind: claim_path_overlap_blocked" "$REG" \
    || fail "claim_path_overlap_blocked not registered in EVENT_REGISTRY.yaml"
grep -q "kind: claim_path_overlap_allowed" "$REG" \
    || fail "claim_path_overlap_allowed not registered in EVENT_REGISTRY.yaml"
ok "both event kinds registered in EVENT_REGISTRY.yaml"

hdr "Round 2: binary integration (mocked gh)"

CHUMP_BIN="$REPO_ROOT/target/debug/chump"
if [[ ! -x "$CHUMP_BIN" ]]; then
    (cd "$REPO_ROOT" && cargo build --bin chump --quiet 2>&1 | tail -20) \
        || fail "cargo build --bin chump failed; cannot run integration"
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
    && git config commit.gpgsign false \
    && git remote add origin https://github.com/test-owner/test-repo.git \
    && mkdir -p .chump .chump-locks docs/gaps \
    && echo '{}' > .chump/state.db.placeholder \
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
    - "should be blocked by mocked open PR overlap on a.sh"
YAML

# PATH shim for gh: emulate exactly the two query shapes this claim path
# touches — the 5b open-PR-in-flight branch check (no hit, so we get past
# it) and the INFRA-2434 `pr list ... files` scan (one PR touching a.sh).
# Everything else (including the plain `pr list ... number,title` fuzzy
# gate) returns an empty JSON array so it never interferes.
SHIMDIR="$WORK/bin"
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/gh" <<'SHIM'
#!/usr/bin/env bash
case " $* " in
    *" repos/"*"/pulls?state=open&head="*)
        exit 0
        ;;
    *"headRefName,files"*)
        printf '[{"number":9999,"title":"INFRA-9999 fix a.sh","headRefName":"chump/infra-9999-claim","files":[{"path":"a.sh"}]}]\n'
        exit 0
        ;;
    *" pr "*" list "*)
        printf '[]\n'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
SHIM
chmod +x "$SHIMDIR/gh"

# Round 2a: --paths a.sh collides with the mocked PR's files -> refused.
hdr "Round 2a: overlapping path is refused"

set +e
OUT="$(PATH="$SHIMDIR:$PATH" \
       CHUMP_WORKTREE_BASE="$WORK/wts" \
       CHUMP_REPO="$REPO" \
       "$CHUMP_BIN" claim INFRA-PATH-OVERLAP-TEST --paths a.sh \
           --skip-doctor --skip-import 2>&1)"
RC=$?
set -e

(( RC != 0 )) \
    || { printf '%s\n' "$OUT"; fail "expected non-zero exit when paths overlap an open PR; got rc=$RC"; }
ok "claim exited non-zero (rc=$RC) when --paths overlaps open PR #9999"

grep -qE "paths overlap with open PR #9999" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must mention 'paths overlap with open PR #9999'"; }
grep -q "INFRA-9999" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must surface the blocking gap (INFRA-9999)"; }
grep -q "a.sh" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must list the overlapping path (a.sh)"; }
grep -q -- "--allow-overlap" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must list the --allow-overlap escape hatch"; }
ok "diagnostic includes PR number + blocking gap + overlapping path + override hint"

AMBIENT="$REPO/.chump-locks/ambient.jsonl"
[[ -f "$AMBIENT" ]] || fail "ambient.jsonl was not created: $AMBIENT"
grep -q '"kind":"claim_path_overlap_blocked"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient.jsonl missing claim_path_overlap_blocked event"; }
grep -q '"blocking_pr":9999' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient event missing blocking_pr:9999"; }
grep -q '"blocking_gap":"INFRA-9999"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient event missing blocking_gap"; }
ok "ambient.jsonl received claim_path_overlap_blocked with full payload"

if [[ -d "$WORK/wts/chump-infra-path-overlap-test" ]]; then
    fail "worktree was created despite refusal — gate must run BEFORE worktree add"
fi
ok "no worktree leaked (refusal fired before worktree create)"

# Round 2b: --paths b.sh is disjoint from the mocked PR's files -> not blocked.
hdr "Round 2b: disjoint path is not blocked"

set +e
OUT2="$(PATH="$SHIMDIR:$PATH" \
        CHUMP_WORKTREE_BASE="$WORK/wts2" \
        CHUMP_REPO="$REPO" \
        "$CHUMP_BIN" claim INFRA-PATH-OVERLAP-TEST --paths b.sh \
            --skip-doctor --skip-import 2>&1)"
RC2=$?
set -e

if grep -qE "paths overlap with open PR" <<<"$OUT2"; then
    printf '%s\n' "$OUT2"
    fail "--paths b.sh (disjoint from mocked PR files) hit the path-overlap gate"
fi
ok "--paths b.sh does not trip the path-overlap gate (rc=$RC2; any failure is downstream)"

EVENT_COUNT_AFTER_2B=$(grep -c '"kind":"claim_path_overlap_blocked"' "$AMBIENT" || true)
(( EVENT_COUNT_AFTER_2B == 1 )) \
    || fail "round 2b emitted a spurious claim_path_overlap_blocked event (count=$EVENT_COUNT_AFTER_2B, expected 1 from round 2a only)"
ok "round 2b emits no additional claim_path_overlap_blocked event"

# Round 2c: --allow-overlap proceeds past the gate and emits _allowed.
hdr "Round 2c: --allow-overlap bypass"

set +e
OUT3="$(PATH="$SHIMDIR:$PATH" \
        CHUMP_WORKTREE_BASE="$WORK/wts3" \
        CHUMP_REPO="$REPO" \
        "$CHUMP_BIN" claim INFRA-PATH-OVERLAP-TEST --paths a.sh --allow-overlap \
            --skip-doctor --skip-import 2>&1)"
RC3=$?
set -e

grep -q -- "--allow-overlap set; proceeding" <<<"$OUT3" \
    || { printf '%s\n' "$OUT3"; fail "--allow-overlap did not print the proceeding-anyway line"; }
ok "--allow-overlap proceeds past the refusal (rc=$RC3; any failure is downstream)"

grep -q '"kind":"claim_path_overlap_allowed"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient.jsonl missing claim_path_overlap_allowed event from --allow-overlap run"; }
ok "ambient.jsonl received claim_path_overlap_allowed for the bypass run"

echo
echo "All INFRA-2434 path-overlap-with-open-PR assertions passed."
