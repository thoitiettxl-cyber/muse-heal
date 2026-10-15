#!/bin/sh
# jrun — run a long command with automatic journal tracking.
#
# Usage: jrun [--beat N] [--id ID] [--label TEXT] -- <command> [args...]
#   --beat N     : heartbeat interval in seconds (default 60, minimum 10)
#   --id ID      : reuse an existing journal id (default: new id via jlog start)
#   --label TEXT : human description for the journal (default: command name)
#
# Journals only the command NAME (basename of argv[0]) or --label — NEVER the
# arguments, which may carry secrets (tokens, passwords, URLs with keys).
#
# Records `start`; a heartbeat every N seconds for as long as jrun itself is
# alive; and exactly one terminal entry: `done` (exit 0) or `fail` (non-zero
# exit, or jrun/command killed by INT/TERM/HUP).
# SIGKILL cannot be trapped, so kill -9 leaves no terminal entry — but the
# heartbeat dies with jrun, so heal-agents reports the task as stale/orphaned
# instead of showing it as active forever.
# For non-interactive long commands (decompile, download, build...).
set -u

BEAT=60
ID=""
LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --beat) [ $# -ge 2 ] || { echo "jrun: --beat needs seconds" >&2; exit 2; }; BEAT="$2"; shift 2; continue ;;
    --beat=*) BEAT="${1#--beat=}"; shift; continue ;;
    --id) [ $# -ge 2 ] || { echo "jrun: --id needs a value" >&2; exit 2; }; ID="$2"; shift 2; continue ;;
    --id=*) ID="${1#--id=}"; shift; continue ;;
    --label) [ $# -ge 2 ] || { echo "jrun: --label needs a value" >&2; exit 2; }; LABEL="$2"; shift 2; continue ;;
    --label=*) LABEL="${1#--label=}"; shift; continue ;;
    --) shift; break ;;
    -h|--help|help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { echo "jrun: no command given (usage: jrun -- <command> [args...])" >&2; exit 2; }
case "$BEAT" in ''|*[!0-9]*) echo "jrun: --beat must be a number" >&2; exit 2 ;; esac
[ "$BEAT" -ge 10 ] || { echo "jrun: --beat minimum is 10s" >&2; exit 2; }

NAME="${LABEL:-$(basename "$1")}"

JLOG="${HOME:-/home/hatch}/.local/bin/jlog"
[ -x "$JLOG" ] || JLOG="jlog"

if [ -z "$ID" ]; then
  out="$("$JLOG" start task="jrun: $NAME" 2>&1)" || { echo "jrun: jlog start failed: $out" >&2; exit 1; }
  ID="$(printf '%s' "$out" | sed -n 's/^JLOG_ID=//p')"
  [ -n "$ID" ] || { echo "jrun: could not parse JLOG_ID from: $out" >&2; exit 1; }
  echo "jrun: tracking as $ID" >&2
fi

# Async children of a non-interactive shell get stdin=/dev/null *before* any
# explicit `<&0` is applied, so stash the real stdin on fd 3 and hand it over from there.
# (If stdin is closed there is nothing to stash; the child then gets /dev/null.)
HAVE_STDIN=0
# (/proc check: a bare `<&0` on a closed fd aborts dash.)
if [ ! -d "/proc/$$" ] || [ -e "/proc/$$/fd/0" ]; then exec 3<&0; HAVE_STDIN=1; fi

T0="$(date +%s)"
PARENT=$$
CPID=""
HB_PID=""
FINISHED=0

# Heartbeat: beats only while jrun (PARENT) is alive and not a zombie, so a
# SIGKILLed jrun cannot leave a loop behind that fakes liveness.
(
  alive() {
    kill -0 "$PARENT" 2>/dev/null || return 1
    ! grep -q '^State:[[:space:]]*Z' "/proc/$PARENT/status" 2>/dev/null
  }
  while :; do
    sleep "$BEAT"
    alive || exit 0
    "$JLOG" beat --id "$ID" progress="still running ($(( $(date +%s) - T0 ))s): $NAME" >/dev/null 2>&1
  done
) 3<&- &
HB_PID=$!

# Write the single terminal entry; idempotent (guarded by FINISHED).
finish() {  # $1 = exit code, $2 = optional note
  [ "$FINISHED" -eq 0 ] || return 0
  FINISHED=1
  [ -n "$HB_PID" ] && { kill "$HB_PID" 2>/dev/null; wait "$HB_PID" 2>/dev/null; }
  el=$(( $(date +%s) - T0 ))
  if [ "$1" -eq 0 ]; then
    "$JLOG" done --id "$ID" summary="exit 0 after ${el}s: $NAME" >/dev/null 2>&1
  else
    "$JLOG" fail --id "$ID" error="${2:-exit $1} after ${el}s: $NAME" >/dev/null 2>&1
  fi
}

# True once the child has exited (it stays a zombie until we `wait` on it).
child_gone() {
  [ -d "/proc/$CPID" ] || return 0
  grep -q '^State:[[:space:]]*Z' "/proc/$CPID/status" 2>/dev/null
}

on_signal() {  # $1 = signal name, $2 = conventional exit code
  trap '' INT TERM HUP
  if [ -n "$CPID" ]; then
    # Always TERM the child (never forward INT: a background child of a
    # non-interactive shell has SIGINT ignored, so INT would not stop it).
    # Escalate to KILL after 5s so jrun can never hang on a stubborn command.
    # (Polling, not a watchdog subshell: no stray process, no PID-reuse risk.)
    kill -TERM "$CPID" 2>/dev/null
    n=0
    while ! child_gone && [ "$n" -lt 5 ]; do sleep 1; n=$((n + 1)); done
    child_gone || kill -KILL "$CPID" 2>/dev/null
    wait "$CPID" 2>/dev/null
  fi
  finish "$2" "killed by SIG$1"
  exit "$2"
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_signal HUP 129' HUP
trap 'rc=$?; finish "$rc" "jrun exited early"' EXIT

# Run the command as a child and `wait`, so trapped signals are handled
# immediately instead of after the command ends. Stdin comes from fd 3 (see above).
if [ "$HAVE_STDIN" -eq 1 ]; then
  "$@" 0<&3 3<&- &
  CPID=$!
  exec 3<&-
else
  "$@" &
  CPID=$!
fi
wait "$CPID"
rc=$?
finish "$rc"
exit "$rc"
