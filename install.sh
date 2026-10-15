#!/bin/sh
# install.sh — install muse-heal into $HOME. Idempotent: safe to re-run.
#
# Installs:
#   ~/workspace/heal/heal.sh, heal-agents.sh, jrun.sh
#   ~/workspace/agent-journal/jlog.sh (+ briefs/)
#   ~/.local/bin/{heal,heal-agents,jlog,jrun} symlinks
#   login-shell hook (# >>> heal) in ~/.bashrc and ~/.profile
# Then runs `heal` once to verify.
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${HOME:-/home/hatch}"

mkdir -p "$HOME_DIR/workspace/heal" \
         "$HOME_DIR/workspace/agent-journal/briefs" \
         "$HOME_DIR/.local/bin" \
         "$HOME_DIR/.config/heal" \
         "$HOME_DIR/workspace/logs"

for f in heal.sh heal-agents.sh jrun.sh; do
  cp "$REPO/$f" "$HOME_DIR/workspace/heal/$f"
  chmod +x "$HOME_DIR/workspace/heal/$f"
done
cp "$REPO/jlog.sh" "$HOME_DIR/workspace/agent-journal/jlog.sh"
chmod +x "$HOME_DIR/workspace/agent-journal/jlog.sh"

ln -sfn "$HOME_DIR/workspace/heal/heal.sh" "$HOME_DIR/.local/bin/heal"
ln -sfn "$HOME_DIR/workspace/heal/heal-agents.sh" "$HOME_DIR/.local/bin/heal-agents"
ln -sfn "$HOME_DIR/workspace/agent-journal/jlog.sh" "$HOME_DIR/.local/bin/jlog"
ln -sfn "$HOME_DIR/workspace/heal/jrun.sh" "$HOME_DIR/.local/bin/jrun"

# Login-shell hook: installed/upgraded by `heal` check #11 (run below) — the hook
# text lives only in heal.sh, so install.sh can never drift from it again.

# Optional: node reinstall cache (used by heal.sh if base-image node goes missing).
# Pre-download once: ~/.cache/heal/node-v24.20.0-linux-x64.tar.xz
#   curl -sSLO --max-time 140 https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-x64.tar.xz

echo "installed. Verifying:"
"$HOME_DIR/.local/bin/heal" fix manual
