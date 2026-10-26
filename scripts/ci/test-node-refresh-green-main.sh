#!/usr/bin/env bash
# scripts/ci/test-node-refresh-green-main.sh — RESILIENT-327
#
# Proves node-refresh-chump.sh keeps the BINARY pinned to the last-GREEN main
# pointer while the SOURCE TREE tracks origin/main HEAD (RESILIENT-327 +
# RESILIENT-1205). With a green sha OLDER than HEAD injected via
# CHUMP_NODE_REFRESH_TEST_GREEN_SHA:
#   * the working tree must land on origin/main HEAD (the "bad" tip) — so a
#     merged BASH-organ fix on HEAD actually reaches the iron and this script
#     never fights chump-node-converge (RESILIENT-1189) over the tree SHA;
#   * the INSTALLED BINARY must still report the GREEN sha (built from a detached
#     worktree at the green pin), never the unverified HEAD binary.
# Also proves the explicit (non-silent) fallback to raw HEAD when no green sha
# can be found.
#
# RESILIENT-1205 regression guard: the pre-1205 script reset the WORKING TREE to
# the green pin, which permanently pinned the checkout behind HEAD whenever green
# lagged (a coherence-sync commit with no build artifact) — the merged-!=-deployed
# keystone. This test now asserts the tree tracks HEAD and only the binary is
# green-pinned.

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

# ── Fixture: bare origin + mirror clone with a GREEN commit then a BAD one ──
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

echo "v2-bad" > "$MIRROR/f.txt"
git -C "$MIRROR" commit -q -am "bad commit (red main, would fail CI)"
git -C "$MIRROR" push -q origin HEAD:main
BAD_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

# Reset the mirror's local main back so the script's own `git fetch` +
# `git reset --hard` is exercised against a real remote-ahead-of-local state.
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"

# ── Fake cargo: stub PATH so no real build runs (fast + hermetic) ──────────
mkdir -p "$TMP/bin" "$MIRROR/target/release"
cat > "$TMP/bin/cargo" <<'EOF'
#!/usr/bin/env bash
# Fake `cargo build --release --bin chump`: writes a stub binary that reports
# the sha of the BUILD cwd's HEAD via `chump --version`, mirroring the real
# binary's "(<sha> built ...)" format closely enough for the refresh script's
# grep. Honors CARGO_TARGET_DIR (RESILIENT-1205: node-refresh builds the green
# pin in a detached worktree while reusing the repo's warm target dir).
out="${CARGO_TARGET_DIR:-target}/release"
mkdir -p "$out"
sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
# portable (no sed -i, which differs on BSD/macOS vs GNU): bake the sha directly.
printf '#!/usr/bin/env bash\necho "chump 0.0.0-test (%s built now)"\n' "$sha" > "$out/chump"
chmod +x "$out/chump"
exit 0
EOF
chmod +x "$TMP/bin/cargo"

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"

# ── Test 1: green sha older than HEAD → TREE lands on HEAD, BINARY on green ─
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_BIN="$TMP/installed-chump" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA" \
HOME="$TMP/fakehome" \
PATH="$TMP/bin:$PATH" \
    bash "$SCRIPT" > "$TMP/out1.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "green-pin run exited $rc: $(cat "$TMP/out1.log")"

# RESILIENT-1205: the SOURCE tree tracks origin/main HEAD (the bad tip), so
# merged bash-organ fixes reach the iron and node-converge is never fought.
LANDED_SHA="$(git -C "$MIRROR" rev-parse HEAD)"
[ "$LANDED_SHA" = "$BAD_SHA" ] \
    || fail "source tree landed on $LANDED_SHA, expected origin/main HEAD $BAD_SHA (green pin was $GREEN_SHA)"
ok "node-refresh converges the source tree to origin/main HEAD (RESILIENT-1205)"

# RESILIENT-327: the installed BINARY must still be the GREEN one, built from a
# detached worktree at the green pin — never the unverified HEAD binary.
INSTALLED_VER="$("$TMP/installed-chump" --version 2>/dev/null || echo none)"
case "$INSTALLED_VER" in
    *"${GREEN_SHA:0:12}"*) ok "installed binary is green-pinned ($INSTALLED_VER), not the HEAD binary" ;;
    *"${BAD_SHA:0:12}"*)   fail "installed binary is the HEAD/bad sha ($INSTALLED_VER) — green pin violated" ;;
    *)                     fail "installed binary version unexpected: $INSTALLED_VER" ;;
esac

grep -q "PIN: raw HEAD" "$TMP/out1.log" \
    || fail "expected a loud PIN log line noting raw HEAD is ahead of green-main"
grep -q '"kind":"node_refresh_green_pin_behind_head"' "$AMBIENT" \
    || fail "expected node_refresh_green_pin_behind_head emitted: $(cat "$AMBIENT")"
ok "divergence between raw HEAD and the green pin is logged loudly, not silently"

# ── Test 2: no green sha available → explicit, non-silent fallback to HEAD ─
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_BIN="$TMP/installed-chump2" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs2" \
HOME="$TMP/fakehome" \
PATH="$TMP/bin:$PATH" \
    bash "$SCRIPT" > "$TMP/out2.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fallback run exited $rc: $(cat "$TMP/out2.log")"

LANDED_SHA2="$(git -C "$MIRROR" rev-parse HEAD)"
[ "$LANDED_SHA2" = "$BAD_SHA" ] \
    || fail "fallback (no gh) run should land on raw HEAD ($BAD_SHA), got $LANDED_SHA2"
grep -q '"kind":"node_refresh_green_lookup_failed"' "$AMBIENT" \
    || fail "expected node_refresh_green_lookup_failed emitted on fallback: $(cat "$AMBIENT")"
ok "with no green sha resolvable, falls back to raw HEAD and emits it loudly (non-silent)"

# ── Test 3 (ZERO-WASTE-132): fast no-change short-circuit makes zero gh calls ─
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
echo "GH_CALLED \$*" >> "$TMP/gh-calls-zw132.log"
exit 0
EOF
chmod +x "$TMP/bin/gh"
rm -f "$TMP/gh-calls-zw132.log"

CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_BIN="$TMP/installed-chump2" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs3" \
HOME="$TMP/fakehome" \
PATH="$TMP/bin:$PATH" \
    bash "$SCRIPT" > "$TMP/out3.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fast short-circuit run exited $rc: $(cat "$TMP/out3.log")"
[ ! -f "$TMP/gh-calls-zw132.log" ] || fail "ZERO-WASTE-132: expected 0 gh calls when main SHA unchanged, got: $(cat "$TMP/gh-calls-zw132.log")"
grep -q "fast short-circuit" "$TMP/out3.log" || fail "ZERO-WASTE-132: expected fast short-circuit log line in $(cat "$TMP/out3.log")"
ok "ZERO-WASTE-132: unchanged origin/main short-circuits with 0 gh calls"

# ── Test 4 (RESILIENT-253): release-audit runner-isolation gate + install-self-hosted-runner root refusal ──
RELEASE_AUDIT="$REPO_ROOT/scripts/dev/release-audit.py"
RUNNER_INSTALLER="$REPO_ROOT/scripts/setup/install-self-hosted-runner.sh"
RELEASE_DOC="$REPO_ROOT/docs/process/RELEASE.md"
grep -q "RESILIENT-253" "$RELEASE_DOC" || fail "RESILIENT-253: docs/process/RELEASE.md missing runner isolation gate checklist"

bad_runner_json="$(CHUMP_RELEASE_AUDIT_RUNNER_SPEC='{"runners":[{"name":"closetjunky","user":"root","readable_paths":["/etc/nats/nats.conf"]}]}' \
    python3 "$RELEASE_AUDIT" --since 1d --json --require-runner-isolation 2>&1)"
bad_runner_rc=$?
[ "$bad_runner_rc" -ne 0 ] || fail "RESILIENT-253: release-audit.py --require-runner-isolation must exit non-zero on root runner reading /etc/nats/nats.conf"
printf '%s' "$bad_runner_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["runner_isolation"]["verdict"]=="NO-GO", d; assert "closetjunky:runs_as_root" in d["runner_isolation"]["violations"], d' \
    || fail "RESILIENT-253: expected NO-GO + closetjunky:runs_as_root in release-audit JSON: $bad_runner_json"

good_runner_json="$(CHUMP_RELEASE_AUDIT_RUNNER_SPEC='{"runners":[{"name":"closetjunky","user":"gha-chump","readable_paths":[]}]}' \
    python3 "$RELEASE_AUDIT" --since 1d --json --require-runner-isolation 2>&1)"
good_runner_rc=$?
[ "$good_runner_rc" -eq 0 ] || fail "RESILIENT-253: release-audit.py --require-runner-isolation must exit 0 on isolated gha-chump runner (rc=$good_runner_rc): $good_runner_json"
printf '%s' "$good_runner_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["runner_isolation"]["verdict"]=="GO", d' \
    || fail "RESILIENT-253: expected GO verdict for isolated runner: $good_runner_json"

if RUNNER_ALLOW_RUNASROOT=1 RUNNER_DIR="$TMP/never-runner" bash "$RUNNER_INSTALLER" --token dummy >/dev/null 2>&1; then
    fail "RESILIENT-253: install-self-hosted-runner.sh must refuse RUNNER_ALLOW_RUNASROOT=1"
fi
ok "RESILIENT-253: release-audit runner-isolation gate flags root/credential-exposed runners as NO-GO and installer refuses RUNNER_ALLOW_RUNASROOT=1"

# ── Test 5 (PRODUCT-324): README quick-start CLI commands match src/main.rs ──
python3 - "$REPO_ROOT/README.md" "$REPO_ROOT/src/main.rs" <<'PY' || fail "PRODUCT-324: README quick-start subcommand drift detected"
import pathlib, re, sys

readme = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
main_rs = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

# Extract the "Try Chump in 5 minutes" quick-start section
m = re.search(r"## Try Chump in 5 minutes\b(.*?)(?:\n---\n|\n## )", readme, re.S)
assert m, "Could not locate '## Try Chump in 5 minutes' section in README.md"
quickstart = m.group(1)

subcommands = set()
for block in re.findall(r"```bash\n(.*?)```", quickstart, re.S):
    for line in block.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m_cmd = re.match(r"^chump\s+([a-z][a-z0-9_-]*)\b", line)
        if m_cmd:
            subcommands.add(m_cmd.group(1))

assert len(subcommands) >= 5, f"Expected >=5 subcommands in README quick-start, got {subcommands}"
missing = [
    sub for sub in sorted(subcommands)
    if f'Some("{sub}")' not in main_rs and f'"{sub}"' not in main_rs
]
assert not missing, f"README quick-start subcommands missing from src/main.rs: {missing}"
PY
ok "PRODUCT-324: all README quick-start 'chump <subcommand>' invocations are registered in src/main.rs"

exit 0
