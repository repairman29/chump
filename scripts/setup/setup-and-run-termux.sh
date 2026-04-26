#!/data/data/com.termux/files/usr/bin/bash
# One-shot: copy chump + .env to ~/chump and start companion. Run from Termux or via RUN_COMMAND.
# Use the directory where this script lives (works from ~/storage/downloads/chump or /sdcard/Download/chump).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
mkdir -p ~/chump/sessions ~/chump/logs
cp "$SCRIPT_DIR/chump" "$SCRIPT_DIR/start-companion.sh" "$SCRIPT_DIR/.env" ~/chump/
[[ -f "$SCRIPT_DIR/setup-llama-on-termux.sh" ]] && cp "$SCRIPT_DIR/setup-llama-on-termux.sh" ~/chump/ && chmod +x ~/chump/setup-llama-on-termux.sh
[[ -f "$SCRIPT_DIR/setup-termux-once.sh" ]] && cp "$SCRIPT_DIR/setup-termux-once.sh" ~/chump/ && chmod +x ~/chump/setup-termux-once.sh
[[ -f "$SCRIPT_DIR/apply-mabel-badass-env.sh" ]] && cp "$SCRIPT_DIR/apply-mabel-badass-env.sh" ~/chump/ && chmod +x ~/chump/apply-mabel-badass-env.sh
chmod +x ~/chump/chump ~/chump/start-companion.sh
cd ~/chump && exec ./start-companion.sh
