#!/data/data/com.termux/files/usr/bin/bash
# Pixel node boot hook — RESILIENT-336. Starts sshd + the node supervisor so
# the worker + witness self-restore after a reboot.
sshd
termux-wake-lock 2>/dev/null
nohup ~/pixel-node-supervisor.sh >> ~/pixel-supervisor.log 2>&1 &
