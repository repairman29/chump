#!/usr/bin/env bash
# scripts/ci/test-node-refresh-artifact-pull.sh — INFRA-3677
#
# Proves node-refresh-chump.sh PULLS the prebuilt CI binary for the green-main
# SHA and installs it WITHOUT running a local cargo build — the build-speed
# payoff. Also proves the pull path degrades to a local build when the artifact
# is absent (the fallback contract that keeps a node no-worse-off than before).
#
# Fails without INFRA-3677: pre-change node-refresh-chump.sh always ran cargo
# (no _try_artifact_pull), so the "cargo was NOT called" assertion in Test 1
# would fail.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ops/node-refresh-chump.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -x "$SCRIPT" ] || fail "missing or not executable"
bash -n "$SCRIPT" || fail "syntax error"
ok "bash -n passes"

# ── Fixture: bare origin + mirror clone with a single (green) commit ────────
ORIGIN="$TMP/origin.git"
MIRROR="$TMP/mirror"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$MIRROR"
git -C "$MIRROR" config user.email test@example.com
git -C "$MIRROR" config user.name "Test"
echo "v1" > "$MIRROR/f.txt"
git -C "$MIRROR" add f.txt
git -C "$MIRROR" commit -q -m "green commit"
git -C "$MIRROR" push -q origin HEAD:main
GREEN_SHA="$(git -C "$MIRROR" rev-parse HEAD)"
GREEN_SHORT="${GREEN_SHA:0:12}"

TARGET="x86_64-unknown-linux-gnu"

# ── Stub `gh`: api → a run id; run download → drop a stub chump + sha256 ─────
# The stub reports the green SHORT sha in --version so the pull's verification
# passes. The sha256 file is computed to match so the integrity check passes.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
# arg-tolerant: handle both direct calls and chump_gh-wrapped calls.
# chump_gh's preempt logic calls \`gh api rate_limit\` before the real call —
# it must see a HEALTHY bucket or it preempts (skips) the background call.
case "\$1" in
  api)
    if printf '%s' "\$*" | grep -q "rate_limit"; then
      echo "5000 5000 9999999999"   # core graphql reset — all healthy
      exit 0
    fi
    # The runs?head_sha= lookup → return a run id.
    echo "778899"
    exit 0
    ;;
  run)
    if [ "\$2" = "download" ]; then
      # Find --dir <path>
      dir=""
      while [ \$# -gt 0 ]; do
        if [ "\$1" = "--dir" ]; then dir="\$2"; fi
        shift
      done
      [ -n "\$dir" ] || { echo "no --dir" >&2; exit 1; }
      mkdir -p "\$dir"
      cat > "\$dir/chump" <<INNER
#!/usr/bin/env bash
echo "chump 0.0.0-ci ($GREEN_SHORT built now)"
INNER
      chmod +x "\$dir/chump"
      # matching sha256 so the integrity check passes
      if command -v sha256sum >/dev/null 2>&1; then
        (cd "\$dir" && sha256sum chump > chump.sha256)
      fi
      exit 0
    fi
    exit 1
    ;;
esac
exit 1
EOF
chmod +x "$TMP/bin/gh"

# ── Stub `cargo`: records that it was called (it must NOT be, in Test 1) ─────
cat > "$TMP/bin/cargo" <<EOF
#!/usr/bin/env bash
echo "CARGO_CALLED" >> "$TMP/cargo-calls.log"
mkdir -p target/release
printf '#!/usr/bin/env bash\necho "chump 0.0.0-local ($GREEN_SHORT built now)"\n' > target/release/chump
chmod +x target/release/chump
exit 0
EOF
chmod +x "$TMP/bin/cargo"

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"
FAKEHOME="$TMP/fakehome"
mkdir -p "$FAKEHOME"

# ── Test 1: artifact present → install via pull, cargo NOT called ────────────
env CHUMP_NODE_BIN="$TMP/installed-chump" \
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_TARGET="$TARGET" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA" \
HOME="$FAKEHOME" \
PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$SCRIPT" > "$TMP/out1.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "pull run exited $rc: $(cat "$TMP/out1.log")"

VER="$("$TMP/installed-chump" --version 2>/dev/null || echo none)"
case "$VER" in
  *"$GREEN_SHORT"*) ok "artifact-pull installed the prebuilt binary ($VER)" ;;
  *) fail "installed binary version unexpected: $VER" ;;
esac

[ ! -f "$TMP/cargo-calls.log" ] \
    || fail "cargo WAS called ($(cat "$TMP/cargo-calls.log")) — pull did not short-circuit the local build"
ok "local cargo build was SKIPPED (the build-speed win)"

grep -q '"method":"artifact_pull"' "$AMBIENT" \
    || fail "expected node_binary_refreshed with method=artifact_pull: $(cat "$AMBIENT")"
ok "emitted node_binary_refreshed method=artifact_pull"

# ── Test 2: no artifact (gh api returns empty run) → falls back to cargo ─────
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  api) echo ""; exit 0 ;;   # no successful run for this sha
esac
exit 1
EOF
chmod +x "$TMP/bin/gh"
rm -f "$TMP/cargo-calls.log"
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"

env CHUMP_NODE_BIN="$TMP/installed-chump2" \
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_TARGET="$TARGET" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs2" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA" \
HOME="$FAKEHOME" \
PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$SCRIPT" > "$TMP/out2.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fallback run exited $rc: $(cat "$TMP/out2.log")"

[ -f "$TMP/cargo-calls.log" ] \
    || fail "cargo was NOT called on artifact miss — fallback to local build broken"
ok "artifact miss falls back to a local cargo build (no-worse-off contract)"

grep -q '"kind":"node_binary_artifact_miss"' "$AMBIENT" \
    || fail "expected node_binary_artifact_miss emitted on fallback: $(cat "$AMBIENT")"
ok "emitted node_binary_artifact_miss on the fallback path"

# ── Test 3: CHUMP_NODE_SKIP_ARTIFACT_PULL=1 forces local build ──────────────
rm -f "$TMP/cargo-calls.log"
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"
env CHUMP_NODE_BIN="$TMP/installed-chump3" \
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_TARGET="$TARGET" \
CHUMP_NODE_SKIP_ARTIFACT_PULL=1 \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs3" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA" \
HOME="$FAKEHOME" \
PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$SCRIPT" > "$TMP/out3.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "skip-pull run exited $rc: $(cat "$TMP/out3.log")"
[ -f "$TMP/cargo-calls.log" ] \
    || fail "CHUMP_NODE_SKIP_ARTIFACT_PULL=1 did not force the local build"
ok "CHUMP_NODE_SKIP_ARTIFACT_PULL=1 forces the local build (operator escape hatch)"

# ── Test 4 (RESILIENT-1041): gh present but UNAUTHENTICATED ─────────────────
# Every test above stubs a WORKING gh via CHUMP_NODE_REFRESH_TEST_GREEN_SHA,
# which bypasses the real _find_green_main_sha gh lookup entirely — none of
# them exercise what happens when gh is on PATH (command -v gh succeeds, so
# the script never takes the "gh unavailable" branch) but every `gh api` call
# fails because the timer environment has no GH_TOKEN / no `gh auth login`
# (RESILIENT-1040, not yet shipped). This is the adversarial case from the
# gap: the green-lookup silently comes back empty, the node falls back to RAW
# origin/main HEAD (which may be red), the artifact-pull lookup also comes up
# empty, and the node pays a full local cargo build. Both fallbacks must now
# emit a halt-class signal, not just a soft ambient note.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Simulates a real unauthenticated `gh` in a non-interactive timer: every
# `api` call fails (rc=1, empty stdout) regardless of the query.
echo "gh: To use GitHub CLI in this environment, run 'gh auth login' or set GH_TOKEN." >&2
exit 1
EOF
chmod +x "$TMP/bin/gh"
rm -f "$TMP/cargo-calls.log"
: > "$AMBIENT"
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"

env CHUMP_NODE_BIN="$TMP/installed-chump4" \
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_TARGET="$TARGET" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs4" \
HOME="$FAKEHOME" \
PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$SCRIPT" > "$TMP/out4.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "unauthed-gh run exited $rc: $(cat "$TMP/out4.log")"

grep -q '"kind":"node_refresh_green_lookup_failed"' "$AMBIENT" \
    || fail "unauthed gh did not fall back to raw origin/main HEAD: $(cat "$AMBIENT")"
ok "unauthed gh (present, all api calls fail) falls back to raw origin/main HEAD"

[ -f "$TMP/cargo-calls.log" ] \
    || fail "unauthed gh did not fall through to a local cargo build (artifact lookup should also fail)"
ok "unauthed gh also misses the artifact-pull lookup and cold-builds locally"

grep -q '"kind":"halt_class_emit".*"name":"node-refresh-green-lookup".*"status":"failure"' "$AMBIENT" \
    || fail "raw-HEAD-fallback did NOT emit a halt-class signal (RESILIENT-1041): $(cat "$AMBIENT")"
ok "raw-HEAD-fallback emits a halt-class signal (RESILIENT-1041)"

grep -q '"kind":"halt_class_emit".*"name":"node-refresh-cold-build".*"status":"failure"' "$AMBIENT" \
    || fail "cold-build fallback did NOT emit a halt-class signal (RESILIENT-1041): $(cat "$AMBIENT")"
ok "cold-build-revert emits a halt-class signal (RESILIENT-1041)"

# ── Test 5 (RESILIENT-1041 fix a): explicit gh-auth precondition ────────────
# Test 4 proves the two DOWNSTREAM fallbacks (green-lookup, cold-build) still
# fire when gh is unauthenticated. This test proves the NEW up-front
# diagnosis: node-refresh-chump.sh checks `gh auth status` before doing
# anything else and emits a distinctly-named halt-class signal
# (node-refresh-gh-auth) that names the root cause directly, instead of
# leaving the operator to infer "unauthenticated gh" from two generic-looking
# fallback events. Fails without the fix: pre-change node-refresh-chump.sh had
# no _check_gh_auth_precondition, so this event would never appear.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 1 ;;
  *) echo "gh: To use GitHub CLI in this environment, run 'gh auth login' or set GH_TOKEN." >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
rm -f "$TMP/cargo-calls.log"
: > "$AMBIENT"
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"

env CHUMP_NODE_BIN="$TMP/installed-chump5" \
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_TARGET="$TARGET" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs5" \
HOME="$FAKEHOME" \
PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$SCRIPT" > "$TMP/out5.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "gh-auth-precondition run exited $rc: $(cat "$TMP/out5.log")"

grep -q '"kind":"halt_class_emit".*"name":"node-refresh-gh-auth".*"status":"failure"' "$AMBIENT" \
    || fail "gh-auth precondition did NOT emit its own halt-class signal (RESILIENT-1041 fix a): $(cat "$AMBIENT")"
ok "unauthenticated gh emits an explicit node-refresh-gh-auth halt-class signal up front"

exit 0
