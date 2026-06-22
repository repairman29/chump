#!/usr/bin/env bash
# install-self-hosted-runner-pi.sh — INFRA-1543
#
# Provisions a GitHub Actions self-hosted runner on a Raspberry Pi (Linux ARM64),
# registers it with labels [self-hosted, Linux, ARM64, linux-arm64, chump-fleet-pi],
# and configures it as a systemd service so it survives reboots.
#
# Offline/air-gapped path: on first run the tarball is downloaded and cached at
# $CHUMP_PI_TARBALL_CACHE (default: ~/.cache/chump-runner/pi-tarball/). Subsequent
# Pi registrations use the cached tarball — no internet required after the first node.
#
# Usage:
#   scripts/setup/install-self-hosted-runner-pi.sh                  # interactive install
#   scripts/setup/install-self-hosted-runner-pi.sh --check          # verify registered + online; exit 0/1
#   scripts/setup/install-self-hosted-runner-pi.sh --uninstall      # remove cleanly
#   scripts/setup/install-self-hosted-runner-pi.sh --token TOKEN    # non-interactive with explicit token
#   scripts/setup/install-self-hosted-runner-pi.sh --cache-only     # download tarball to cache, don't install
#   scripts/setup/install-self-hosted-runner-pi.sh --from-cache DIR # install using cached tarball from DIR
#
# Idempotent: re-running does nothing if a healthy runner is already registered.
#
# Rack-and-register flow: docs/process/SELF_HOSTED_RUNNERS.md § Pi mesh
#
# Rust-First-Bypass: install wrapper around the upstream GitHub actions-runner
# tarball; pure shell glue around curl + tar + systemctl + gh api; no state
# mutation outside $RUNNER_DIR or $CHUMP_PI_TARBALL_CACHE. Per META-064 shell-OK.

set -euo pipefail

REPO_OWNER="${CHUMP_REPO_OWNER:-repairman29}"
REPO_NAME="${CHUMP_REPO_NAME:-chump}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-chump-pi}"
RUNNER_NAME_DEFAULT="pi-$(hostname -s | tr '[:upper:]' '[:lower:]')"
RUNNER_NAME="${RUNNER_NAME:-$RUNNER_NAME_DEFAULT}"
# AC #3: required labels
RUNNER_LABELS_DEFAULT="self-hosted,Linux,ARM64,linux-arm64,chump-fleet-pi"
RUNNER_LABELS="${RUNNER_LABELS:-$RUNNER_LABELS_DEFAULT}"

# AC #4: offline-air-gapped install path — cache the tarball once
CHUMP_PI_TARBALL_CACHE="${CHUMP_PI_TARBALL_CACHE:-$HOME/.cache/chump-runner/pi-tarball}"

# Systemd service name
SYSTEMD_SERVICE="chump-actions-runner-pi"
SYSTEMD_UNIT_FILE="/etc/systemd/system/${SYSTEMD_SERVICE}.service"

# PATH for the runner environment; includes common Rust install locations
RUNNER_RUSTUP_HOST_BIN="$HOME/.rustup/toolchains/stable-aarch64-unknown-linux-gnu/bin"
RUNNER_PATH_DEFAULT="$HOME/.cargo/bin:$RUNNER_RUSTUP_HOST_BIN:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
RUNNER_PATH="${RUNNER_PATH:-$RUNNER_PATH_DEFAULT}"

LATEST_VERSION_URL="https://api.github.com/repos/actions/runner/releases/latest"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

assert_linux_arm64() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  if [ "$os" != "Linux" ]; then
    die "This script is for Linux only (detected: $os). Use install-self-hosted-runner.sh for macOS."
  fi
  if [ "$arch" != "aarch64" ] && [ "$arch" != "arm64" ]; then
    die "This script targets ARM64 only (detected: $arch). Use install-self-hosted-runner.sh for x86_64."
  fi
}

assert_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemd not found. This installer requires a systemd-based Linux distro (Raspberry Pi OS, Ubuntu)."
  fi
}

cmd_check() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "FAIL: gh CLI not installed"
    exit 1
  fi
  local online linux_arm64_online
  online=$(gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
    --jq '.runners[] | select(.status=="online") | .name' 2>/dev/null | wc -l | tr -d ' ')
  linux_arm64_online=$(gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
    --jq '.runners[] | select(.status=="online") | select(.labels[].name == "linux-arm64") | .name' \
    2>/dev/null | wc -l | tr -d ' ')

  if [ "$linux_arm64_online" -lt 1 ]; then
    echo "FAIL: no online linux-arm64 runners for $REPO_OWNER/$REPO_NAME"
    echo "  Total online: $online (none have linux-arm64 label)"
    echo "Hint: run this script on a Pi to register one."
    exit 1
  fi

  echo "OK: $linux_arm64_online linux-arm64 runner(s) online for $REPO_OWNER/$REPO_NAME"
  gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
    --jq '.runners[] | select(.labels[].name == "linux-arm64") |
          "  - \(.name) [\(.status)] labels=\(.labels | map(.name) | join(","))"' 2>/dev/null
}

resolve_tarball() {
  # Returns the tarball path; downloads if not cached.
  # Output: path to .tar.gz (may be in CHUMP_PI_TARBALL_CACHE)
  local force_version="${1:-}"
  local version tarball_name tarball_path tarball_url

  mkdir -p "$CHUMP_PI_TARBALL_CACHE"

  if [ -n "$force_version" ]; then
    version="$force_version"
  else
    echo "Fetching latest actions-runner version from GitHub..." >&2
    version=$(curl -fsSL "$LATEST_VERSION_URL" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')
  fi

  tarball_name="actions-runner-linux-arm64-${version}.tar.gz"
  tarball_path="$CHUMP_PI_TARBALL_CACHE/$tarball_name"

  if [ -f "$tarball_path" ]; then
    echo "Using cached tarball: $tarball_path" >&2
  else
    tarball_url="https://github.com/actions/runner/releases/download/v${version}/${tarball_name}"
    echo "Downloading: $tarball_url" >&2
    echo "Caching to: $tarball_path" >&2
    curl -fsSL -o "$tarball_path" "$tarball_url"
    echo "Download complete. Future Pi installs will use this cached tarball." >&2
  fi

  echo "$tarball_path"
}

cmd_cache_only() {
  assert_linux_arm64
  local tarball_path
  tarball_path=$(resolve_tarball)
  echo "Tarball cached at: $tarball_path"
  echo "Copy this to new Pi nodes for air-gapped install:"
  echo "  scp $tarball_path pi@<new-pi>:~/runner.tar.gz"
  echo "  CHUMP_PI_TARBALL_CACHE=~/runner-cache scripts/setup/install-self-hosted-runner-pi.sh"
  exit 0
}

ensure_registration_token() {
  if [ -n "${TOKEN:-}" ]; then
    return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    echo "Fetching registration token from GitHub API..."
    TOKEN=$(gh api -X POST "/repos/$REPO_OWNER/$REPO_NAME/actions/runners/registration-token" \
      --jq '.token' 2>/dev/null || true)
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
}

emit_ambient() {
  local kind="$1" msg="${2:-}"
  local repo_root ambient
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME")"
  ambient="$repo_root/.chump-locks/ambient.jsonl"
  mkdir -p "$(dirname "$ambient")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"%s","host":"%s","msg":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$(hostname -s 2>/dev/null || echo unknown)" "$msg" \
    >> "$ambient" 2>/dev/null || true
}

install_systemd_service() {
  # Write and enable the systemd unit. Requires sudo.
  local runner_dir="$1" runner_user
  runner_user="$(id -un)"

  # Build the service file content
  local unit_content
  unit_content="$(cat <<EOF
[Unit]
Description=Chump GitHub Actions Self-Hosted Runner (Pi mesh)
After=network.target

[Service]
Type=simple
User=$runner_user
WorkingDirectory=$runner_dir
ExecStart=$runner_dir/run.sh
Restart=always
RestartSec=10
Environment=PATH=$RUNNER_PATH
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SYSTEMD_SERVICE

[Install]
WantedBy=multi-user.target
EOF
)"

  if [ -w "$(dirname "$SYSTEMD_UNIT_FILE")" ] || [ -w "$SYSTEMD_UNIT_FILE" ] 2>/dev/null; then
    # Running as root or unit dir is writable (unlikely but check)
    printf '%s\n' "$unit_content" > "$SYSTEMD_UNIT_FILE"
  else
    # Need sudo
    printf '%s\n' "$unit_content" | sudo tee "$SYSTEMD_UNIT_FILE" > /dev/null
  fi

  sudo systemctl daemon-reload
  sudo systemctl enable --now "$SYSTEMD_SERVICE"
  echo "systemd service installed and started: $SYSTEMD_SERVICE"
  echo "  Status: sudo systemctl status $SYSTEMD_SERVICE"
  echo "  Logs:   sudo journalctl -u $SYSTEMD_SERVICE -f"
}

cmd_install() {
  assert_linux_arm64
  assert_systemd

  # 0. Idempotency: skip if already configured
  if [ -d "$RUNNER_DIR" ] && [ -f "$RUNNER_DIR/.runner" ]; then
    echo "Runner already configured at $RUNNER_DIR — re-running is a no-op."
    echo "Use --uninstall to remove or --check to verify."
    exit 0
  fi

  # 1. Registration token
  ensure_registration_token

  # 2. Resolve tarball (cache or download)
  local tarball_path
  if [ -n "${FROM_CACHE_DIR:-}" ]; then
    # Air-gapped: user pointed at a pre-downloaded tarball directory
    local cached_tarballs
    cached_tarballs=$(find "$FROM_CACHE_DIR" -name "actions-runner-linux-arm64-*.tar.gz" 2>/dev/null | sort -V | tail -1 || true)
    if [ -z "$cached_tarballs" ]; then
      die "No actions-runner-linux-arm64-*.tar.gz found in $FROM_CACHE_DIR"
    fi
    tarball_path="$cached_tarballs"
    echo "Air-gapped install: using $tarball_path"
  else
    tarball_path=$(resolve_tarball)
  fi

  # 3. Extract
  mkdir -p "$RUNNER_DIR"
  cd "$RUNNER_DIR"
  echo "Extracting runner..."
  tar xzf "$tarball_path"

  # 4. Configure (non-interactive)
  echo "Registering runner $RUNNER_NAME with labels $RUNNER_LABELS..."
  ./config.sh \
    --url "https://github.com/$REPO_OWNER/$REPO_NAME" \
    --token "$TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --work "_work" \
    --unattended \
    --replace

  # 5. Install as systemd service
  install_systemd_service "$RUNNER_DIR"

  emit_ambient "pi_runner_installed" "name=$RUNNER_NAME labels=$RUNNER_LABELS"

  echo
  echo "Pi runner install complete."
  echo "Verify in 30 seconds:"
  echo "  scripts/setup/install-self-hosted-runner-pi.sh --check"
}

cmd_uninstall() {
  assert_systemd
  if systemctl is-active --quiet "$SYSTEMD_SERVICE" 2>/dev/null; then
    sudo systemctl stop "$SYSTEMD_SERVICE" || true
  fi
  if systemctl is-enabled --quiet "$SYSTEMD_SERVICE" 2>/dev/null; then
    sudo systemctl disable "$SYSTEMD_SERVICE" || true
  fi
  if [ -f "$SYSTEMD_UNIT_FILE" ]; then
    sudo rm -f "$SYSTEMD_UNIT_FILE"
    sudo systemctl daemon-reload
    echo "Removed systemd unit $SYSTEMD_UNIT_FILE"
  fi
  if [ -d "$RUNNER_DIR" ]; then
    if [ -x "$RUNNER_DIR/config.sh" ] && [ -n "${TOKEN:-}" ]; then
      (cd "$RUNNER_DIR" && ./config.sh remove --token "$TOKEN") || true
    fi
    rm -rf "$RUNNER_DIR"
    echo "Removed runner directory $RUNNER_DIR"
  fi
  echo "Uninstall complete."
}

# Dispatch
TOKEN=""
FROM_CACHE_DIR=""

for a in "$@"; do
  case "$a" in
    --token)       : ;;  # handled in arg parse below
    --from-cache)  : ;;
    *)             : ;;
  esac
done

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --check)        cmd_check; exit $? ;;
      --uninstall)    shift
                      while [ $# -gt 0 ]; do
                        case "$1" in --token) TOKEN="$2"; shift 2 ;; *) shift ;; esac
                      done
                      cmd_uninstall; exit $? ;;
      --cache-only)   cmd_cache_only; exit $? ;;
      --from-cache)   FROM_CACHE_DIR="${2:?'--from-cache requires a directory path'}"; shift 2 ;;
      --token)        TOKEN="${2:?'--token requires a value'}"; shift 2 ;;
      -h|--help)      usage 0 ;;
      "")             shift ;;
      *)              echo "Unknown arg: $1"; usage 1 ;;
    esac
  done
}

parse_args "$@"
cmd_install
