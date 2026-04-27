#!/usr/bin/env bash
# Run OCR on a screenshot or image. For Mabel on Pixel: screencap + tesseract so she can
# read screen text (notifications, foreground app) without a vision model.
#
# Usage (on Pixel / Termux):
#   bash scripts/setup/screen-ocr.sh [IMAGE_PATH]
# If IMAGE_PATH is omitted, tries to capture the screen to a temp file (requires root or
# Termux:API / system screencap). If IMAGE_PATH is given, runs tesseract on that file.
# Output: plain text to stdout.
#
# Requires: pkg install tesseract
# CHUMP_CLI_ALLOWLIST on Pixel should include: tesseract, bash (and screencap path if using no-arg form).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

IMG="${1:-}"

if [[ -z "$IMG" ]]; then
  # No arg: try to capture screen. On some devices /system/bin/screencap works without root.
  IMG="/data/data/com.termux/files/usr/tmp/screen-ocr-$$.png"
  mkdir -p "$(dirname "$IMG")"
  if ( unset LD_LIBRARY_PATH; /system/bin/screencap -p "$IMG" 2>/dev/null ); then
    :
  else
    echo "screen-ocr: no image path given and screencap failed (need root or Termux:API). Use: bash scripts/setup/screen-ocr.sh /path/to/image.png" >&2
    exit 1
  fi
  trap "rm -f '$IMG'" EXIT
fi

if [[ ! -f "$IMG" ]]; then
  echo "screen-ocr: file not found: $IMG" >&2
  exit 1
fi

# tesseract image stdout (no lang = default eng)
tesseract "$IMG" stdout 2>/dev/null || {
  echo "screen-ocr: tesseract failed. Install with: pkg install tesseract" >&2
  exit 1
}
