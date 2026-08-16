#!/data/data/com.termux/files/usr/bin/bash
sshd
termux-wake-lock 2>/dev/null
nohup ~/witness/run.sh >/dev/null 2>&1 &
