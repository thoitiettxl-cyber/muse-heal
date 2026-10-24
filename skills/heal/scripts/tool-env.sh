# tool-env.sh — loader for tool shells, NOT a secrets file.
# This file contains code only, never secret values.
# It loads only `export VAR=` lines from the user's secrets file
# (~/workspace/.secrets/.bashrc) and from ~/.bashrc, so a non-interactive
# shell (muse.exec: /bin/bash --norc --noprofile -c) that sources this file
# via BASH_ENV, or a wrapper script that sources it, sees the API keys
# without the caller having to source any rc file. Values are never printed.
# Usage: BASH_ENV="$HOME/.config/heal/tool-env.sh" bash -c '...'
# Heal (heal.sh) writes this file to ~/.config/heal/tool-env.sh; this copy
# in the repo is the template heal.sh embeds, so the two must match.
for _tool_env_file in "$HOME/workspace/.secrets/.bashrc" "$HOME/.bashrc"; do
  if [ -r "$_tool_env_file" ]; then
    while IFS= read -r _tool_env_line || [ -n "$_tool_env_line" ]; do
      case "$_tool_env_line" in
        export\ [A-Za-z_]*=*) eval "$_tool_env_line" 2>/dev/null || true ;;
      esac
    done < "$_tool_env_file"
  fi
done
unset _tool_env_file _tool_env_line
# Lemo-Opuscar library location: the workspace clone, not a second ~/lemo-opuscar clone.
if [ -d "$HOME/workspace/lemo-opuscar/core/render" ]; then
  export LEMO_OPUSCAR_HOME="$HOME/workspace/lemo-opuscar"
fi
