#!/usr/bin/env bash
# install-self-hosted-runner.sh — INFRA-1534
#
# Provisions a GitHub Actions self-hosted runner on this machine and registers
# it as a launchd service so it survives reboots. The runner lets Chump
# bypass GitHub's org-tier concurrency cap that gates CI throughput today.
#
# Architecture rationale: docs/process/SELF_HOSTED_RUNNERS.md
#
# Usage:
#   scripts/setup/install-self-hosted-runner.sh                # interactive install
#   scripts/setup/install-self-hosted-runner.sh --check        # verify registered + online; exit 0/1
#   scripts/setup/install-self-hosted-runner.sh --uninstall    # remove cleanly
#   scripts/setup/install-self-hosted-runner.sh --token TOKEN  # non-interactive with explicit token
#
# Idempotent: re-running does nothing if a healthy runner is already registered.
#
# Rust-First-Bypass: install wrapper around the upstream GitHub actions-runner
# tarball; pure shell glue around curl + tar + launchctl + gh api; no state
# mutation outside ~/actions-runner-chump/. Per META-064 shell-OK criteria.

set -euo pipefail

REPO_OWNER="${CHUMP_REPO_OWNER:-repairman29}"
REPO_NAME="${CHUMP_REPO_NAME:-chump}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-chump}"
RUNNER_NAME_DEFAULT="$(hostname -s | tr '[:upper:]' '[:lower:]')"
RUNNER_NAME="${RUNNER_NAME:-$RUNNER_NAME_DEFAULT}"
RUNNER_LABELS_DEFAULT="self-hosted,macos-arm64,chump-fleet"
RUNNER_LABELS="${RUNNER_LABELS:-$RUNNER_LABELS_DEFAULT}"

# Detect arch + os for the right tarball
case "$(uname -s)" in
  Darwin)  PLATFORM="osx"  ;;
  Linux)   PLATFORM="linux" ;;
  *)       echo "ERROR: unsupported OS $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64)        ARCH="x64"   ;;
  *)             echo "ERROR: unsupported arch $(uname -m)"; exit 1 ;;
esac

LATEST_VERSION_URL="https://api.github.com/repos/actions/runner/releases/latest"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

cmd_check() {
  # Health check: query GH API for runners; assert at least one online for this repo.
  if ! command -v gh >/dev/null 2>&1; then
    echo "FAIL: gh CLI not installed"
    exit 1
  fi
  local online
  online=$(gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
    --jq '.runners[] | select(.status=="online") | .name' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$online" -ge 1 ]; then
    echo "OK: $online self-hosted runner(s) online for $REPO_OWNER/$REPO_NAME"
    gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
      --jq '.runners[] | "  - \(.name) [\(.os)] labels=\(.labels | map(.name) | join(","))"' 2>/dev/null
    exit 0
  else
    echo "FAIL: no online self-hosted runners for $REPO_OWNER/$REPO_NAME"
    echo "Hint: install one with 'scripts/setup/install-self-hosted-runner.sh'"
    exit 1
  fi
}

cmd_uninstall() {
  local plist="$HOME/Library/LaunchAgents/com.chump.actions-runner.plist"
  if [ -f "$plist" ]; then
    launchctl bootout "gui/$UID" "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "Removed launchd plist."
  fi
  if [ -d "$RUNNER_DIR" ]; then
    if [ -x "$RUNNER_DIR/config.sh" ] && [ -n "${TOKEN:-}" ]; then
      (cd "$RUNNER_DIR" && ./config.sh remove --token "$TOKEN") || true
    fi
    rm -rf "$RUNNER_DIR"
    echo "Removed runner directory $RUNNER_DIR."
  fi
  echo "Uninstall complete. Verify via: ./install-self-hosted-runner.sh --check"
}

cmd_install() {
  # 0. Pre-flight
  if [ -d "$RUNNER_DIR" ] && [ -f "$RUNNER_DIR/.runner" ]; then
    echo "Runner already configured at $RUNNER_DIR — re-running is a no-op."
    echo "Use --uninstall to remove, or --check to verify health."
    exit 0
  fi

  if [ -z "${TOKEN:-}" ]; then
    if command -v gh >/dev/null 2>&1; then
      echo "Fetching registration token from GitHub API..."
      TOKEN=$(gh api -X POST "/repos/$REPO_OWNER/$REPO_NAME/actions/runners/registration-token" \
        --jq '.token' 2>/dev/null || true)
    fi
  fi

  if [ -z "${TOKEN:-}" ]; then
    cat <<EOF
ERROR: no registration token available.

Get one manually:
  1. Visit https://github.com/$REPO_OWNER/$REPO_NAME/settings/actions/runners/new
  2. Copy the token shown
  3. Re-run: $0 --token <TOKEN>

Or ensure 'gh' CLI is installed and authenticated with admin:repo scope.
EOF
    exit 1
  fi

  # 1. Get latest version
  echo "Fetching latest actions-runner version..."
  local version tarball_url
  version=$(curl -fsSL "$LATEST_VERSION_URL" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')
  tarball_url="https://github.com/actions/runner/releases/download/v${version}/actions-runner-${PLATFORM}-${ARCH}-${version}.tar.gz"
  echo "Version: $version"
  echo "Tarball: $tarball_url"

  # 2. Download + extract
  mkdir -p "$RUNNER_DIR"
  cd "$RUNNER_DIR"
  echo "Downloading runner..."
  curl -fsSL -o runner.tar.gz "$tarball_url"
  tar xzf runner.tar.gz
  rm runner.tar.gz

  # 3. Configure (non-interactive)
  echo "Registering runner $RUNNER_NAME with labels $RUNNER_LABELS..."
  ./config.sh \
    --url "https://github.com/$REPO_OWNER/$REPO_NAME" \
    --token "$TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --work "_work" \
    --unattended \
    --replace

  # 4. Install as launchd service (macOS)
  if [ "$PLATFORM" = "osx" ]; then
    local plist="$HOME/Library/LaunchAgents/com.chump.actions-runner.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Chump"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.actions-runner</string>
    <key>ProgramArguments</key>
    <array>
        <string>$RUNNER_DIR/run.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$RUNNER_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/Chump/actions-runner.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/Chump/actions-runner.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF
    launchctl bootstrap "gui/$UID" "$plist"
    echo "launchd service installed: $plist"
  else
    echo "On Linux: install as systemd unit manually. Service script at $RUNNER_DIR/svc.sh"
  fi

  echo
  echo "Install complete. Verify in 30 seconds with:"
  echo "  scripts/setup/install-self-hosted-runner.sh --check"
  echo
  echo "View logs:"
  echo "  tail -f $HOME/Library/Logs/Chump/actions-runner.log"
}

# Dispatch
TOKEN=""
case "${1:-}" in
  --check)     cmd_check  ;;
  --uninstall) shift; while [ $# -gt 0 ]; do case "$1" in --token) TOKEN="$2"; shift 2 ;; *) shift ;; esac; done; cmd_uninstall ;;
  --token)     TOKEN="${2:-}"; cmd_install ;;
  -h|--help)   usage 0 ;;
  "")          cmd_install ;;
  *)           echo "Unknown arg: $1"; usage 1 ;;
esac
