#!/usr/bin/env bash
# test-pi-mesh-installer-shape.sh — INFRA-1543
#
# Smoke test for the Pi mesh runner installer.
# AC #6: lint the installer, assert labels include linux-arm64,
# assert systemd service file is emitted by the installer.
#
# Exits 0 if all checks pass, non-zero otherwise.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
INSTALLER="$REPO_ROOT/scripts/setup/install-self-hosted-runner-pi.sh"

PASS=0
FAIL=0

ok() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Pi mesh installer shape smoke test (INFRA-1543) ==="
echo

# 1. Installer exists and is executable
echo "-- 1. Installer presence"
if [ -f "$INSTALLER" ]; then
  ok "installer exists at scripts/setup/install-self-hosted-runner-pi.sh"
else
  fail "installer not found at $INSTALLER"
fi
if [ -x "$INSTALLER" ]; then
  ok "installer is executable"
else
  fail "installer is not executable (chmod +x $INSTALLER)"
fi

# 2. Bash lint (syntax check)
echo
echo "-- 2. Bash syntax lint"
if bash -n "$INSTALLER" 2>/dev/null; then
  ok "bash -n passed (no syntax errors)"
else
  fail "bash -n failed on $INSTALLER"
  bash -n "$INSTALLER" || true
fi

# 3. Labels include linux-arm64
echo
echo "-- 3. Labels include linux-arm64"
if grep -q 'linux-arm64' "$INSTALLER"; then
  ok "linux-arm64 label found in installer"
else
  fail "linux-arm64 label NOT found in $INSTALLER"
fi
if grep -q 'chump-fleet-pi' "$INSTALLER"; then
  ok "chump-fleet-pi label found in installer"
else
  fail "chump-fleet-pi label NOT found in $INSTALLER"
fi
# Verify all AC #3 required labels present
for label in "self-hosted" "Linux" "ARM64" "linux-arm64" "chump-fleet-pi"; do
  if grep -q "$label" "$INSTALLER"; then
    ok "label '$label' found"
  else
    fail "required label '$label' NOT found in installer"
  fi
done

# 4. Systemd service file is emitted
echo
echo "-- 4. systemd service file emission"
if grep -q 'SYSTEMD_UNIT_FILE\|\.service\|systemd' "$INSTALLER"; then
  ok "installer references systemd service file"
else
  fail "installer does not appear to emit a systemd service file"
fi
if grep -q '\[Unit\]\|\[Service\]\|\[Install\]' "$INSTALLER"; then
  ok "systemd unit sections ([Unit]/[Service]/[Install]) present in installer"
else
  fail "systemd unit sections NOT found in installer"
fi
if grep -q 'WantedBy=multi-user.target' "$INSTALLER"; then
  ok "WantedBy=multi-user.target present (standard systemd daemon target)"
else
  fail "WantedBy=multi-user.target NOT found in installer"
fi

# 5. Offline/air-gapped cache path
echo
echo "-- 5. Offline cache path"
if grep -q 'CHUMP_PI_TARBALL_CACHE\|cache\|--from-cache' "$INSTALLER"; then
  ok "offline cache mechanism found in installer"
else
  fail "offline cache mechanism NOT found in installer"
fi
if grep -q '\-\-from-cache\|FROM_CACHE_DIR' "$INSTALLER"; then
  ok "--from-cache / FROM_CACHE_DIR air-gapped install path present"
else
  fail "--from-cache / FROM_CACHE_DIR NOT found in installer"
fi

# 6. --check flag present
echo
echo "-- 6. --check flag"
if grep -q '\-\-check' "$INSTALLER"; then
  ok "--check flag present"
else
  fail "--check flag NOT found in installer"
fi

# 7. Assert script targets Linux ARM64 (guard present)
echo
echo "-- 7. Platform guard"
if grep -q 'assert_linux_arm64\|Linux.*ARM\|aarch64' "$INSTALLER"; then
  ok "Linux ARM64 platform guard present"
else
  fail "Linux ARM64 platform guard NOT found in installer"
fi

# 8. Rust-First-Bypass trailer
echo
echo "-- 8. META-064 compliance"
if grep -q 'Rust-First-Bypass' "$INSTALLER"; then
  ok "Rust-First-Bypass trailer present (META-064 shell-OK bypass)"
else
  fail "Rust-First-Bypass trailer NOT found (required by META-064 pre-commit hook)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
