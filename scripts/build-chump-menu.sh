#!/usr/bin/env bash
# Build the Chump menu bar app and create ChumpMenu.app in ChumpMenu/.
# Requires: Xcode or swift (macOS 13+). Run from repo root or ChumpMenu/.

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ChumpMenu"
mkdir -p ChumpMenu.app/Contents/MacOS
echo "Building ChumpMenu..."
swift build -c release 2>&1
BIN="$ROOT/ChumpMenu/.build/release/ChumpMenu"
if [[ ! -f "$BIN" ]]; then
  echo "Binary not found at $BIN"
  exit 1
fi
cp "$BIN" ChumpMenu.app/Contents/MacOS/
cp "$ROOT/ChumpMenu/Info.plist" ChumpMenu.app/Contents/
touch ChumpMenu.app
echo "Done: $ROOT/ChumpMenu/ChumpMenu.app"
echo "Quit Chump Menu first (brain icon → Quit), then run the .app again."
echo "To set repo path: defaults write ai.openclaw.chump-menu ChumpRepoPath /path/to/rust-agent"
