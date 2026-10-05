#!/bin/bash
# Runs INSIDE proot-distro debian. Args: <CWD> [claude args...]
# Provides subscription OAuth + the chump/gh/git ship toolchain env, then
# execs the glibc claude build. env does NOT cross the proot boundary, so
# every var the ship path needs is re-established here.
CWD="$1"; shift
cd "$CWD" || { echo "[claude-proot-guest] cannot cd $CWD" >&2; exit 97; }
export PATH="$HOME/.local/bin:$PATH"
export IS_SANDBOX=1
unset ANTHROPIC_API_KEY
# chump ship toolchain env
export CHUMP_NODE_DIR=/data/data/com.termux/files/home/.chumpnode
export CHUMP_STATE_DIR=/data/data/com.termux/files/home/.chump
export CHUMP_REPO=/data/data/com.termux/files/home/chump-repo
export CHUMP_HOME=/data/data/com.termux/files/home/chump
export CHUMP_BIN=/data/data/com.termux/files/home/chump/chump
export CHUMP_WORKTREE_BASE=/data/data/com.termux/files/usr/tmp
# gh reads $HOME/.config/gh by default; inside proot HOME=/root, so point it
# at the Termux node config (bound, visible) — this is how the node is authed.
export GH_CONFIG_DIR=/data/data/com.termux/files/home/.config/gh
# git identity: HOME=/root here does not see the node global gitconfig.
export GIT_AUTHOR_NAME=pixel-worker GIT_AUTHOR_EMAIL=pixel-worker@chump.bot
export GIT_COMMITTER_NAME=pixel-worker GIT_COMMITTER_EMAIL=pixel-worker@chump.bot
# Subscription OAuth token, read fresh from the refresher file each spawn.
export CLAUDE_CODE_OAUTH_TOKEN="$(python3 -c "import json;print(json.load(open(\"/data/data/com.termux/files/home/.chump/oauth-token.json\"))[\"token\"])")"
exec claude "$@"
