#!/bin/sh
# install.sh — install muse-heal into $HOME. Idempotent: safe to re-run.
#
# Installs:
#   ~/workspace/heal/heal.sh, heal-agents.sh
#   ~/workspace/agent-journal/jlog.sh (+ briefs/)
#   ~/.local/bin/{heal,heal-agents,jlog} symlinks
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

for f in heal.sh heal-agents.sh; do
  cp "$REPO/$f" "$HOME_DIR/workspace/heal/$f"
  chmod +x "$HOME_DIR/workspace/heal/$f"
done
cp "$REPO/jlog.sh" "$HOME_DIR/workspace/agent-journal/jlog.sh"
chmod +x "$HOME_DIR/workspace/agent-journal/jlog.sh"

ln -sfn "$HOME_DIR/workspace/heal/heal.sh" "$HOME_DIR/.local/bin/heal"
ln -sfn "$HOME_DIR/workspace/heal/heal-agents.sh" "$HOME_DIR/.local/bin/heal-agents"
ln -sfn "$HOME_DIR/workspace/agent-journal/jlog.sh" "$HOME_DIR/.local/bin/jlog"

# Login-shell hook (background self-heal, silent when healthy, throttled).
# Installed in BOTH ~/.bashrc (interactive) and ~/.profile (login shells).
for rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.profile"; do
  [ -f "$rc" ] || continue
  if ! grep -q '# >>> heal' "$rc" 2>/dev/null; then
    cat >>"$rc" <<'HEAL_HOOK_EOF'

# >>> heal: background self-heal on new shells (silent when healthy). Managed by heal.sh — see ~/workspace/logs/heal.log
if [ -x "$HOME/workspace/heal/heal.sh" ]; then
  _heal_now="$(date +%s 2>/dev/null || echo 0)"
  _heal_last="$(cat "$HOME/.config/heal/last-auto" 2>/dev/null || echo 0)"
  case "$_heal_last" in ''|*[!0-9]*) _heal_last=0 ;; esac
  if [ "$_heal_now" -ge "$((_heal_last + 300))" ]; then
    echo "$_heal_now" >"$HOME/.config/heal/last-auto" 2>/dev/null
    ( HEAL_QUIET=1 "$HOME/workspace/heal/heal.sh" fix login >>"$HOME/workspace/logs/heal.log" 2>&1 & )
  fi
  unset _heal_now _heal_last
fi
# <<< heal
HEAL_HOOK_EOF
    echo "hook added to $rc"
  fi
done

# Optional: node reinstall cache (used by heal.sh if base-image node goes missing).
# Pre-download once: ~/.cache/heal/node-v24.20.0-linux-x64.tar.xz
#   curl -sSLO --max-time 140 https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-x64.tar.xz

echo "installed. Verifying:"
"$HOME_DIR/.local/bin/heal" fix manual
