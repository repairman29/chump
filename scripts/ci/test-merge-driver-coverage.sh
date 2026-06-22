#!/usr/bin/env bash
# test-merge-driver-coverage.sh — INFRA-1389
#
# Validates merge-driver coverage for hot shared files:
#  1. .gitattributes registers a driver for each hot file
#  2. Every registered driver script exists and is executable
#  3. install-merge-drivers.sh registers the 2 active INFRA-1389 aliases
#  4. INFRA-1526 regression guard: src/main.rs must NOT have a custom merge driver
#  5. Synthetic append-only conflict on Cargo.toml → auto-resolved, no markers
#  6. Synthetic append-only conflict on web/v2/app.js → auto-resolved, no markers
#  7. Non-pure-append conflict → driver exits 1 (falls back to 3-way, expected)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1389 merge-driver coverage test ==="
echo

GITATTRS="$REPO_ROOT/.gitattributes"

# ── 1. .gitattributes contains all active hot files ─────────────────────────
HOT_FILES=(
  ".github/workflows/ci.yml"
  "docs/observability/EVENT_REGISTRY.yaml"
  "Cargo.toml"
  "web/v2/app.js"
)
for hf in "${HOT_FILES[@]}"; do
  if grep -qF "$hf" "$GITATTRS" 2>/dev/null; then
    ok ".gitattributes: $hf has a merge driver"
  else
    fail ".gitattributes: $hf missing merge driver entry"
  fi
done

# ── 2. Every driver script referenced by .gitattributes exists + executable ──
# Parse 'merge=<name>' from .gitattributes, map to driver scripts
while IFS= read -r line; do
  # Skip comments and blank lines
  [[ "$line" =~ ^# ]] && continue
  [[ -z "${line// }" ]] && continue
  # Extract merge driver alias (e.g., ci-yml-add-row)
  alias=$(echo "$line" | grep -oE 'merge=[^ ]+' | cut -d= -f2)
  [[ -z "$alias" ]] && continue
  # Skip git built-ins (union, ours, theirs)
  [[ "$alias" == "union" || "$alias" == "ours" || "$alias" == "theirs" ]] && continue
  # Map alias to script (convention: merge-driver-<alias>.sh or merge-driver-append-only.sh).
  # The chump-state-sql-regen alias maps to merge-driver-state-sql-regen.sh (strip prefix).
  script="$REPO_ROOT/scripts/git/merge-driver-${alias}.sh"
  script_no_prefix="$REPO_ROOT/scripts/git/merge-driver-${alias#chump-}.sh"
  generic="$REPO_ROOT/scripts/git/merge-driver-append-only.sh"
  if [[ -x "$script" ]]; then
    ok "driver script executable: scripts/git/merge-driver-${alias}.sh"
  elif [[ -x "$script_no_prefix" ]]; then
    ok "driver script executable: scripts/git/merge-driver-${alias#chump-}.sh (alias=$alias)"
  elif [[ -x "$generic" ]] && [[ "$alias" =~ (cargo-toml-append|js-append) ]]; then
    ok "driver script executable: merge-driver-append-only.sh (alias=$alias)"
  else
    fail "driver script missing or not executable for alias=$alias"
  fi
done < "$GITATTRS"

# ── 3. install-merge-drivers.sh registers active INFRA-1389 aliases ─────────
INSTALL_SCRIPT="$REPO_ROOT/scripts/setup/install-merge-drivers.sh"
for alias in cargo-toml-append js-append; do
  if grep -q "$alias" "$INSTALL_SCRIPT" 2>/dev/null; then
    ok "install-merge-drivers.sh registers $alias"
  else
    fail "install-merge-drivers.sh missing $alias registration"
  fi
done

# ── 4. INFRA-1526 regression guard: src/main.rs must NOT use a merge driver ──
# rust-main-append was removed from .gitattributes on 2026-05-23 because its
# fallback path silently dropped hunks instead of producing conflict markers.
if grep -E "^src/main\.rs[[:space:]]+merge=" "$GITATTRS" 2>/dev/null | grep -qv "^#"; then
  fail "INFRA-1526 regression: src/main.rs has a custom merge driver in .gitattributes — remove it"
else
  ok "src/main.rs has no custom merge driver (INFRA-1526 guard)"
fi
if grep -q 'git config.*merge\.rust-main-append\.name' "$INSTALL_SCRIPT" 2>/dev/null; then
  fail "INFRA-1526 regression: install-merge-drivers.sh still registers rust-main-append driver"
else
  ok "install-merge-drivers.sh does not register rust-main-append (INFRA-1526 guard)"
fi

# ── 4–6. Synthetic append-only conflict simulations ─────────────────────────
DRIVER="$REPO_ROOT/scripts/git/merge-driver-append-only.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_driver_test() {
  local label="$1"
  local ancestor_content="$2"
  local ours_content="$3"
  local theirs_content="$4"
  local expect_success="$5"  # "true" or "false"
  local expect_contains="${6:-}"  # optional substring expected in merged output

  local anc="$TMP/ancestor"
  local ours="$TMP/ours"
  local theirs="$TMP/theirs"
  printf '%s' "$ancestor_content" > "$anc"
  printf '%s' "$ours_content"     > "$ours"
  printf '%s' "$theirs_content"   > "$theirs"

  if bash "$DRIVER" "$anc" "$ours" "$theirs" "7"; then
    if [[ "$expect_success" == "true" ]]; then
      # Verify no conflict markers remain.
      if grep -q "^<<<<<<\|^>>>>>>\|^=======$" "$ours" 2>/dev/null; then
        fail "$label: driver exited 0 but conflict markers remain"
      elif [[ -n "$expect_contains" ]] && ! grep -qF "$expect_contains" "$ours" 2>/dev/null; then
        fail "$label: driver exited 0 but expected content '$expect_contains' not found"
      else
        ok "$label: auto-resolved (exit 0, no markers, expected content present)"
      fi
    else
      fail "$label: expected driver failure (exit 1) but it succeeded"
    fi
  else
    if [[ "$expect_success" == "false" ]]; then
      ok "$label: correctly declined non-pure-append (exit 1, falls back to 3-way)"
    else
      fail "$label: driver unexpectedly failed (exit 1) on a pure-append case"
    fi
  fi
}

# Cargo.toml — two branches each add a different dependency
CARGO_ANCESTOR='[package]
name = "chump"
version = "0.1.0"

[dependencies]
serde = "1"
'
CARGO_OURS="${CARGO_ANCESTOR}tokio = \"1\""$'\n'
CARGO_THEIRS="${CARGO_ANCESTOR}anyhow = \"1\""$'\n'
run_driver_test \
  "Cargo.toml: two distinct dep additions" \
  "$CARGO_ANCESTOR" "$CARGO_OURS" "$CARGO_THEIRS" \
  "true" "anyhow"

# Cargo.toml — same dep added by both (dedup case)
CARGO_BOTH_OURS="${CARGO_ANCESTOR}serde_json = \"1\""$'\n'
CARGO_BOTH_THEIRS="${CARGO_ANCESTOR}serde_json = \"1\""$'\n'
run_driver_test \
  "Cargo.toml: same dep by both branches (dedup)" \
  "$CARGO_ANCESTOR" "$CARGO_BOTH_OURS" "$CARGO_BOTH_THEIRS" \
  "true" "serde_json"

# web/v2/app.js — two branches each add a new VIEWS entry
JS_ANCESTOR='const VIEWS = {
  chat: () => document.createElement("chump-view-chat"),
};
'
JS_OURS="${JS_ANCESTOR}// branch A\n"
JS_THEIRS="${JS_ANCESTOR}// branch B\n"
run_driver_test \
  "web/v2/app.js: two distinct additions" \
  "$JS_ANCESTOR" "$JS_OURS" "$JS_THEIRS" \
  "true" "branch B"

# ── 7. Non-pure-append: one branch edited the shared prefix ─────────────────
NON_APPEND_ANCESTOR='line1
line2
line3
'
NON_APPEND_OURS='line1
line2-modified-by-ours
line3
new-from-ours
'
NON_APPEND_THEIRS='line1
line2
line3
new-from-theirs
'
run_driver_test \
  "Non-pure-append: prefix edit → driver declines" \
  "$NON_APPEND_ANCESTOR" "$NON_APPEND_OURS" "$NON_APPEND_THEIRS" \
  "false"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
