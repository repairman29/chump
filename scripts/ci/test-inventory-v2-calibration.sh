#!/usr/bin/env bash
# INFRA-2378 — smoke test: stale-plist detector false-positive suppression.
#
# Verifies that a plist under a known source directory (e.g. launchd/) with
# a sibling installer script (scripts/setup/install-<stem>.sh) is NOT flagged
# as stale, even when its ProgramArguments[0] binary doesn't exist on disk.
#
# Also verifies that a plist in the same source directory WITHOUT a sibling
# installer IS still flagged (we don't suppress everything, just managed ones).
#
# Exit codes:
#   0 — all assertions passed
#   1 — assertion failed (details printed to stderr)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[test-inventory-v2-calibration] building chump binary..."
    PATH="$HOME/.cargo/bin:$PATH" cargo build \
        --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

TEST_DB="$TMPDIR_TEST/inventory.db"
TEST_AMBIENT="$TMPDIR_TEST/ambient.jsonl"
TEST_MIGRATION="$REPO_ROOT/migrations/inventory_v1.sql"

# ── Synthetic repo root ───────────────────────────────────────────────────────
FAKE_ROOT="$TMPDIR_TEST/repo"
mkdir -p "$FAKE_ROOT"
(
    cd "$FAKE_ROOT"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "test"
    git commit --allow-empty -m "init" --quiet
)

# Set up a minimal directory structure inside the fake repo.
mkdir -p "$FAKE_ROOT/launchd"
mkdir -p "$FAKE_ROOT/scripts/setup"

# --- Case A: template plist WITH a sibling installer (must NOT be flagged) ---
# Plist: launchd/com.chump.foo.plist
# Installer: scripts/setup/install-foo.sh
# Binary referenced in plist: /nonexistent/bin/foo (doesn't exist)
cat > "$FAKE_ROOT/launchd/com.chump.foo.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.foo</string>
    <key>ProgramArguments</key>
    <array>
        <string>/nonexistent/bin/chump-foo</string>
        <string>--run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

cat > "$FAKE_ROOT/scripts/setup/install-foo.sh" << 'EOF'
#!/usr/bin/env bash
# Installer for com.chump.foo
echo "installing foo"
EOF
chmod +x "$FAKE_ROOT/scripts/setup/install-foo.sh"

# --- Case B: template plist WITHOUT a sibling installer (SHOULD be flagged) ---
# Plist: launchd/com.chump.bar.plist
# No installer for bar exists
# Binary referenced in plist: /nonexistent/bin/bar
cat > "$FAKE_ROOT/launchd/com.chump.bar.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.bar</string>
    <key>ProgramArguments</key>
    <array>
        <string>/nonexistent/bin/chump-bar</string>
    </array>
</dict>
</plist>
EOF

# ── Populate artifact_index with both plists ──────────────────────────────────
# Initialize the DB from migration.
sqlite3 "$TEST_DB" < "$TEST_MIGRATION"

# Insert the two test plists into artifact_index.
sqlite3 "$TEST_DB" << 'SQL'
INSERT OR IGNORE INTO artifact_index
    (path, class, size_bytes, first_seen_at, last_modified_at, activation_state, last_synced_at)
VALUES
    ('launchd/com.chump.foo.plist', 'plist', 0,
     strftime('%s','now'), strftime('%s','now'), 'unknown', strftime('%s','now')),
    ('launchd/com.chump.bar.plist', 'plist', 0,
     strftime('%s','now'), strftime('%s','now'), 'unknown', strftime('%s','now'));
SQL

# ── Run the detector via chump inventory rebuild ──────────────────────────────
export CHUMP_INVENTORY_DB="$TEST_DB"
export CHUMP_INVENTORY_MIGRATION="$TEST_MIGRATION"
export CHUMP_AMBIENT_LOG="$TEST_AMBIENT"
export CHUMP_REPO_ROOT="$FAKE_ROOT"

echo "[test-inventory-v2-calibration] running inventory rebuild on fake repo..."
"$CHUMP_BIN" inventory rebuild > "$TMPDIR_TEST/rebuild.out" 2>&1 || {
    cat "$TMPDIR_TEST/rebuild.out"
    echo "FAIL: inventory rebuild exited non-zero" >&2
    exit 1
}

# ── Assertions ────────────────────────────────────────────────────────────────
echo "[test-inventory-v2-calibration] checking findings..."

STALE_FINDINGS="$(sqlite3 "$TEST_DB" \
    "SELECT artifact_path FROM tech_debt_findings WHERE finding_class='stale-plist';")"

# Assert 1: foo.plist (has installer) must NOT appear in findings.
if echo "$STALE_FINDINGS" | grep -q "com.chump.foo.plist"; then
    echo "FAIL: launchd/com.chump.foo.plist was flagged as stale despite having" \
         "a sibling installer (scripts/setup/install-foo.sh)" >&2
    echo "Findings dump:" >&2
    echo "$STALE_FINDINGS" >&2
    exit 1
fi
echo "[test-inventory-v2-calibration] PASS: foo.plist (with installer) correctly suppressed"

# Assert 2: bar.plist (no installer) MUST appear in findings.
if ! echo "$STALE_FINDINGS" | grep -q "com.chump.bar.plist"; then
    echo "FAIL: launchd/com.chump.bar.plist was NOT flagged as stale, but it" \
         "has no installer and its binary doesn't exist" >&2
    echo "Findings dump:" >&2
    echo "$STALE_FINDINGS" >&2
    exit 1
fi
echo "[test-inventory-v2-calibration] PASS: bar.plist (without installer) correctly flagged"

echo "[test-inventory-v2-calibration] all assertions passed"
