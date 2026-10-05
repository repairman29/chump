#!/data/data/com.termux/files/usr/bin/bash
# Witness loop — RESILIENT-335/336. Runs the probe every 5 min.
# Installed by setup-pixel-node.sh into ~/witness/run.sh.
termux-wake-lock 2>/dev/null
while true; do python3 ~/witness/probe.py >/dev/null 2>>~/witness/run.err; sleep 300; done
