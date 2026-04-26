# Run battle QA without keeping a terminal open

## Option A: tmux (recommended)

Starts a detached session; survives terminal close. Reattach to watch.

```bash
cd /path/to/Chump   # or: cd "$CHUMP_HOME"
tmux new -s battle-qa -d './scripts/ci/run-battle-qa-full.sh; echo "Done at $(date)"; exec bash'
```

- Watch live: `tmux attach -t battle-qa`
- Detach (leave running): `Ctrl+b` then `d`
- Check: `tmux has-session -t battle-qa 2>/dev/null && echo Running || echo Done`

## Option B: launchd (runs fully in background, survives logout)

One-off job; runs when loaded, then exits. Logs go to `logs/battle-qa-launchd.log` and `logs/battle-qa-launchd.err`.

```bash
cd /path/to/Chump   # or: cd "$CHUMP_HOME"
mkdir -p ~/Library/LaunchAgents
cp scripts/plists/com.chump.battle-qa.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.chump.battle-qa.plist
```

- Results (when done): `logs/battle-qa-report.txt`, `logs/battle-qa-failures.txt`
- Unload so it doesn’t run again next login: `launchctl unload ~/Library/LaunchAgents/com.chump.battle-qa.plist`

Edit `scripts/plists/com.chump.battle-qa.plist` if your Chump path or username differs.
