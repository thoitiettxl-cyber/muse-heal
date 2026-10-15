#!/bin/sh
# heal-agents.sh — detect agent work orphaned by a VM replace (or gone stale).
#
# Reads the work journal (~/workspace/agent-journal/journal.jsonl, override:
# JOURNAL_FILE). For every task whose last entry is not terminal (done/fail):
#   - orphaned: current boot time is NEWER than the task's last heartbeat.
#     The VM was replaced after the worker's last sign of life.
#   - stale:    no heartbeat for --stale-minutes (default 30) and no replace
#     detected. The worker may have died — or may just be slow/quiet.
#
# Read-only: never modifies the journal, so re-runs are identical.
#
# Usage: heal-agents [--json] [--stale-minutes N] [--boot-epoch EPOCH]
#   --boot-epoch is a test hook (simulates a fresh boot at EPOCH).
# Exit: 0 = clean, 1 = orphaned/stale found, 2 = usage/runtime error.
set -u

HOME_DIR="${HOME:-/home/hatch}"
JOURNAL="${JOURNAL_FILE:-$HOME_DIR/workspace/agent-journal/journal.jsonl}"
STALE_MIN=30
JSON_OUT=0
BOOT_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUT=1; shift ;;
    --stale-minutes) STALE_MIN="$2"; shift 2 ;;
    --stale-minutes=*) STALE_MIN="${1#--stale-minutes=}"; shift ;;
    --boot-epoch) BOOT_OVERRIDE="$2"; shift 2 ;;
    --boot-epoch=*) BOOT_OVERRIDE="${1#--boot-epoch=}"; shift ;;
    -h|--help|help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "heal-agents: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

case "$STALE_MIN" in ''|*[!0-9]*) echo "heal-agents: --stale-minutes must be a number" >&2; exit 2 ;; esac

if [ ! -f "$JOURNAL" ]; then
  if [ "$JSON_OUT" -eq 1 ]; then
    echo '{"orphaned":[],"stale":[],"summary":{"tracked":0,"terminal":0,"active":0,"orphaned":0,"stale":0}}'
  else
    echo "heal-agents: no journal yet ($JOURNAL) — nothing to check."
  fi
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { echo "heal-agents: python3 not found" >&2; exit 2; }

HA_JOURNAL="$JOURNAL" HA_STALE_MIN="$STALE_MIN" HA_JSON="$JSON_OUT" \
HA_BOOT_OVERRIDE="$BOOT_OVERRIDE" python3 - <<'PYEOF'
import json, os, sys, time, subprocess, datetime

journal = os.environ["HA_JOURNAL"]
stale_sec = int(os.environ["HA_STALE_MIN"]) * 60
want_json = os.environ["HA_JSON"] == "1"
boot_override = os.environ["HA_BOOT_OVERRIDE"].strip()

def boot_epoch():
    if boot_override:
        return int(boot_override), True
    try:
        out = subprocess.run(["uptime", "-s"], capture_output=True, text=True, timeout=10)
        s = out.stdout.strip()
        if s:
            dt = datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S").astimezone()
            return int(dt.timestamp()), False
    except Exception:
        pass
    try:
        with open("/proc/stat") as f:
            for line in f:
                if line.startswith("btime"):
                    return int(line.split()[1]), False
    except Exception:
        pass
    return None, False

def fmt(ts):
    try:
        return datetime.datetime.fromtimestamp(int(ts), datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    except Exception:
        return "?"

def age(ts, now):
    s = max(0, now - int(ts))
    if s < 90: return f"{s}s"
    m = s // 60
    if m < 90: return f"{m}m"
    return f"{m // 60}h{m % 60:02d}m"

tasks, order, bad = {}, [], 0
try:
    fh = open(journal, encoding="utf-8")
except OSError as e:
    print(f"heal-agents: cannot read journal: {e}", file=sys.stderr); sys.exit(2)
with fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            bad += 1; continue
        i, k = e.get("id"), e.get("kind")
        if not i or not isinstance(k, str):
            bad += 1; continue
        if i not in tasks:
            tasks[i] = {"id": i, "entries": []}; order.append(i)
        tasks[i]["entries"].append(e)

now = int(time.time())
boot, boot_fake = boot_epoch()
if boot is None:
    print("heal-agents: cannot determine boot time", file=sys.stderr); sys.exit(2)

orphaned, stale, n_terminal, n_active = [], [], 0, 0
for i in order:
    es = tasks[i]["entries"]
    terminal = None
    for e in es:
        if e.get("kind") in ("done", "fail"):
            terminal = e
    if terminal:
        n_terminal += 1
        continue
    first = next((e for e in es if e.get("kind") == "start"), es[0])
    beats = [e for e in es if e.get("kind") == "beat"]
    hb = max(beats, key=lambda e: int(e.get("ts") or 0)) if beats else None
    hb_ts = int((hb or first).get("ts") or 0)
    progress = ((hb or {}).get("progress") or (hb or {}).get("milestone") or "").strip()
    rec = {
        "id": i,
        "task": first.get("task") or "(no task description)",
        "workdir": first.get("workdir") or "",
        "brief": first.get("brief") or "",
        "chat": first.get("chat") or "",
        "started_at": fmt(first.get("ts")),
        "last_heartbeat_at": fmt(hb_ts),
        "heartbeat_age": age(hb_ts, now),
        "progress": progress,
    }
    if boot > hb_ts:
        rec["verdict"] = "orphaned"
        rec["cause"] = f"VM replace detected: boot {fmt(boot)} is newer than last heartbeat {fmt(hb_ts)}"
        orphaned.append(rec)
    elif now - hb_ts > stale_sec:
        rec["verdict"] = "stale"
        rec["cause"] = f"no heartbeat for {age(hb_ts, now)} (threshold {os.environ['HA_STALE_MIN']}m); no VM replace detected"
        stale.append(rec)
    else:
        n_active += 1

summary = {"tracked": len(order), "terminal": n_terminal, "active": n_active,
           "orphaned": len(orphaned), "stale": len(stale), "bad_lines": bad,
           "boot_epoch": boot, "boot_simulated": boot_fake}

if want_json:
    print(json.dumps({"orphaned": orphaned, "stale": stale, "summary": summary},
                     ensure_ascii=False, indent=1))
else:
    print(f"heal-agents: {len(orphaned)} orphaned, {len(stale)} stale "
          f"({summary['tracked']} tracked, {n_terminal} terminal, {n_active} active)"
          + (" [boot time SIMULATED for testing]" if boot_fake else ""))
    def show(rec):
        print(f"--- {rec['verdict'].upper()} {rec['id']}")
        print(f"  task:     {rec['task']}")
        if rec["workdir"]: print(f"  workdir:  {rec['workdir']}")
        if rec["brief"]:   print(f"  brief:    {rec['brief']}")
        if rec["chat"]:    print(f"  chat:     {rec['chat']}")
        print(f"  started:  {rec['started_at']}")
        print(f"  last beat:{rec['last_heartbeat_at']} ({rec['heartbeat_age']} ago)")
        if rec["progress"]: print(f"  progress: {rec['progress']}")
        print(f"  cause:    {rec['cause']}")
        print(f"  resume:   jlog show --id {rec['id']}  # full history, then re-spawn with context")
    for rec in orphaned + stale:
        show(rec)
    if bad:
        print(f"  WARNING: {bad} malformed journal line(s) were skipped — "
              f"those tasks are UNTRACKED and invisible to orphan detection!")

# Exit codes: 0 = clean, 1 = orphaned/stale work found, 2 = malformed lines
# (tasks may be silently lost). Malformed lines alone are a data-integrity
# failure even when no orphaned work is detected.
if orphaned or stale:
    sys.exit(1)
elif bad:
    sys.exit(2)
else:
    sys.exit(0)
PYEOF
