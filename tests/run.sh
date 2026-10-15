#!/bin/sh
# tests/run.sh — reproducible verification for heal-agents/jlog/jrun fixes.
# Each claim in commit messages must be re-verifiable by running this.
# Usage: sh tests/run.sh
set -u

# Ensure toolkit binaries are on PATH (non-interactive shells may lack ~/.local/bin)
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

PASS=0
FAIL=0
TDIR=$(mktemp -d)
trap 'rm -rf "$TDIR"' EXIT INT TERM

JLOG=${JLOG:-jlog}
JRUN=${JRUN:-jrun}
HEAL_AGENTS=${HEAL_AGENTS:-heal-agents}
JRUN_PATH=$(command -v "$JRUN" 2>/dev/null || echo "$JRUN")

ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- 1. alert on orphaned/malformed ---
echo "--- alert on orphaned/malformed ---"
export JOURNAL_FILE="$TDIR/journal.jsonl"
$JLOG start task="orphan case" >/dev/null 2>&1
if $HEAL_AGENTS --alert "$TDIR/alert.json" >/dev/null 2>&1; then
  [ -f "$TDIR/alert.json" ] && ok "alert file written (exit 0)" || bad "alert file missing"
  python3 -c "import json; d=json.load(open('$TDIR/alert.json')); assert 'checked_at' in d['summary']" 2>/dev/null \
    && ok "alert has checked_at" || bad "alert missing checked_at"
else
  bad "--alert should always exit 0"
fi
echo "NOT JSON {{{" >> "$JOURNAL_FILE"
if $HEAL_AGENTS --alert "$TDIR/alert2.json" >/dev/null 2>&1; then
  [ -f "$TDIR/alert2.json" ] && ok "alert written despite malformed line" || bad "alert missing on malformed"
else
  bad "--alert must exit 0 even with bad lines"
fi

# --- 2. kill -9 (37s: 12s + 25s for 2+ beat cycles) ---
echo "--- kill -9 (beat 10s, 2+ cycles) ---"
export JOURNAL_FILE="$TDIR/kill9.jsonl"
rm -f "$JOURNAL_FILE"
$JRUN --beat 10 --label "kill9-test" -- sleep 120 >/dev/null 2>&1 &
KP=$!
sleep 12
B1=$(grep -c '"kind":"beat"' "$JOURNAL_FILE" 2>/dev/null || echo 0)
kill -9 $KP 2>/dev/null
sleep 2
sleep 25
B2=$(grep -c '"kind":"beat"' "$JOURNAL_FILE" 2>/dev/null || echo 0)
[ "$B2" -eq "$B1" ] && ok "kill -9: no ghost beats ($B1 -> $B2 after 25s)" || bad "kill -9: ghost beats ($B1 -> $B2)"
V=$(JOURNAL_FILE="$TDIR/kill9.jsonl" $HEAL_AGENTS --stale-minutes 0 --json 2>/dev/null | python3 -c "
import json,sys; d=json.load(sys.stdin); s=d['summary']
print('STALE' if s['stale']>0 and s['active']==0 else 'ACTIVE' if s['active']>0 else 'OTHER')" 2>/dev/null)
[ "$V" = "STALE" ] && ok "heal-agents reports STALE (not active)" || bad "verdict: $V (want STALE)"

# --- 3. signals ---
# NOTE: SIGINT cannot be delivered to background jobs in non-interactive shells
# (POSIX). TERM/HUP prove the on_signal path; INT uses the same path.
echo "--- signals ---"
for spec in "TERM:143" "HUP:129"; do
  SIG=${spec%%:*}; CODE=${spec##*:}
  export JOURNAL_FILE="$TDIR/sig-$SIG.jsonl"
  rm -f "$JOURNAL_FILE"
  $JRUN --beat 60 --label "sig-$SIG" -- sleep 30 >/dev/null 2>&1 &
  SP=$!
  sleep 2
  kill -$SIG $SP 2>/dev/null
  for _i in 1 2 3 4 5; do kill -0 $SP 2>/dev/null || break; sleep 1; done
  wait $SP 2>/dev/null; RC=$?
  KIND=$(python3 -c "import json; ls=[json.loads(l) for l in open('$JOURNAL_FILE')]; print([x['kind'] for x in ls if x['kind'] in ('done','fail')][-1])" 2>/dev/null)
  [ "$RC" -eq "$CODE" ] && [ "$KIND" = "fail" ] && ok "SIG$SIG -> exit $CODE, journal fail" || bad "SIG$SIG -> exit $RC (want $CODE), journal $KIND (want fail)"
done
grep -q "trap 'on_signal INT 130' INT" "$JRUN_PATH" 2>/dev/null \
  && ok "SIGINT trap installed (on_signal INT 130)" || bad "SIGINT trap not found"

# --- 4. stdin + secret + json (fast) ---
echo "--- stdin + secret + json_escape ---"
export JOURNAL_FILE="$TDIR/fast.jsonl"
rm -f "$JOURNAL_FILE"
OUT=$(echo "hello pipe" | $JRUN --beat 60 --label "stdin-pipe" -- cat 2>/dev/null)
[ "$OUT" = "hello pipe" ] && ok "stdin via pipe works" || bad "stdin pipe: got '$OUT'"
OUT2=$($JRUN --beat 60 --label "stdin-closed" -- cat < /dev/null 2>/dev/null)
[ -z "$OUT2" ] && ok "closed stdin works" || bad "closed stdin: got '$OUT2'"

export JOURNAL_FILE="$TDIR/secret.jsonl"
rm -f "$JOURNAL_FILE"
$JRUN --beat 60 -- sh -c 'echo TOKEN=sk-ant-SECRET123' >/dev/null 2>&1
grep -q "sk-ant-SECRET123" "$JOURNAL_FILE" 2>/dev/null && bad "secret leaked into journal" || ok "secret not in journal"
TASK=$(python3 -c "import json; print(json.loads(open('$JOURNAL_FILE').readline())['task'])" 2>/dev/null)
[ "$TASK" = "jrun: sh" ] && ok "only command name journaled ($TASK)" || bad "task leaks args: $TASK"

export JOURNAL_FILE="$TDIR/utf8.jsonl"
rm -f "$JOURNAL_FILE"
$JLOG start task="tóm tắt công việc" >/dev/null 2>&1
grep -q "tóm tắt" "$JOURNAL_FILE" 2>/dev/null && ok "UTF-8 readable in journal" || bad "UTF-8 escaped"
python3 -c "import json; [json.loads(l) for l in open('$JOURNAL_FILE')]" 2>/dev/null \
  && ok "journal lines are valid JSON" || bad "invalid JSON"
$JLOG start task="$(printf 'a\033b\x01c')" >/dev/null 2>&1
python3 -c "import json; [json.loads(l) for l in open('$JOURNAL_FILE')]" 2>/dev/null \
  && ok "control chars produce valid JSON" || bad "control chars break JSON"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
