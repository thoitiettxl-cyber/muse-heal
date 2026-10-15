#!/bin/sh
# jrun — run a long command with automatic journal tracking.
#
# Usage: jrun [--beat N] [--id ID] -- <command> [args...]
#   --beat N : heartbeat interval in seconds (default 60)
#   --id ID  : reuse an existing journal id (default: new id via jlog start)
#
# Does `jlog start`, runs the command, beats every N seconds in the background,
# and traps EXIT/INT/TERM to record `jlog done` (exit 0) or `jlog fail`.
# For non-interactive long commands only (decompile, download, build...).
#
# The journal entry survives VM replace; heal-agents will flag the task as
# ORPHANED if the machine reboots mid-run without a terminal entry.
set -u

BEAT=60
ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --beat) [ $# -ge 2 ] || { echo "jrun: --beat needs seconds" >&2; exit 2; }; BEAT="$2"; shift 2; continue ;;
    --beat=*) BEAT="${1#--beat=}"; shift; continue ;;
    --id) [ $# -ge 2 ] || { echo "jrun: --id needs a value" >&2; exit 2; }; ID="$2"; shift 2; continue ;;
    --id=*) ID="${1#--id=}"; shift; continue ;;
    --) shift; break ;;
    -h|--help|help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { echo "jrun: no command given (usage: jrun -- <command> [args...])" >&2; exit 2; }
case "$BEAT" in ''|*[!0-9]*) echo "jrun: --beat must be a number" >&2; exit 2 ;; esac
[ "$BEAT" -ge 10 ] || { echo "jrun: --beat minimum is 10s" >&2; exit 2; }

JLOG="${HOME:-/home/hatch}/.local/bin/jlog"
[ -x "$JLOG" ] || JLOG="jlog"

# Start the journal entry (unless reusing an id).
if [ -z "$ID" ]; then
  # shellcheck disable=SC2086
  out="$($JLOG start task="jrun: $*" 2>&1)" || { echo "jrun: jlog start failed: $out" >&2; exit 1; }
  ID="$(printf '%s' "$out" | sed -n 's/^JLOG_ID=//p')"
  [ -n "$ID" ] || { echo "jrun: could not parse JLOG_ID from: $out" >&2; exit 1; }
  echo "jrun: tracking as $ID" >&2
fi

# Background heartbeat.
(
  while :; do
    sleep "$BEAT"
    "$JLOG" beat --id "$ID" progress="still running: $*" >/dev/null 2>&1
  done
) &
HEARTBEAT_PID=$!

# Ensure heartbeat dies and a terminal entry is recorded on any exit.
cleanup() {
  kill "$HEARTBEAT_PID" 2>/dev/null
  wait "$HEARTBEAT_PID" 2>/dev/null
}
trap 'cleanup' EXIT INT TERM

# Run the command.
"$@"
rc=$?

cleanup
trap - EXIT INT TERM

if [ "$rc" -eq 0 ]; then
  "$JLOG" done --id "$ID" summary="exit 0: $*" >/dev/null 2>&1
else
  "$JLOG" fail --id "$ID" error="exit $rc: $*" >/dev/null 2>&1
fi
exit "$rc"
