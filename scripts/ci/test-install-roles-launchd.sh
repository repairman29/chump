#!/usr/bin/env bash
# INFRA-8569: install-roles-launchd.sh must find role plists under scripts/plists/
# and exit non-zero (loudly) when it finds none.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
cat > "$T/bin/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/launchctl.log"
EOF
chmod +x "$T/bin/launchctl"

run() { HOME="$T/home" CHUMP_HOME="$1" PATH="$T/bin:$PATH" bash "$REPO/scripts/setup/install-roles-launchd.sh"; }

# 1. real repo: at least one role rendered and loaded
run "$REPO" >"$T/out1" 2>&1 || { cat "$T/out1"; echo "FAIL: installer failed on real repo"; exit 1; }
n=$(grep -c '^load ' "$T/launchctl.log" || true)
[ "$n" -ge 1 ] || { echo "FAIL: no launchctl load calls"; exit 1; }
ls "$T/home/Library/LaunchAgents/"*.plist >/dev/null 2>&1 || { echo "FAIL: no plist rendered"; exit 1; }

# 2. empty root: must exit non-zero with loud message
mkdir -p "$T/empty/scripts/plists"
if run "$T/empty" >"$T/out2" 2>&1; then echo "FAIL: exit 0 with zero plists"; exit 1; fi
grep -q "installed 0 role plists" "$T/out2" || { echo "FAIL: no loud message"; cat "$T/out2"; exit 1; }
echo "PASS"
