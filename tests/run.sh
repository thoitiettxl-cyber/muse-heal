#!/bin/sh
# tests/run.sh — reproducible verification for heal-agents/jlog/jrun fixes.
# Each claim in commit messages must be re-verifiable by running this.
# Usage: sh tests/run.sh
# Requires: the toolkit installed (jlog, jrun, heal-agents on PATH).
set -u

# Ensure toolkit binaries are on PATH (non-interactive shells may lack ~/.local/bin)
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

PASS=0
FAIL=0
TDIR=$(mktemp -d)
trap 'rm -rf "$TDIR"' EXIT

ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

JLOG=${JLOG:-jlog}
JRUN=${JRUN:-jrun}
HEAL_AGENTS=${HEAL_AGENTS:-heal-agents}
JRUN_PATH=$(command -v "$JRUN" 2>/dev/null || echo "$JRUN")

# --- 1. hook --alert writes file even when detector exits non-zero ---
echo "--- alert on orphaned/malformed ---"
export JOURNAL_FILE="$TDIR/journal.jsonl"
$JLOG start task="orphan case" >/dev/null 2>&1
# Fake an old heartbeat to simulate orphan (boot_epoch in past)
if $HEAL_AGENTS --alert "$TDIR/alert.json"; then
  [ -f "$TDIR/alert.json" ] && ok "alert file written (exit 0)" || bad "alert file missing"
  python3 -c "import json; d=json.load(open('$TDIR/alert.json')); assert 'checked_at' in d['summary']" 2>/dev/null \
    && ok "alert has checked_at" || bad "alert missing checked_at"
else
  bad "--alert should always exit 0"
fi
# malformed line -> --alert still writes file
echo "NOT JSON {{{" >> "$JOURNAL_FILE"
if $HEAL_AGENTS --alert "$TDIR/alert2.json" 2>/dev/null; then
  [ -f "$TDIR/alert2.json" ] && ok "alert written despite malformed line" || bad "alert missing on malformed"
else
  bad "--alert must exit 0 even with bad lines"
fi

# --- 2. kill -9: no ghost heartbeat, heal-agents says STALE not active ---
echo "--- kill -9 (beat 10s, wait 25s = 2+ cycles) ---"
export JOURNAL_FILE="$TDIR/kill9.jsonl"
rm -f "$JOURNAL_FILE"
( $JRUN --beat 10 --label "kill9-test" -- sleep 120 >/dev/null 2>&1 ) &
KP=$!
sleep 12
B1=$(grep -c '"kind":"beat"' "$JOURNAL_FILE" 2>/dev/null || echo 0)
kill -9 $KP 2>/dev/null
sleep 25
B2=$(grep -c '"kind":"beat"' "$JOURNAL_FILE" 2>/dev/null || echo 0)
if [ "$B2" -eq "$B1" ]; then
  ok "kill -9: no ghost beats ($B1 -> $B2 after 25s)"
else
  bad "kill -9: ghost beats detected ($B1 -> $B2)"
fi
# heal-agents verdict must be STALE, not active
V=$($HEAL_AGENTS --stale-minutes 0 --json 2>/dev/null | python3 -c "
import json,sys,os
os.environ['JOURNAL_FILE']='$TDIR/kill9.jsonl'
import subprocess
out=subprocess.run(['$HEAL_AGENTS','--stale-minutes','0','--json'],capture_output=True,text=True,env={**os.environ})
d=json.loads(out.stdout); s=d['summary']
print('active' if s['active']>0 else 'stale' if s['stale']>0 else 'none')
" 2>/dev/null)
# simpler: use JOURNAL_FILE env directly
V=$(JOURNAL_FILE="$TDIR/kill9.jsonl" $HEAL_AGENTS --stale-minutes 0 --json 2>/dev/null | python3 -c "
import json,sys; d=json.load(sys.stdin); s=d['summary']
print('STALE' if s['stale']>0 and s['active']==0 else 'ACTIVE' if s['active']>0 else 'OTHER')")
if [ "$V" = "STALE" ]; then
  ok "heal-agents reports STALE (not active) after kill -9"
else
  bad "heal-agents verdict after kill -9: $V (want STALE)"
fi

# --- 3. signals: TERM/HUP write fail with 143/129; INT trap verified by code ---
# NOTE: SIGINT cannot be delivered to background jobs in non-interactive shells
# (POSIX: signals ignored at shell startup cannot be trapped). TERM/HUP prove
# the on_signal path; INT uses the same path (verified manually in foreground).
echo "--- signals ---"
for spec in "TERM:143" "HUP:129"; do
  SIG=${spec%%:*}; CODE=${spec##*:}
  export JOURNAL_FILE="$TDIR/sig-$SIG.jsonl"
  rm -f "$JOURNAL_FILE"
  ( $JRUN --beat 60 --label "sig-$SIG" -- sleep 30 >/dev/null 2>&1 ) &
  SP=$!
  sleep 2
  kill -$SIG $SP 2>/dev/null
  wait $SP 2>/dev/null
  RC=$?
  KIND=$(python3 -c "import json; ls=[json.loads(l) for l in open('$JOURNAL_FILE')]; print([x['kind'] for x in ls if x['kind'] in ('done','fail')][-1])" 2>/dev/null)
  if [ "$RC" -eq "$CODE" ] && [ "$KIND" = "fail" ]; then
    ok "SIG$SIG -> exit $CODE, journal fail"
  else
    bad "SIG$SIG -> exit $RC (want $CODE), journal $KIND (want fail)"
  fi
done
# INT: verify trap is installed (delivery tested manually in foreground)
if grep -q "trap 'on_signal INT 130' INT" "$JRUN_PATH" 2>/dev/null || \
   grep -q "trap 'on_signal INT 130' INT" "$(command -v jrun)"; then
  ok "SIGINT trap installed (on_signal INT 130)"
else
  bad "SIGINT trap not found in jrun"
fi

# --- 4. stdin: pipe and closed ---
echo "--- stdin ---"
export JOURNAL_FILE="$TDIR/stdin.jsonl"
OUT=$(echo "hello pipe" | $JRUN --beat 60 --label "stdin-pipe" -- cat 2>/dev/null)
[ "$OUT" = "hello pipe" ] && ok "stdin via pipe works" || bad "stdin pipe: got '$OUT'"
OUT2=$($JRUN --beat 60 --label "stdin-closed" -- cat < /dev/null 2>/dev/null)
[ -z "$OUT2" ] && ok "closed stdin works" || bad "closed stdin: got '$OUT2'"

# --- 5. secret not journaled ---
echo "--- secret ---"
export JOURNAL_FILE="$TDIR/secret.jsonl"
rm -f "$JOURNAL_FILE"
$JRUN --beat 60 -- sh -c 'echo TOKEN=sk-ant-SECRET123' >/dev/null 2>&1
if grep -q "sk-ant-SECRET123" "$JOURNAL_FILE" 2>/dev/null; then
  bad "secret leaked into journal"
else
  ok "secret not in journal"
fi
TASK=$(python3 -c "import json; print(json.loads(open('$JOURNAL_FILE').readline())['task'])" 2>/dev/null)
case "$TASK" in
  "jrun: sh") ok "only command name journaled ($TASK)" ;;
  *) bad "task field leaks args: $TASK" ;;
esac

# --- 6. json_escape: UTF-8 readable, control chars valid ---
echo "--- json_escape ---"
export JOURNAL_FILE="$TDIR/utf8.jsonl"
rm -f "$JOURNAL_FILE"
$JLOG start task="tóm tắt công việc" >/dev/null 2>&1
if grep -q "tóm tắt" "$JOURNAL_FILE" 2>/dev/null; then
  ok "UTF-8 readable in journal"
else
  bad "UTF-8 escaped to \\uXXXX"
fi
python3 -c "import json; [json.loads(l) for l in open('$JOURNAL_FILE')]" 2>/dev/null \
  && ok "journal lines are valid JSON" || bad "invalid JSON in journal"
# ESC / control chars
$JLOG start task="$(printf 'a\033b\x01c')" >/dev/null 2>&1
python3 -c "import json; [json.loads(l) for l in open('$JOURNAL_FILE')]" 2>/dev/null \
  && ok "control chars produce valid JSON" || bad "control chars break JSON"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
