#!/bin/sh
# jlog — append one entry to the agent work journal.
#
# Journal: ~/workspace/agent-journal/journal.jsonl (override: JOURNAL_FILE).
# Append-only, one JSON object per line. Written under flock.
#
# Usage:
#   jlog start [--id ID] task="..." [brief="..."] [workdir="..."] [chat="..."]
#       Without --id, generates one and prints: JLOG_ID=<id>
#   jlog beat --id ID progress="..." [milestone="..."]
#   jlog done --id ID [summary="..."]
#   jlog fail --id ID error="..."
#   jlog show --id ID            # print all journal lines for an id
#
# Convention: the main agent writes `start` when delegating long work to a
# subagent (or a side chat). The worker writes `beat` per milestone (or every
# few minutes) and exactly one terminal entry (`done`/`fail`) at the end.
set -u

JOURNAL="${JOURNAL_FILE:-${HOME:-/home/hatch}/workspace/agent-journal/journal.jsonl}"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

json_escape() {
  # Escape \, ", tab; strip CR; fold newlines to \n. (GNU sed.)
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' \
    -e 's/\r//g' -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g'
}

[ $# -ge 1 ] || usage
kind="$1"; shift
case "$kind" in
  start|beat|done|fail|show) ;;
  -h|--help|help) usage ;;
  *) echo "jlog: unknown kind '$kind'" >&2; exit 2 ;;
esac

id=""; task=""; brief=""; workdir=""; chat=""; progress=""; milestone=""
summary=""; error=""
while [ $# -gt 0 ]; do
  case "$1" in
    --id)   [ $# -ge 2 ] || { echo "jlog: --id needs a value" >&2; exit 2; }; id="$2"; shift 2; continue ;;
    --id=*) id="${1#--id=}"; shift; continue ;;
    task=*)      task="${1#task=}" ;;
    brief=*)     brief="${1#brief=}" ;;
    workdir=*)   workdir="${1#workdir=}" ;;
    chat=*)      chat="${1#chat=}" ;;
    progress=*)  progress="${1#progress=}" ;;
    milestone=*) milestone="${1#milestone=}" ;;
    summary=*)   summary="${1#summary=}" ;;
    error=*)     error="${1#error=}" ;;
    *) echo "jlog: unknown arg '$1'" >&2; exit 2 ;;
  esac
  shift
done

if [ "$kind" = "show" ]; then
  [ -n "$id" ] || { echo "jlog show: --id required" >&2; exit 2; }
  [ -f "$JOURNAL" ] || exit 0
  # Parse as JSON (not grep): entries may be written by other tools with
  # different whitespace (e.g. python json.dumps uses `"id": "..."`).
  command -v python3 >/dev/null 2>&1 || { echo "jlog show: python3 not found" >&2; exit 2; }
  python3 - "$id" "$JOURNAL" <<'PYEOF'
import json, sys
jid, path = sys.argv[1], sys.argv[2]
for line in open(path, encoding="utf-8"):
    s = line.strip()
    if not s:
        continue
    try:
        e = json.loads(s)
    except Exception:
        continue
    if e.get("id") == jid:
        print(s)
PYEOF
  exit 0
fi

[ -n "$id" ] || {
  if [ "$kind" = "start" ]; then
    id="task-$(date +%Y%m%d-%H%M%S)-$$"
  else
    echo "jlog $kind: --id required" >&2; exit 2
  fi
}

case "$kind" in
  start) [ -n "$task" ] || { echo "jlog start: task=... required" >&2; exit 2; } ;;
  beat)  { [ -n "$progress" ] || [ -n "$milestone" ]; } || { echo "jlog beat: progress=... required" >&2; exit 2; } ;;
  fail)  [ -n "$error" ] || { echo "jlog fail: error=... required" >&2; exit 2; } ;;
esac

ts="$(date +%s)"
at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
e() { json_escape "$1"; }
line="{\"kind\":\"$kind\",\"id\":\"$(e "$id")\",\"ts\":$ts,\"at\":\"$at\""
[ -n "$task" ]     && line="$line,\"task\":\"$(e "$task")\""
[ -n "$brief" ]    && line="$line,\"brief\":\"$(e "$brief")\""
[ -n "$workdir" ]  && line="$line,\"workdir\":\"$(e "$workdir")\""
[ -n "$chat" ]     && line="$line,\"chat\":\"$(e "$chat")\""
[ -n "$progress" ] && line="$line,\"progress\":\"$(e "$progress")\""
[ -n "$milestone" ] && line="$line,\"milestone\":\"$(e "$milestone")\""
[ -n "$summary" ]  && line="$line,\"summary\":\"$(e "$summary")\""
[ -n "$error" ]    && line="$line,\"error\":\"$(e "$error")\""
line="$line}"

mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null
exec 9>>"$JOURNAL.lock"
if ! flock 9 2>/dev/null; then
  echo "jlog: cannot lock journal" >&2; exit 1
fi
printf '%s\n' "$line" >>"$JOURNAL"

if [ "$kind" = "start" ]; then
  echo "JLOG_ID=$id"
else
  echo "jlog: $kind $id" >&2
fi
