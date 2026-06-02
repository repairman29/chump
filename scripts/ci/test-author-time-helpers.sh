#!/usr/bin/env bash
# INFRA-2399: Smoke tests for 5 author-time helper subcommands.
# Runs each helper against temp-file fixtures, asserts correct edits.
# Usage: bash scripts/ci/test-author-time-helpers.sh
set -euo pipefail

PASS=0
FAIL=0
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BINARY="${CHUMP_BIN:-"${REPO_ROOT}/target/debug/chump"}"

# Build binary if not present
if [[ ! -f "$BINARY" ]]; then
    echo "[smoke] building chump binary..."
    cd "$REPO_ROOT"
    PATH="$HOME/.cargo/bin:$PATH" cargo build --quiet 2>&1
fi

TMPDIR_FIXTURES="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURES"' EXIT

ok() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

assert_contains() {
    local file="$1" pattern="$2" label="$3"
    # `--` marks end-of-options so patterns starting with '-' aren't treated as flags.
    if grep -qF -- "$pattern" "$file"; then
        ok "$label"
    else
        fail "$label — expected '$pattern' in $file"
        echo "  file contents:"
        cat "$file"
    fi
}

assert_not_contains() {
    local file="$1" pattern="$2" label="$3"
    if ! grep -qF -- "$pattern" "$file"; then
        ok "$label"
    else
        fail "$label — unexpected '$pattern' found in $file"
    fi
}

# ── Helper: make a fake repo root with fixture files ──────────────────────────
make_fixture_root() {
    local root="$1"
    mkdir -p "$root/scripts/ci"
    mkdir -p "$root/scripts/setup"
    mkdir -p "$root/.github/workflows"
    mkdir -p "$root/docs/observability"
    mkdir -p "$root/src"

    # Fake Cargo.toml with [workspace] so repo_root() finds it
    printf '[workspace]\nmembers = []\n' > "$root/Cargo.toml"

    # .env.example fixture
    printf '# Chump env example\nEXISTING_VAR=foo\n' > "$root/.env.example"

    # env-vars-internal.txt fixture
    cat > "$root/scripts/ci/env-vars-internal.txt" <<'EOF'
# Internal env vars
# ── Tier 2 debug/advanced ────────────────────────────────────────────────────
CHUMP_DEBUG
# ── Tier 3 system/runtime ────────────────────────────────────────────────────
HOME
EOF

    # chump-fleet-bootstrap.sh fixture
    cat > "$root/scripts/setup/chump-fleet-bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
# REQUIRED_DAEMONS (INFRA-1594)
REQUIRED_DAEMONS=(
    "com.chump.paramedic|scripts/setup/install-paramedic.sh"
)
EOF

    # optional-installers-allowlist.txt fixture
    printf '# optional installers\ninstall-existing-optional.sh\n' \
        > "$root/scripts/setup/optional-installers-allowlist.txt"

    # deprecated-installers-allowlist.txt fixture
    printf '# deprecated installers\n' \
        > "$root/scripts/setup/deprecated-installers-allowlist.txt"

    # ci.yml fixture with code: block
    cat > "$root/.github/workflows/ci.yml" <<'EOF'
name: CI
on: [push]
jobs:
  filter:
    runs-on: ubuntu-latest
    steps:
      - uses: dorny/paths-filter@v4
        with:
          filters: |
            code:
              - 'docs/**'
              - 'scripts/**'
              - 'src/**'
            docs:
              - 'docs/**'
EOF

    # EVENT_REGISTRY.yaml fixture
    cat > "$root/docs/observability/EVENT_REGISTRY.yaml" <<'EOF'
# EVENT_REGISTRY.yaml
events:
  - kind: existing_event
    effect_metric: credible
    status: stable
EOF

    # raw-gh-allowlist.txt fixture
    cat > "$root/scripts/ci/raw-gh-allowlist.txt" <<'EOF'
# INFRA-1274 raw-gh allowlist
scripts/coord/existing.sh    # migration gap: INFRA-0001
EOF
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 1: chump add-env-var — tier 1 (.env.example)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 1: add-env-var tier 1 (.env.example) ──"
ROOT1="$TMPDIR_FIXTURES/t1"
make_fixture_root "$ROOT1"

CHUMP_REPO_ROOT="$ROOT1" "$BINARY" add-env-var MY_NEW_VAR --tier 1 --gap-id INFRA-9999
assert_contains "$ROOT1/.env.example" "# MY_NEW_VAR=" "tier-1 var appears commented in .env.example"
assert_contains "$ROOT1/.env.example" "# gap: INFRA-9999" "tier-1 gap comment appears above var"

# Idempotency: run again, should not duplicate
CHUMP_REPO_ROOT="$ROOT1" "$BINARY" add-env-var MY_NEW_VAR --tier 1 --gap-id INFRA-9999
count=$(grep -c "MY_NEW_VAR=" "$ROOT1/.env.example" || true)
if [[ "$count" -eq 1 ]]; then
    ok "tier-1 idempotent (no duplicate)"
else
    fail "tier-1 idempotent — expected 1 occurrence, got $count"
fi

# ══════════════════════════════════════════════════════════════════════════════
# TEST 2: chump add-env-var — tier 2 (env-vars-internal.txt)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 2: add-env-var tier 2 (env-vars-internal.txt) ──"
ROOT2="$TMPDIR_FIXTURES/t2"
make_fixture_root "$ROOT2"

CHUMP_REPO_ROOT="$ROOT2" "$BINARY" add-env-var CHUMP_MY_DEBUG --tier 2 --gap-id INFRA-8888
assert_contains "$ROOT2/scripts/ci/env-vars-internal.txt" "CHUMP_MY_DEBUG" "tier-2 var in internal file"
assert_contains "$ROOT2/scripts/ci/env-vars-internal.txt" "# gap: INFRA-8888" "tier-2 gap comment present"

# Critical: no inline comment on the var line itself
# The var line must be exactly "CHUMP_MY_DEBUG" — not "CHUMP_MY_DEBUG # anything"
if grep -E "^CHUMP_MY_DEBUG\s*#" "$ROOT2/scripts/ci/env-vars-internal.txt"; then
    fail "tier-2 CRITICAL: inline comment found on var line (audit will misparse)"
else
    ok "tier-2 no inline comment on var line"
fi

# Idempotency
CHUMP_REPO_ROOT="$ROOT2" "$BINARY" add-env-var CHUMP_MY_DEBUG --tier 2 --gap-id INFRA-8888
count=$(grep -c "^CHUMP_MY_DEBUG$" "$ROOT2/scripts/ci/env-vars-internal.txt" || true)
if [[ "$count" -eq 1 ]]; then
    ok "tier-2 idempotent"
else
    fail "tier-2 idempotent — expected 1 occurrence, got $count"
fi

# ══════════════════════════════════════════════════════════════════════════════
# TEST 3: chump emit-event (EVENT_REGISTRY.yaml)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 3: emit-event (EVENT_REGISTRY.yaml) ──"
ROOT3="$TMPDIR_FIXTURES/t3"
make_fixture_root "$ROOT3"

CHUMP_REPO_ROOT="$ROOT3" "$BINARY" emit-event my_new_event_kind \
    --gap-id INFRA-7777 --description "Emitted when a new thing happens"
assert_contains "$ROOT3/docs/observability/EVENT_REGISTRY.yaml" \
    "kind: my_new_event_kind" "new kind registered in EVENT_REGISTRY.yaml"
assert_contains "$ROOT3/docs/observability/EVENT_REGISTRY.yaml" \
    "status: pending" "new entry has status: pending"
assert_contains "$ROOT3/docs/observability/EVENT_REGISTRY.yaml" \
    "INFRA-7777" "gap reference present in registry entry"

# Idempotency: existing kind is skipped
CHUMP_REPO_ROOT="$ROOT3" "$BINARY" emit-event existing_event
count=$(grep -c "kind: existing_event" "$ROOT3/docs/observability/EVENT_REGISTRY.yaml" || true)
if [[ "$count" -eq 1 ]]; then
    ok "emit-event idempotent for existing kind"
else
    fail "emit-event idempotent — expected 1 occurrence, got $count"
fi

# ══════════════════════════════════════════════════════════════════════════════
# TEST 4: chump install-daemon (all three kinds)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 4: install-daemon (required / optional / deprecated) ──"
ROOT4="$TMPDIR_FIXTURES/t4"
make_fixture_root "$ROOT4"

# required
CHUMP_REPO_ROOT="$ROOT4" "$BINARY" install-daemon my-new-watchdog --kind required --gap-id INFRA-6666
assert_contains "$ROOT4/scripts/setup/chump-fleet-bootstrap.sh" \
    "com.chump.my-new-watchdog|scripts/setup/install-my-new-watchdog.sh" \
    "required daemon entry in bootstrap"
assert_contains "$ROOT4/scripts/setup/chump-fleet-bootstrap.sh" \
    "INFRA-6666" "gap comment present for required daemon"

# optional
CHUMP_REPO_ROOT="$ROOT4" "$BINARY" install-daemon my-optional-tool --kind optional
assert_contains "$ROOT4/scripts/setup/optional-installers-allowlist.txt" \
    "install-my-optional-tool.sh" "optional daemon in allowlist"

# deprecated
CHUMP_REPO_ROOT="$ROOT4" "$BINARY" install-daemon old-thing --kind deprecated
assert_contains "$ROOT4/scripts/setup/deprecated-installers-allowlist.txt" \
    "install-old-thing.sh" "deprecated daemon in deprecated allowlist"

# Idempotency: required daemon
CHUMP_REPO_ROOT="$ROOT4" "$BINARY" install-daemon my-new-watchdog --kind required --gap-id INFRA-6666
count=$(grep -c "com.chump.my-new-watchdog" "$ROOT4/scripts/setup/chump-fleet-bootstrap.sh" || true)
if [[ "$count" -eq 1 ]]; then
    ok "install-daemon required idempotent"
else
    fail "install-daemon required idempotent — expected 1 occurrence, got $count"
fi

# ══════════════════════════════════════════════════════════════════════════════
# TEST 5: chump add-path-filter (ci.yml code: block)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 5: add-path-filter (ci.yml code: block) ──"
ROOT5="$TMPDIR_FIXTURES/t5"
make_fixture_root "$ROOT5"

CHUMP_REPO_ROOT="$ROOT5" "$BINARY" add-path-filter myfeature
assert_contains "$ROOT5/.github/workflows/ci.yml" \
    "- 'myfeature/**'" "new dir in ci.yml code: block"

# Alphabetical: myfeature should appear between docs and src
python3 - "$ROOT5/.github/workflows/ci.yml" <<'PYEOF'
import sys
with open(sys.argv[1]) as f:
    lines = f.read().splitlines()

in_code = False
entries = []
for line in lines:
    t = line.strip()
    if t == "code:":
        in_code = True
        continue
    if in_code:
        if t.startswith("- '") or t.startswith('- "'):
            entries.append(t)
        elif t and not t.startswith("#") and entries:
            break

prefixes = []
for e in entries:
    inner = e[3:].rstrip("'\"").rstrip("/**")
    prefixes.append(inner)

if prefixes != sorted(prefixes):
    print(f"SORT FAIL: {prefixes}")
    sys.exit(1)
else:
    print(f"SORT OK: {prefixes}")
PYEOF
if [[ $? -eq 0 ]]; then
    ok "add-path-filter: entries are alphabetically sorted"
else
    fail "add-path-filter: entries are NOT alphabetically sorted"
fi

# Idempotency
CHUMP_REPO_ROOT="$ROOT5" "$BINARY" add-path-filter myfeature
count=$(grep -c "myfeature/\*\*" "$ROOT5/.github/workflows/ci.yml" || true)
if [[ "$count" -eq 1 ]]; then
    ok "add-path-filter idempotent"
else
    fail "add-path-filter idempotent — expected 1 occurrence, got $count"
fi

# ══════════════════════════════════════════════════════════════════════════════
# TEST 6: chump add-raw-gh-allowlist (raw-gh-allowlist.txt)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 6: add-raw-gh-allowlist ──"
ROOT6="$TMPDIR_FIXTURES/t6"
make_fixture_root "$ROOT6"

CHUMP_REPO_ROOT="$ROOT6" "$BINARY" add-raw-gh-allowlist \
    scripts/coord/my-new-gh-script.sh --migration-gap INFRA-5555
assert_contains "$ROOT6/scripts/ci/raw-gh-allowlist.txt" \
    "scripts/coord/my-new-gh-script.sh" "script path in raw-gh-allowlist"
assert_contains "$ROOT6/scripts/ci/raw-gh-allowlist.txt" \
    "migration gap: INFRA-5555" "migration gap comment present"

# Error case: missing --migration-gap
set +e
CHUMP_REPO_ROOT="$ROOT6" "$BINARY" add-raw-gh-allowlist scripts/coord/no-gap.sh 2>/dev/null
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
    ok "add-raw-gh-allowlist: fails without --migration-gap"
else
    fail "add-raw-gh-allowlist: should have failed without --migration-gap"
fi

# Idempotency
CHUMP_REPO_ROOT="$ROOT6" "$BINARY" add-raw-gh-allowlist \
    scripts/coord/my-new-gh-script.sh --migration-gap INFRA-5555
count=$(grep -c "my-new-gh-script.sh" "$ROOT6/scripts/ci/raw-gh-allowlist.txt" || true)
if [[ "$count" -eq 1 ]]; then
    ok "add-raw-gh-allowlist idempotent"
else
    fail "add-raw-gh-allowlist idempotent — expected 1 occurrence, got $count"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "══════════════════════════════════════════"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
