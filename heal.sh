#!/bin/sh
# heal.sh — self-healing for this Hatch VM.
#
# Only $HOME survives a VM replace. This script verifies every piece of the
# permanent setup living under $HOME and repairs what it can. Every check is
# idempotent: running it N times is the same as running it once.
#
# Usage: heal [check|fix|status|log] [caller]
#   fix (default) : check + repair
#   check         : dry run — report only, change nothing
#   status        : last run result + recent log lines
#   log           : tail the log
#   -h/--help     : this help
# Env: HEAL_QUIET=1 -> print nothing when the result is OK (used by the
#   login-shell hook).
#
# Core mechanics (adapted from muse-bootstrap heal.sh for this VM):
#   - atomic state write (tmp + mv), one state file per caller
#   - flock: concurrent runs serialize; the loser exits quietly
#   - whole run bounded by `timeout` (re-exec guard); TIMEOUT is recorded
#   - one log file, rotated to the last 200 lines
#   - every possibly-hanging command wrapped in `timeout`
#   - secret VALUES are never printed or logged; only key NAMES are matched
#
# What heal deliberately does NOT do:
#   - restore anything outside $HOME (base image is the source of truth there)
#   - regenerate secret values (API keys, OAuth tokens) — presence is checked,
#     a missing value is reported as FAIL for a human to fix
#   - push anything to any repo

set -u

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
HOME_DIR="${HOME:-/home/hatch}"
LOG_DIR="$HOME_DIR/workspace/logs"
LOG="$LOG_DIR/heal.log"
STATE_DIR="$HOME_DIR/.config/heal"
LOCK="$STATE_DIR/heal.lock"
NODE_CACHE_DIR="$HOME_DIR/.cache/heal"
NODE_VER="v24.20.0"
NODE_TARBALL="node-${NODE_VER}-linux-x64.tar.xz"
NODE_URL="https://nodejs.org/dist/${NODE_VER}/${NODE_TARBALL}"
NODE_LOCAL="$HOME_DIR/.local/node"

# Sane PATH for the run itself: our own bins first, then system, then the
# hatch image extras (npm lives there).
PATH="$HOME_DIR/.local/node/bin:$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin:/opt/hatch-image/bin:$PATH"
export PATH

MODE="fix"
CALLER="manual"
QUIET="${HEAL_QUIET:-0}"
DRY_RUN=0

for a in "$@"; do
  case "$a" in
    fix) MODE="fix" ;;
    check) MODE="check" ;;
    status) MODE="status" ;;
    log) MODE="log" ;;
    -q|--quiet) QUIET=1 ;;
    -h|--help|help) MODE="help" ;;
    login|manual|cron) CALLER="$a" ;;
    *) echo "heal: unknown argument '$a'" >&2; echo "usage: heal [check|fix|status|log] [caller]" >&2; exit 2 ;;
  esac
done
[ "$MODE" = "check" ] && DRY_RUN=1

num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

log_line() { echo "$(date '+%F %T %Z') $*" >>"$LOG"; }

write_state() {
  # $1 = result word. Atomic: tmp + rename.
  tmp="$STATE.tmp.$$"
  echo "$(date +%s) $1" >"$tmp" && mv "$tmp" "$STATE"
}

# ---------------------------------------------------------------- help/status
if [ "$MODE" = "help" ]; then
  sed -n '2,/^$/p' "$SELF" | sed 's/^# \{0,1\}//'
  exit 0
fi

mkdir -p "$LOG_DIR" "$STATE_DIR" "$NODE_CACHE_DIR" 2>/dev/null
STATE="$STATE_DIR/state.$CALLER"

if [ "$MODE" = "status" ]; then
  if [ -f "$STATE" ]; then
    epoch="$(num "$(cut -d' ' -f1 "$STATE" 2>/dev/null)")"
    result="$(cut -d' ' -f2 "$STATE" 2>/dev/null || echo unknown)"
    echo "heal status: result=$result at=$(date -d "@$epoch" '+%F %T %Z' 2>/dev/null || echo "$epoch") caller=$CALLER"
  else
    echo "heal status: no state yet for caller=$CALLER"
  fi
  echo "--- recent log ---"
  tail -n 8 "$LOG" 2>/dev/null || echo "(empty log)"
  exit 0
fi

if [ "$MODE" = "log" ]; then
  tail -n 50 "$LOG" 2>/dev/null || echo "(empty log)"
  exit 0
fi

# ------------------------------------------------- timeout guard (outer layer)
# Bound the total runtime: re-exec under `timeout` unless already wrapped.
if [ -z "${HEAL_WRAPPED:-}" ] && command -v timeout >/dev/null 2>&1; then
  export HEAL_WRAPPED=1
  timeout -k 10 300 "$SELF" "$@"
  code=$?
  if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
    # Record TIMEOUT under the flock, re-checking state mtime INSIDE the
    # lock so a concurrent run can never interleave between check and write.
    start_s="$(date +%s)"
    (
      flock -n 9 || exit 0
      st_mtime="$(num "$(stat -c %Y "$STATE" 2>/dev/null || echo 0)")"
      if [ "$st_mtime" -le "$start_s" ]; then
        tmp="$STATE.tmp.$$"
        echo "$(date +%s) TIMEOUT" >"$tmp" && mv "$tmp" "$STATE"
        log_line "TIMEOUT caller=$CALLER"
        [ "$QUIET" -eq 1 ] || echo "heal result=TIMEOUT caller=$CALLER"
      fi
    ) 9>"$LOCK"
  fi
  exit "$code"
fi

# ------------------------------------------------- concurrency guard (inner)
# Another heal is already working — exit BEFORE any state write, so the loser
# can never fake a fresh state.
exec 9>"$LOCK"
flock -n 9 || exit 0

start_s="$(date +%s)"
start_ms="$(date +%s%3N)"

ok_list=""
healed_list=""
failed_list=""
would_list=""

report_ok()     { ok_list="${ok_list} $1"; }
report_healed() { healed_list="${healed_list} $1"; log_line "HEALED:$1"; }
report_failed() { failed_list="${failed_list} $1"; log_line "FAIL:$1"; }
report_would()  { would_list="${would_list} $1"; }

# ------------------------------------------------------------------ repairs
ensure_bashrc_path_entry() {
  # $1 = dir that must appear in a fresh login shell's PATH.
  # Idempotent: grep-guarded append to ~/.bashrc.
  line="export PATH=\"$1:\$PATH\""
  grep -qF "$line" "$HOME_DIR/.bashrc" 2>/dev/null && return 0
  printf '%s\n' "$line" >>"$HOME_DIR/.bashrc"
}

repair_node() {
  # Try cached tarball first (works offline), then download.
  if [ -f "$NODE_CACHE_DIR/$NODE_TARBALL" ]; then
    rm -rf "$NODE_LOCAL"
    mkdir -p "$NODE_LOCAL"
    if timeout 120 tar -xJf "$NODE_CACHE_DIR/$NODE_TARBALL" -C "$NODE_LOCAL" --strip-components=1 2>/dev/null; then
      ensure_bashrc_path_entry "$NODE_LOCAL/bin"
      PATH="$NODE_LOCAL/bin:$PATH"; export PATH
      timeout 10 node --version >/dev/null 2>&1 && return 0
    fi
    return 1
  fi
  command -v curl >/dev/null 2>&1 || return 1
  tmp="$NODE_CACHE_DIR/$NODE_TARBALL.tmp.$$"
  if timeout 150 curl -sSL --max-time 140 -o "$tmp" "$NODE_URL" 2>/dev/null; then
    mv "$tmp" "$NODE_CACHE_DIR/$NODE_TARBALL"
    repair_node
  else
    rm -f "$tmp"
    return 1
  fi
}

repair_npm() {
  # npm ships inside the node tarball; reuse the node repair path.
  if [ -x "$NODE_LOCAL/bin/npm" ]; then
    ensure_bashrc_path_entry "$NODE_LOCAL/bin"
    PATH="$NODE_LOCAL/bin:$PATH"; export PATH
    timeout 10 npm --version >/dev/null 2>&1 && return 0
  fi
  repair_node && timeout 10 npm --version >/dev/null 2>&1
}

write_mcp_wrapper() {
  cat >"$HOME_DIR/.local/bin/mcp" <<'HEAL_MCP_EOF'
#!/usr/bin/env bash
# Permanent system MCP client (registry: ~/.config/mcp/servers.json)
#
# Durable env loading: API keys live in ~/.bashrc, but non-interactive shells
# (cron, exec, login shells without a .bash_profile chain) don't source it.
# Instead of requiring the caller to `source ~/.bashrc`, apply only the
# `export VAR=value` lines here — no other .bashrc side effects run.
if [ -r "$HOME/.bashrc" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      export\ [A-Za-z_]*=*) eval "$line" 2>/dev/null || true ;;
    esac
  done < "$HOME/.bashrc"
fi
exec node "$HOME/workspace/mcp/bin/mcp.mjs" "$@"
HEAL_MCP_EOF
  chmod +x "$HOME_DIR/.local/bin/mcp"
}

write_codemode_wrapper() {
  cat >"$HOME_DIR/.local/bin/codemode" <<'HEAL_CODEMODE_EOF'
#!/usr/bin/node
// codemode launcher: delegates to the project implementation. Keeps no logic here
// so updates only touch ~/workspace/codemode/.
import "/home/hatch/workspace/codemode/cli.mjs";
HEAL_CODEMODE_EOF
  chmod +x "$HOME_DIR/.local/bin/codemode"
}

repair_node_modules() {
  # $1 = project dir. npm ci is the idempotent repair (lockfile -> exact tree).
  proj="$1"
  ( cd "$proj" && timeout 240 npm ci --no-audit --no-fund >>"$LOG" 2>&1 )
}

# ------------------------------------------------------------------- checks
# 1. node — base image provides it; repair from under ~ if gone.
if timeout 10 node --version >/dev/null 2>&1; then
  report_ok "node:$(timeout 10 node --version 2>/dev/null)"
elif [ "$DRY_RUN" -eq 1 ]; then
  report_would "node: reinstall ${NODE_VER} from cache/download"
else
  if repair_node; then
    report_healed "node: reinstalled ${NODE_VER}"
  else
    report_failed "node: missing and reinstall failed"
  fi
fi

# 2. npm — needed for node_modules repair.
if timeout 10 npm --version >/dev/null 2>&1; then
  report_ok "npm:$(timeout 10 npm --version 2>/dev/null)"
elif [ "$DRY_RUN" -eq 1 ]; then
  report_would "npm: restore from node tarball"
else
  if repair_npm; then
    report_healed "npm: restored"
  else
    report_failed "npm: missing and restore failed"
  fi
fi

# 3. login-shell PATH must contain ~/.local/bin (checked in a FRESH login shell,
#    not the current one — the current shell may have it while new logins don't).
if timeout 10 bash -lc 'case ":$PATH:" in *":$HOME/.local/bin:"*) exit 0;; *) exit 1;; esac' >/dev/null 2>&1; then
  report_ok "login-path: ~/.local/bin"
elif [ "$DRY_RUN" -eq 1 ]; then
  report_would "login-path: append ~/.local/bin to ~/.bashrc"
else
  ensure_bashrc_path_entry "$HOME_DIR/.local/bin"
  if timeout 10 bash -lc 'case ":$PATH:" in *":$HOME/.local/bin:"*) exit 0;; *) exit 1;; esac' >/dev/null 2>&1; then
    report_healed "login-path: ~/.local/bin"
  else
    report_failed "login-path: ~/.local/bin still missing after repair"
  fi
fi

# 4. CLI binaries in ~/.local/bin (existence + content sanity + executable).
for b in mcp codemode; do
  bin="$HOME_DIR/.local/bin/$b"
  sane=0
  if [ -x "$bin" ]; then
    case "$b" in
      mcp) grep -q 'workspace/mcp/bin/mcp.mjs' "$bin" 2>/dev/null && sane=1 ;;
      codemode) grep -q 'workspace/codemode/cli.mjs' "$bin" 2>/dev/null && sane=1 ;;
    esac
  fi
  if [ "$sane" -eq 1 ]; then
    report_ok "bin:$b"
  elif [ "$DRY_RUN" -eq 1 ]; then
    report_would "bin:$b: regenerate wrapper"
  else
    case "$b" in
      mcp) write_mcp_wrapper ;;
      codemode) write_codemode_wrapper ;;
    esac
    if [ -x "$bin" ]; then
      report_healed "bin:$b: regenerated"
    else
      report_failed "bin:$b: regenerate failed"
    fi
  fi
done

# 5. the `heal` command itself must resolve.
if [ -L "$HOME_DIR/.local/bin/heal" ] && \
   [ "$(readlink "$HOME_DIR/.local/bin/heal")" = "$SELF" ]; then
  report_ok "bin:heal"
elif [ "$DRY_RUN" -eq 1 ]; then
  report_would "bin:heal: recreate symlink"
else
  ln -sfn "$SELF" "$HOME_DIR/.local/bin/heal"
  if [ -L "$HOME_DIR/.local/bin/heal" ]; then
    report_healed "bin:heal: symlink recreated"
  else
    report_failed "bin:heal: symlink recreate failed"
  fi
fi

# 6. node_modules for mcp + codemode (pinned dep present = tree intact).
npm_ok=0
timeout 10 npm --version >/dev/null 2>&1 && npm_ok=1
for proj in mcp codemode; do
  case "$proj" in
    mcp) dep="@earendil-works/pi-mcp" ;;
    codemode) dep="@earendil-works/pi-codemode" ;;
  esac
  pdir="$HOME_DIR/workspace/$proj"
  if [ -f "$pdir/package.json" ] && [ -f "$pdir/node_modules/$dep/package.json" ]; then
    report_ok "node_modules:$proj"
  elif [ ! -f "$pdir/package.json" ] || [ ! -f "$pdir/package-lock.json" ]; then
    report_failed "node_modules:$proj: project source missing (cannot npm ci)"
  elif [ "$DRY_RUN" -eq 1 ]; then
    report_would "node_modules:$proj: npm ci"
  elif [ "$npm_ok" -eq 0 ]; then
    report_failed "node_modules:$proj: npm unavailable, cannot reinstall"
  else
    if repair_node_modules "$pdir" && [ -f "$pdir/node_modules/$dep/package.json" ]; then
      report_healed "node_modules:$proj: npm ci"
    else
      report_failed "node_modules:$proj: npm ci failed"
    fi
  fi
done

# 7. servers.json symlink -> the registry under ~/workspace.
link="$HOME_DIR/.config/mcp/servers.json"
target="$HOME_DIR/workspace/mcp/servers.json"
if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
  report_ok "symlink:servers.json"
elif [ "$DRY_RUN" -eq 1 ]; then
  report_would "symlink:servers.json: ln -sfn"
else
  mkdir -p "$HOME_DIR/.config/mcp"
  # If it's a real file (not a link), back it up before replacing.
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    mv "$link" "$link.heal-bak-$(date +%s)"
  fi
  ln -sfn "$target" "$link"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
    report_healed "symlink:servers.json"
  else
    report_failed "symlink:servers.json: relink failed"
  fi
fi

# 8. API key exports in ~/.bashrc — NAMES only, values never read or logged.
#    A missing value cannot be regenerated by heal: honest FAIL.
for k in CONTEXT7_API_KEY KSHT_API_KEY POSTIMAGE_API_KEY EXA_API_KEY FIRECRAWL_API_KEY REDIS_API_KEY TYPESAFE_API_KEY; do
  if grep -q "^export ${k}=" "$HOME_DIR/.bashrc" 2>/dev/null; then
    report_ok "env:$k"
  else
    report_failed "env:$k: export line missing from ~/.bashrc (re-add manually)"
  fi
done

# 9. OAuth tokens: must exist, mode 0600. Missing token = FAIL (needs re-auth).
tok="$HOME_DIR/.config/mcp/tokens.json"
if [ -f "$tok" ]; then
  mode="$(stat -c %a "$tok" 2>/dev/null || echo ?)"
  if [ "$mode" = "600" ]; then
    report_ok "tokens.json:600"
  elif [ "$DRY_RUN" -eq 1 ]; then
    report_would "tokens.json: chmod 600 (now $mode)"
  else
    chmod 600 "$tok"
    if [ "$(stat -c %a "$tok" 2>/dev/null)" = "600" ]; then
      report_healed "tokens.json: chmod 600"
    else
      report_failed "tokens.json: chmod failed"
    fi
  fi
else
  report_failed "tokens.json: missing (re-run OAuth flow manually)"
fi

# 10. codemode store.json — created lazily by codemode; ensure it exists.
store="$HOME_DIR/.config/codemode/store.json"
if [ -f "$store" ]; then
  report_ok "codemode-store"
elif [ "$DRY_RUN" -eq 1 ]; then
  report_would "codemode-store: create {}"
else
  mkdir -p "$HOME_DIR/.config/codemode"
  printf '{}\n' >"$store" && chmod 600 "$store"
  if [ -f "$store" ]; then
    report_healed "codemode-store: created"
  else
    report_failed "codemode-store: create failed"
  fi
fi

# 11. login hooks — the `# >>> heal` block must exist in BOTH ~/.bashrc
#     (interactive shells) and ~/.profile (login shells; this VM has no
#     ~/.bash_profile chain, so ~/.bashrc alone never fires on login).
#     Repair re-appends the block (grep-guarded, idempotent).
install_login_hooks() {
  for rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.profile"; do
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
    # Check for orphaned agent work after a possible VM replace; write an
    # alert file instead of printing (nobody reads hook output). Throttled
    # by the same 5-minute window as the heal run above.
    ( "$HOME/.local/bin/heal-agents" --json >"$HOME/.config/heal/agents-alert.json.tmp" 2>/dev/null && mv "$HOME/.config/heal/agents-alert.json.tmp" "$HOME/.config/heal/agents-alert.json" & )
  fi
  unset _heal_now _heal_last
fi
# <<< heal
HEAL_HOOK_EOF
    fi
  done
}

hooks_ok=1
for rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.profile"; do
  grep -q '# >>> heal' "$rc" 2>/dev/null || hooks_ok=0
done
if [ "$hooks_ok" -eq 1 ]; then
  report_ok "hooks:bashrc+profile"
elif [ "$DRY_RUN" -eq 1 ]; then
  report_would "hooks: append # >>> heal block"
else
  install_login_hooks
  hooks_ok=1
  for rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.profile"; do
    grep -q '# >>> heal' "$rc" 2>/dev/null || hooks_ok=0
  done
  if [ "$hooks_ok" -eq 1 ]; then
    report_healed "hooks: reinstalled"
  else
    report_failed "hooks: reinstall failed"
  fi
fi

# 12. skills — canonical location is ~/workspace/custom-skills/ (the standard
# path muse.skill_search indexes). Content is not regenerable; missing = FAIL.
for s in api-design cli-creator codemode commit github librarian mcp-builder mcp-client summarize tmux update-changelog uv heal; do
  if [ -f "$HOME_DIR/workspace/custom-skills/$s/SKILL.md" ]; then
    report_ok "skill:$s"
  else
    report_failed "skill:$s: SKILL.md missing (restore manually)"
  fi
done

# 13. rea — reverse-engineering CLI + MCP server (npm global, prefix ~/.local).
# Binary + package + engine JARs (jadx, apktool) + java runtime. Not
# auto-reinstalled here (needs network + npm); FAIL names the manual fix.
rbin="$HOME_DIR/.local/bin/rea"
rea_state="ok"
[ -x "$rbin" ] || rea_state="no-binary"
[ -f "$HOME_DIR/.local/lib/node_modules/rea-agents/package.json" ] || rea_state="no-package"
[ -f "$HOME_DIR/.local/share/rea/jadx-headless-mcp-0.7.1-all.jar" ] || rea_state="no-jadx-jar"
[ -f "$HOME_DIR/.local/share/rea/apktool_3.0.3.jar" ] || rea_state="no-apktool-jar"
[ -x "$HOME_DIR/.local/bin/apktool" ] || rea_state="no-apktool-launcher"
if [ "$rea_state" = "ok" ]; then
  if timeout 10 bash -lc 'command -v java >/dev/null 2>&1' >/dev/null 2>&1; then
    rver="$(timeout 10 "$rbin" --version 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$rver" ]; then
      report_ok "rea:$rver"
    else
      report_failed "rea: binary not responding"
    fi
  else
    report_failed "rea: java missing (JDK needed for jadx engine; reinstall Temurin JDK to ~/.local/jdk-21)"
  fi
elif [ "$DRY_RUN" -eq 1 ]; then
  report_would "rea: reinstall via bash ~/workspace/rea/install.sh"
else
  report_failed "rea: $rea_state (reinstall: bash ~/workspace/rea/install.sh)"
fi

# ------------------------------------------------------------------ report
stamp="$(date '+%F %T %Z')"
end_ms="$(date +%s%3N)"
dur_ms=$((end_ms - start_ms))

n_ok="$(echo "$ok_list" | wc -w)"
n_healed="$(echo "$healed_list" | wc -w)"
n_failed="$(echo "$failed_list" | wc -w)"

if [ -n "$failed_list" ]; then
  result="FAIL"
elif [ "$DRY_RUN" -eq 1 ]; then
  result="CHECK"
elif [ -n "$healed_list" ]; then
  result="HEALED"
else
  result="OK"
fi

write_state "$result"
log_line "result=$result caller=$CALLER dur=${dur_ms}ms ok=$n_ok healed=$n_healed failed=$n_failed${healed_list:+ healed:[$healed_list ]}${failed_list:+ failed:[$failed_list ]}${would_list:+ would:[$would_list ]}"

# Rotate log (under flock).
tail -n 200 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"

if [ "$DRY_RUN" -eq 1 ]; then
  n_would="$(echo "$would_list" | wc -w)"
  echo "heal result=CHECK caller=$CALLER ok=$n_ok would_heal=$n_would"
  [ -n "$would_list" ] && echo "would heal: $would_list"
  [ -n "$failed_list" ] && { echo "unfixable: $failed_list"; exit 1; }
  exit 0
fi

summary="heal result=$result caller=$CALLER dur=${dur_ms}ms ok=$n_ok healed=$n_healed failed=$n_failed"
if [ "$result" = "OK" ]; then
  [ "$QUIET" -eq 1 ] || echo "$summary"
  exit 0
fi
echo "$summary"
[ -n "$healed_list" ] && echo "healed: $healed_list"
[ -n "$failed_list" ] && echo "failed: $failed_list"
[ "$result" = "FAIL" ] && exit 1
exit 0
