#!/usr/bin/env bash
# scripts/ci/test-node-refresh-artifact-ancestor.sh — RESILIENT-1037
#
# Proves node-refresh-chump.sh finds a prebuilt aarch64/x86_64 artifact for the
# nearest ANCESTOR commit that actually triggered build-fleet-binaries.yml,
# instead of missing entirely when the green-main pointer lands on a doc-only
# commit (e.g. the recurring "chore(backlog): coherence sync" ships) that
# never triggered a build (build-fleet-binaries.yml's `paths:` filter only
# fires on src/**, crates/**, build.rs, Cargo.*).
#
# LIVE SYMPTOM (mugman, RESILIENT-1037): node-refresh logged "no green-main
# sha found" / an artifact-pull miss for the exact green sha, then cold-built
# with 4 cargo procs on a 2-core node — unsafe. Root cause: green-main is
# found via ci.yml (runs on every push), but build-fleet-binaries.yml only
# runs when buildable paths change, so an exact-sha artifact lookup against a
# doc-only green pointer always misses even though CI already built an
# identical binary for the last source-changing ancestor.
#
# Fails without RESILIENT-1037: pre-change node-refresh-chump.sh only ever
# queries the artifact workflow for the EXACT green/HEAD sha (no
# _find_build_artifact_sha ancestor walk), so with a doc-only tip commit and a
# built ancestor two commits back, the exact-match query returns no run and
# the script falls through to a local cargo build — Test 1's "cargo was NOT
# called" assertion then fails.

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

# ── Fixture: BUILT commit, then a DOC-ONLY commit on top (the green tip) ────
ORIGIN="$TMP/origin.git"
MIRROR="$TMP/mirror"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$MIRROR"
git -C "$MIRROR" config user.email test@example.com
git -C "$MIRROR" config user.name "Test"

echo "v1" > "$MIRROR/src.txt"
git -C "$MIRROR" add src.txt
git -C "$MIRROR" commit -q -m "source change (this commit gets a real CI build)"
BUILT_SHA="$(git -C "$MIRROR" rev-parse HEAD)"
BUILT_SHORT="${BUILT_SHA:0:12}"

echo "coherence sync" > "$MIRROR/docs.txt"
git -C "$MIRROR" add docs.txt
git -C "$MIRROR" commit -q -m "chore(backlog): coherence sync — doc-only, no build triggered"
GREEN_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

git -C "$MIRROR" push -q origin HEAD:main

TARGET="x86_64-unknown-linux-gnu"

# ── Stub `gh`: distinguishes the ancestor-list query from an exact-sha query.
# - runs?branch=main&status=success (no head_sha)  → list query: only BUILT_SHA
#   ever had a successful run.
# - runs?head_sha=<sha>&status=success              → exact-match query: only
#   matches when <sha> == BUILT_SHA (the green tip itself was NEVER built).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
BUILT_SHA="$BUILT_SHA"
BUILT_SHORT="$BUILT_SHORT"
case "\$1" in
  api)
    args="\$*"
    if printf '%s' "\$args" | grep -q "rate_limit"; then
      echo "5000 5000 9999999999"
      exit 0
    fi
    if printf '%s' "\$args" | grep -q "head_sha="; then
      # exact-match query — only the BUILT commit has a run.
      if printf '%s' "\$args" | grep -q "head_sha=\${BUILT_SHA}"; then
        echo "554433"
      else
        echo ""
      fi
      exit 0
    fi
    # ancestor-list query (branch=main&status=success, no head_sha filter).
    echo "\$BUILT_SHA"
    exit 0
    ;;
  run)
    if [ "\$2" = "download" ]; then
      dir=""
      while [ \$# -gt 0 ]; do
        if [ "\$1" = "--dir" ]; then dir="\$2"; fi
        shift
      done
      [ -n "\$dir" ] || { echo "no --dir" >&2; exit 1; }
      mkdir -p "\$dir"
      cat > "\$dir/chump" <<INNER
#!/usr/bin/env bash
echo "chump 0.0.0-ci (\$BUILT_SHORT built now)"
INNER
      chmod +x "\$dir/chump"
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

# ── Stub `cargo`: records that it was called (must NOT be, if the fix works).
cat > "$TMP/bin/cargo" <<EOF
#!/usr/bin/env bash
echo "CARGO_CALLED" >> "$TMP/cargo-calls.log"
mkdir -p target/release
printf '#!/usr/bin/env bash\necho "chump 0.0.0-local built now"\n' > target/release/chump
chmod +x target/release/chump
exit 0
EOF
chmod +x "$TMP/bin/cargo"

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"
FAKEHOME="$TMP/fakehome"
mkdir -p "$FAKEHOME"

# ── Test: green tip is doc-only (never built) but a built ancestor exists ──
env CHUMP_NODE_BIN="$TMP/installed-chump" \
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_TARGET="$TARGET" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA" \
HOME="$FAKEHOME" \
PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$SCRIPT" > "$TMP/out.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "run exited $rc: $(cat "$TMP/out.log")"

VER="$("$TMP/installed-chump" --version 2>/dev/null || echo none)"
case "$VER" in
  *"$BUILT_SHORT"*) ok "artifact-pull installed the BUILT ANCESTOR's binary ($VER), not a cold build" ;;
  *) fail "installed binary version unexpected: $VER" ;;
esac

[ ! -f "$TMP/cargo-calls.log" ] \
    || fail "cargo WAS called ($(cat "$TMP/cargo-calls.log")) — ancestor discovery did not short-circuit the local build"
ok "local cargo build was SKIPPED — the doc-only green tip did not force a cold build"

grep -q '"method":"artifact_pull"' "$AMBIENT" \
    || fail "expected node_binary_refreshed with method=artifact_pull: $(cat "$AMBIENT")"
ok "emitted node_binary_refreshed method=artifact_pull despite the green tip having no direct build"

grep -q "nearest built ancestor" "$TMP/out.log" \
    || fail "expected a log line noting the ancestor fallback: $(cat "$TMP/out.log")"
ok "logged the ancestor-fallback decision (auditable, not silent)"

exit 0
