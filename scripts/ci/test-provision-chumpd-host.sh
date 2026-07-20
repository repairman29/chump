#!/usr/bin/env bash
# test-provision-chumpd-host.sh — RESILIENT-176
#
# Shape/safety smoke test for scripts/setup/provision-chumpd-host.sh.
# This is a PREP-slice gap (chumpd/MISSION-051 hasn't merged), so this test
# does NOT exercise a real provision run — it asserts the script's shape,
# its HOME guard, its dry-run non-mutation contract, and that it embeds no
# credential-looking strings. Mirrors scripts/ci/test-pi-mesh-installer-shape.sh.
#
# Exits 0 if all checks pass, non-zero otherwise.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/setup/provision-chumpd-host.sh"

PASS=0
FAIL=0

ok()   { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== provision-chumpd-host.sh shape smoke test (RESILIENT-176) ==="
echo

# 1. Script presence + executable
echo "-- 1. Script presence"
if [[ -f "$SCRIPT" ]]; then
  ok "script exists at scripts/setup/provision-chumpd-host.sh"
else
  fail "script not found at $SCRIPT"
fi
if [[ -x "$SCRIPT" ]]; then
  ok "script is executable"
else
  fail "script is not executable (chmod +x $SCRIPT)"
fi

# 2. Bash syntax lint
echo
echo "-- 2. Bash syntax lint"
if bash -n "$SCRIPT" 2>/dev/null; then
  ok "bash -n passed (no syntax errors)"
else
  fail "bash -n failed on $SCRIPT"
  bash -n "$SCRIPT" || true
fi

# 3. Refuses to run with unset HOME
echo
echo "-- 3. HOME guard"
if grep -q 'HOME.*unset\|-z.*HOME' "$SCRIPT"; then
  ok "HOME-unset guard present in script source"
else
  fail "no HOME-unset guard found in script source"
fi
HOME_GUARD_OUTPUT="$(env -u HOME bash "$SCRIPT" --check 2>&1)" && HOME_GUARD_EXIT=0 || HOME_GUARD_EXIT=$?
if [[ "$HOME_GUARD_EXIT" -ne 0 ]]; then
  ok "running with HOME unset exits non-zero (exit=$HOME_GUARD_EXIT)"
else
  fail "running with HOME unset did NOT fail (exit=0) — guard is not effective"
fi
if echo "$HOME_GUARD_OUTPUT" | grep -qi 'HOME is unset'; then
  ok "HOME-unset error message is clear"
else
  fail "HOME-unset run produced no clear error message"
fi

# 4. Dry-run mode touches nothing outside a fixture dir
echo
echo "-- 4. Dry-run non-mutation"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# Snapshot files that could plausibly be touched by a non-dry-run provision
# (HOME-scoped state this test's fixture HOME should never gain).
BEFORE_SNAPSHOT="$(find "$FIXTURE_DIR" 2>/dev/null | sort)"

DRYRUN_OUTPUT="$(
  HOME="$FIXTURE_DIR" \
  CHUMPD_PROVISION_DIR="$FIXTURE_DIR/chump-host" \
  bash "$SCRIPT" --dry-run 2>&1
)" && DRYRUN_EXIT=0 || DRYRUN_EXIT=$?

AFTER_SNAPSHOT="$(find "$FIXTURE_DIR" 2>/dev/null | sort)"

# Dry-run may create the fixture HOME's own subdirs it's told to use for
# logging/inventory purposes, but must NOT actually clone a repo (no .git)
# or write a launchd/systemd unit outside intent.
if [[ ! -d "$FIXTURE_DIR/chump-host/.git" ]]; then
  ok "dry-run did not actually clone a repo into CHUMPD_PROVISION_DIR"
else
  fail "dry-run cloned a real repo — mutation occurred under --dry-run"
fi
if echo "$DRYRUN_OUTPUT" | grep -q '\[dry-run\]'; then
  ok "dry-run output uses the [dry-run] would-do marker"
else
  fail "dry-run output missing the [dry-run] marker — can't verify no-op behavior"
fi
# Nothing should be written under the real (test-runner) $HOME/Library/LaunchAgents
# or $HOME/.config/systemd for a chumpd unit as a side effect of this test run.
if [[ ! -f "$HOME/Library/LaunchAgents/com.chump.chumpd.plist" && ! -f "$HOME/.config/systemd/user/chumpd.service" ]]; then
  ok "no chumpd service unit leaked into the real \$HOME during dry-run"
else
  fail "a chumpd service unit was written under the real \$HOME during dry-run — HOME override not honored"
fi
[[ "$DRYRUN_EXIT" -eq 0 ]] && ok "dry-run exits 0" || fail "dry-run exited non-zero ($DRYRUN_EXIT)"

# 5. No credential-looking strings baked into the script
echo
echo "-- 5. No embedded credential-shaped strings"
# GitHub PAT shapes (classic ghp_/gho_/ghu_/ghs_/ghr_ + fine-grained github_pat_),
# generic long base64/hex assignments, and Anthropic key shape sk-ant-.
CRED_PATTERNS='ghp_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|ghu_[A-Za-z0-9]{30,}|ghs_[A-Za-z0-9]{30,}|ghr_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}'
if grep -qE "$CRED_PATTERNS" "$SCRIPT" "$REPO_ROOT/scripts/setup/chumpd.service" 2>/dev/null; then
  fail "credential-shaped string found in provisioning script or service template"
else
  ok "no credential-shaped strings found (checked PAT/oauth/API-key shapes)"
fi
# The script must only CHECK presence of secrets, never echo/print a var's value.
if grep -qE 'echo.*\$GH_TOKEN\b|echo.*\$GITHUB_TOKEN\b|log.*\$GH_TOKEN\b|log.*\$GITHUB_TOKEN\b' "$SCRIPT"; then
  fail "script appears to print a credential env var's VALUE"
else
  ok "script never echoes GH_TOKEN/GITHUB_TOKEN values"
fi

# 6. No secrets-in-argv pattern (RESILIENT-173): no inline KEY=value ... cmd
# constructions with a credential-shaped name immediately before a command.
echo
echo "-- 6. RESILIENT-173 no-secrets-in-argv shape"
if grep -qE '(GH_TOKEN|GITHUB_TOKEN|OAUTH)=[^$ ]+ +[a-zA-Z]' "$SCRIPT"; then
  fail "possible inline credential=value ... cmd pattern found (argv leak shape)"
else
  ok "no inline credential=literal-value ... cmd pattern found"
fi
if grep -q 'EnvironmentFile=' "$REPO_ROOT/scripts/setup/chumpd.service" 2>/dev/null; then
  ok "chumpd.service uses EnvironmentFile= (not inline Environment=KEY=value) for credentials"
else
  fail "chumpd.service does not reference EnvironmentFile= for credential material"
fi

# 7. --check / --uninstall / --dry-run flags present (documented usage surface)
echo
echo "-- 7. Documented flags present"
for flag in '\-\-check' '\-\-dry-run' '\-\-uninstall'; do
  if grep -q -- "$flag" "$SCRIPT"; then
    ok "flag $flag present"
  else
    fail "flag $flag NOT found in script"
  fi
done

# 8. Rust-First-Bypass trailer (META-064 shell-OK justification)
echo
echo "-- 8. META-064 compliance"
if grep -q 'Rust-First-Bypass' "$SCRIPT"; then
  ok "Rust-First-Bypass justification present"
else
  fail "Rust-First-Bypass justification NOT found (required by META-064 pre-commit hook)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
