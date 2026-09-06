#!/usr/bin/env bash
# scripts/ci/test-node-refresh-red-run-skip.sh — RESILIENT-1039
#
# Proves node-refresh-chump.sh does NOT force a local cargo build when the
# green-main tip's build-fleet-binaries.yml run went RED (e.g. a transient
# crates.io/toolchain blip) while an OLDER ancestor commit still has a
# successful run. Instead it must silently pull the nearest ANCESTOR's
# artifact and install it — exactly the RESILIENT-1037 ancestor-walk, now
# locked in against the specific "red run sits between two green runs"
# shape observed live: build-fleet-binaries went RED at ff5b70a (05:57),
# then GREEN again two commits later at 3ca3b7a (08:15) after a transient
# failure (`can't find crate for wasmtime`, gone on the very next push) —
# self-healed before any code change was needed. VERIFIED end-to-end against
# the real repo/API in the RESILIENT-1039 PR: node-refresh-chump.sh pulled
# the aarch64 artifact for the nearest green ancestor and logged
# method=artifact_pull with zero cargo invocations.
#
# Fails without the RESILIENT-1037 ancestor-walk (or if a future change drops
# the `status=success` filter from either the ancestor-list or exact-match gh
# queries): the red tip's run would be treated as installable/blocking, the
# artifact download for it would fail, and the script would fall through to a
# local cargo build — Test 1's "cargo was NOT called" assertion below fails.

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

# ── Fixture: GREEN commit, then a RED commit (the tip/green-main pointer) ──
# Mirrors the live shape: ci.yml (a different, every-push workflow) stayed
# green through both commits, so the green-main pointer lands ON the commit
# whose build-fleet-binaries run failed.
ORIGIN="$TMP/origin.git"
MIRROR="$TMP/mirror"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$MIRROR"
git -C "$MIRROR" config user.email test@example.com
git -C "$MIRROR" config user.name "Test"

echo "v1" > "$MIRROR/src.txt"
git -C "$MIRROR" add src.txt
git -C "$MIRROR" commit -q -m "source change (build-fleet-binaries SUCCEEDS here)"
GREEN_ANCESTOR_SHA="$(git -C "$MIRROR" rev-parse HEAD)"
GREEN_ANCESTOR_SHORT="${GREEN_ANCESTOR_SHA:0:12}"

echo "v2" > "$MIRROR/src.txt"
git -C "$MIRROR" add src.txt
git -C "$MIRROR" commit -q -m "source change (build-fleet-binaries FAILS here — transient)"
RED_TIP_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

git -C "$MIRROR" push -q origin HEAD:main

TARGET="x86_64-unknown-linux-gnu"

# ── Stub `gh`: the ancestor-list query (status=success, no head_sha) only
# ever returns the GREEN ancestor — the RED tip never appears, exactly like
# the real GitHub Actions API's status=success filter. The exact-match query
# (head_sha=<sha>&status=success) likewise only matches the GREEN ancestor;
# querying it for the RED tip returns nothing.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
GREEN_SHA="$GREEN_ANCESTOR_SHA"
GREEN_SHORT="$GREEN_ANCESTOR_SHORT"
RED_SHA="$RED_TIP_SHA"
case "\$1" in
  api)
    args="\$*"
    if printf '%s' "\$args" | grep -q "rate_limit"; then
      echo "5000 5000 9999999999"
      exit 0
    fi
    if printf '%s' "\$args" | grep -q "head_sha="; then
      # exact-match query — the RED tip has NO successful run; only the
      # green ancestor does.
      if printf '%s' "\$args" | grep -q "head_sha=\${GREEN_SHA}"; then
        echo "554433"
      else
        echo ""
      fi
      exit 0
    fi
    # ancestor-list query (branch=main&status=success, no head_sha filter) —
    # the RED run is excluded server-side by status=success, same as real gh.
    echo "\$GREEN_SHA"
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
echo "chump 0.0.0-ci (\$GREEN_SHORT built now)"
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

# ── Stub `cargo`: records that it was called (must NOT be, if the fix holds).
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

# ── Test: green-main pointer lands on the RED tip commit; a green ancestor
# exists two commits back. Refresh must pull the ancestor's artifact, not
# cold-build.
env CHUMP_NODE_BIN="$TMP/installed-chump" \
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_TARGET="$TARGET" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$RED_TIP_SHA" \
HOME="$FAKEHOME" \
PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$SCRIPT" > "$TMP/out.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "run exited $rc: $(cat "$TMP/out.log")"

VER="$("$TMP/installed-chump" --version 2>/dev/null || echo none)"
case "$VER" in
  *"$GREEN_ANCESTOR_SHORT"*) ok "artifact-pull installed the GREEN ANCESTOR's binary ($VER), skipping the RED tip" ;;
  *) fail "installed binary version unexpected: $VER" ;;
esac

[ ! -f "$TMP/cargo-calls.log" ] \
    || fail "cargo WAS called ($(cat "$TMP/cargo-calls.log")) — a red run at the tip forced a cold build"
ok "local cargo build was SKIPPED — a red run at the tip did not force a cold build"

grep -q '"method":"artifact_pull"' "$AMBIENT" \
    || fail "expected node_binary_refreshed with method=artifact_pull: $(cat "$AMBIENT")"
ok "emitted node_binary_refreshed method=artifact_pull despite the tip's build-fleet-binaries run being red"

grep -q "nearest built ancestor" "$TMP/out.log" \
    || fail "expected a log line noting the ancestor fallback: $(cat "$TMP/out.log")"
ok "logged the ancestor-fallback decision (auditable, not silent)"

exit 0
