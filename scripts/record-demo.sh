#!/bin/bash
# Record a 3-minute CLI demo of Chump's golden path
# Requires: asciinema (https://asciinema.org)
# Install: brew install asciinema

set -eu

DEMO_DIR="${1:-.}"
TIMESTAMP=$(date +%Y-%m-%d-%H%M%S)
RECORDING="$DEMO_DIR/demo-$TIMESTAMP.cast"
LOG="$DEMO_DIR/demo-$TIMESTAMP.log"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Chump CLI Demo Recorder ===${NC}"
echo -e "${BLUE}Recording to: $RECORDING${NC}"
echo ""
echo "This script will record a ~3-minute interactive terminal session."
echo "The demo covers: install → init → task execution → result."
echo ""
echo "Make sure Chump is already installed (brew install chump or cargo install --path .)"
echo "Press ENTER to start recording when ready..."
read

# Record with asciinema
# -c specifies command to run, -t specifies title
asciinema rec \
  --title "Chump CLI Demo - 3-minute Golden Path" \
  --command "$DEMO_DIR/scripts/demo-golden-path.sh" \
  "$RECORDING"

echo ""
echo -e "${GREEN}✓ Recording saved: $RECORDING${NC}"
echo ""
echo "Next steps:"
echo "  1. Review the recording: asciinema play $RECORDING"
echo "  2. Upload to asciinema.org: asciinema upload $RECORDING"
echo "  3. Or self-host on GitHub Pages (see docs/DEMO_HOSTING.md)"
echo ""
echo "Recording metadata:"
asciinema cat "$RECORDING" | head -1 > "$LOG"
echo "  Saved to: $LOG"
