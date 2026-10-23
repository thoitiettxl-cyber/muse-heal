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

# 4,6-10 removed on this VM (old-system leftovers): mcp/codemode projects, their
# bins/node_modules/servers.json/store, 7 API-key exports and tokens.json do not exist here.

# 11. login hooks — the `# >>> heal v2` block must exist in BOTH ~/.bashrc
#     (interactive shells) and ~/.profile (login shells; this VM has no
#     ~/.bash_profile chain, so ~/.bashrc alone never fires on login).
#     Versioned: a pre-v2 `# >>> heal` block is REPLACED (old text backed up
#     once to <rc>.heal.bak), so hook changes actually reach installed VMs.
#     Repair is idempotent.
hook_state() {  # $1 = rc file -> ok | old | missing
  if grep -q '^# >>> heal v2' "$1" 2>/dev/null; then echo ok
  elif grep -q '^# >>> heal' "$1" 2>/dev/null; then echo old
  else echo missing
  fi
}
install_login_hooks() {
  for rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.profile"; do
    st="$(hook_state "$rc")"
    [ "$st" = "ok" ] && continue
    if [ "$st" = "old" ]; then
      [ -f "$rc.heal.bak" ] || cp -p "$rc" "$rc.heal.bak" 2>/dev/null
      # Rewrite in place (cat >) so the rc file keeps its inode/permissions.
      if sed '/^# >>> heal/,/^# <<< heal/d' "$rc" >"$rc.heal.tmp" 2>/dev/null; then
        cat "$rc.heal.tmp" >"$rc"
      fi
      rm -f "$rc.heal.tmp"
    fi
    cat >>"$rc" <<'HEAL_HOOK_EOF'

# >>> heal v2: background self-heal + orphaned-work alert on new shells (silent when healthy). Managed by heal.sh — see ~/workspace/logs/heal.log
if [ -x "$HOME/workspace/heal/heal.sh" ]; then
  _heal_now="$(date +%s 2>/dev/null || echo 0)"
  _heal_last="$(cat "$HOME/.config/heal/last-auto" 2>/dev/null || echo 0)"
  case "$_heal_last" in ''|*[!0-9]*) _heal_last=0 ;; esac
  if [ "$_heal_now" -ge "$((_heal_last + 300))" ]; then
    echo "$_heal_now" >"$HOME/.config/heal/last-auto" 2>/dev/null
    ( HEAL_QUIET=1 "$HOME/workspace/heal/heal.sh" fix login >>"$HOME/workspace/logs/heal.log" 2>&1 & )
    # Orphaned-work alert: --alert always (re)writes ~/.config/heal/agents-alert.json,
    # whatever heal-agents' exit status (0/1/2). Read it at session start.
    ( "$HOME/.local/bin/heal-agents" --alert "$HOME/.config/heal/agents-alert.json" >/dev/null 2>&1 & )
  fi
  unset _heal_now _heal_last
fi
# <<< heal
HEAL_HOOK_EOF
  done
}

hooks_ok=1
for rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.profile"; do
  [ "$(hook_state "$rc")" = "ok" ] || hooks_ok=0
done
if [ "$hooks_ok" -eq 1 ]; then
  report_ok "hooks:bashrc+profile"
elif [ "$DRY_RUN" -eq 1 ]; then
  report_would "hooks: install/upgrade # >>> heal v2 block"
else
  install_login_hooks
  hooks_ok=1
  for rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.profile"; do
    [ "$(hook_state "$rc")" = "ok" ] || hooks_ok=0
  done
  if [ "$hooks_ok" -eq 1 ]; then
    report_healed "hooks: installed/upgraded to v2"
  else
    report_failed "hooks: install/upgrade failed"
  fi
fi

# 12. skills — canonical location is ~/workspace/custom-skills/ (the standard
# path muse.skill_search indexes). Content is not regenerable; missing = FAIL.
# The heal skill must be a symlink to the repo (never a copy that can drift).
for s in api-design cli-creator codemode commit ghidra github librarian mcp-builder mcp-client summarize tmux update-changelog uv; do
  if [ -f "$HOME_DIR/workspace/custom-skills/$s/SKILL.md" ]; then
    report_ok "skill:$s"
  else
    report_failed "skill:$s: SKILL.md missing (restore manually)"
  fi
done
if [ -L "$HOME_DIR/workspace/custom-skills/heal" ] && [ "$(readlink "$HOME_DIR/workspace/custom-skills/heal")" = "$HOME_DIR/workspace/muse-heal/skills/heal" ]; then
  report_ok "skill:heal (symlink to repo)"
else
  report_failed "skill:heal: not a symlink to ~/workspace/muse-heal/skills/heal (run install.sh)"
fi

# 13. git-gh-auth — git + gh auth must be present under $HOME and gh must
#     be installed under ~/.local/bin (a system gh does not survive a VM
#     replace). Strict cmp -s against ~/workspace/.secrets only for
#     .gitconfig and gh config.yml (tools do not rewrite them).
#     Credential stores (.git-credentials, hosts.yml) are checked by
#     existence + mode 600 + github.com present only — no value cmp —
#     because git/gh may rewrite them; heal restores them only if
#     missing, wrong mode, or host absent, never clobbering a rotated
#     credential. Secret VALUES are never printed, logged, or diffed.
#     If the .secrets source itself is missing, this is FAIL (a secret
#     value cannot be regenerated).
restore_auth_file() {  # $1 = source, $2 = dest -> 0 if dest matches source
  mkdir -p "$(dirname "$2")" 2>/dev/null
  cp "$1" "$2" 2>/dev/null && chmod 600 "$2" 2>/dev/null && cmp -s "$1" "$2"
}

ensure_secrets_block() {  # idempotent, grep-guarded append to BOTH rc files
  for _rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.profile"; do
    grep -q 'BEGIN muse-secrets' "$_rc" 2>/dev/null && continue
    cat >>"$_rc" <<'HEAL_SECRETS_EOF'

# BEGIN muse-secrets (managed: sources ~/workspace/.secrets/.bashrc if present; idempotent)
if [ -f "$HOME/workspace/.secrets/.bashrc" ]; then . "$HOME/workspace/.secrets/.bashrc"; fi
# END muse-secrets
HEAL_SECRETS_EOF
    grep -q 'BEGIN muse-secrets' "$_rc" 2>/dev/null || return 1
  done
  return 0
}

repair_gh_userspace() {  # install gh to ~/.local/bin (survives VM replace)
  [ -x "$HOME_DIR/.local/bin/gh" ] && timeout 10 "$HOME_DIR/.local/bin/gh" --version >/dev/null 2>&1 && return 0
  ver="$(timeout 20 curl -s https://api.github.com/repos/cli/cli/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')"
  [ -n "$ver" ] || ver="2.103.0"
  tmp="/tmp/heal-gh-$$.tar.gz"
  if timeout 150 curl -sSL --max-time 140 -o "$tmp" "https://github.com/cli/cli/releases/download/v${ver}/gh_${ver}_linux_amd64.tar.gz" 2>/dev/null && tar -tzf "$tmp" >/dev/null 2>&1; then
    mkdir -p "/tmp/heal-gh-$$" && tar -xzf "$tmp" -C "/tmp/heal-gh-$$" 2>/dev/null && cp "/tmp/heal-gh-$$/gh_${ver}_linux_amd64/bin/gh" "$HOME_DIR/.local/bin/gh" 2>/dev/null && chmod +x "$HOME_DIR/.local/bin/gh" 2>/dev/null
  fi
  rm -rf "$tmp" "/tmp/heal-gh-$$" 2>/dev/null
  [ -x "$HOME_DIR/.local/bin/gh" ] && timeout 10 "$HOME_DIR/.local/bin/gh" --version >/dev/null 2>&1
}

cred_ok() {  # $1 = .git-credentials -> 0 if exists, mode 600, github.com host present (no value cmp)
  [ -f "$1" ] || return 1
  [ "$(stat -c %a "$1" 2>/dev/null)" = "600" ] || return 1
  awk '{n=split($0,a,"@"); if (n>1) {split(a[2],b,":"); print b[1]}}' "$1" 2>/dev/null | grep -qx 'github.com'
}

hosts_ok() {  # $1 = hosts.yml -> 0 if exists, mode 600, github.com: key present (no value cmp)
  [ -f "$1" ] || return 1
  [ "$(stat -c %a "$1" 2>/dev/null)" = "600" ] || return 1
  grep -qx 'github.com:' "$1" 2>/dev/null
}

restore_git_credentials() {  # restore only if missing, wrong mode, or github.com absent
  cred_ok "$HOME_DIR/.git-credentials" && return 0
  cp "$HOME_DIR/workspace/.secrets/.git-credentials" "$HOME_DIR/.git-credentials" 2>/dev/null && chmod 600 "$HOME_DIR/.git-credentials" 2>/dev/null
  cred_ok "$HOME_DIR/.git-credentials"
}

restore_gh_hosts() {  # restore only if missing, wrong mode, or github.com absent
  hosts_ok "$HOME_DIR/.config/gh/hosts.yml" && return 0
  mkdir -p "$HOME_DIR/.config/gh" 2>/dev/null
  cp "$HOME_DIR/workspace/.secrets/hosts.yml" "$HOME_DIR/.config/gh/hosts.yml" 2>/dev/null && chmod 600 "$HOME_DIR/.config/gh/hosts.yml" 2>/dev/null
  hosts_ok "$HOME_DIR/.config/gh/hosts.yml"
}

auth_check() {  # 0 if strict files match source, credential stores pass cred_ok/hosts_ok, blocks present, user-space gh runs
  cmp -s "$HOME_DIR/workspace/.secrets/.gitconfig" "$HOME_DIR/.gitconfig" 2>/dev/null || return 1
  cmp -s "$HOME_DIR/workspace/.secrets/config.yml" "$HOME_DIR/.config/gh/config.yml" 2>/dev/null || return 1
  cred_ok "$HOME_DIR/.git-credentials" || return 1
  hosts_ok "$HOME_DIR/.config/gh/hosts.yml" || return 1
  [ "$(stat -c %a "$HOME_DIR/.gitconfig" 2>/dev/null)" = "600" ] || return 1
  [ "$(stat -c %a "$HOME_DIR/.config/gh/config.yml" 2>/dev/null)" = "600" ] || return 1
  [ "$(stat -c %a "$HOME_DIR/workspace/.secrets" 2>/dev/null)" = "700" ] || return 1
  for _sf in .gitconfig .git-credentials .bashrc config.yml hosts.yml; do
    [ "$(stat -c %a "$HOME_DIR/workspace/.secrets/$_sf" 2>/dev/null)" = "600" ] || return 1
  done
  grep -q 'BEGIN muse-secrets' "$HOME_DIR/.bashrc" 2>/dev/null || return 1
  grep -q 'BEGIN muse-secrets' "$HOME_DIR/.profile" 2>/dev/null || return 1
  [ -x "$HOME_DIR/.local/bin/gh" ] && timeout 10 "$HOME_DIR/.local/bin/gh" --version >/dev/null 2>&1
}

auth_source_missing=""
[ -f "$HOME_DIR/workspace/.secrets/.gitconfig" ] || auth_source_missing="$auth_source_missing .gitconfig"
[ -f "$HOME_DIR/workspace/.secrets/.git-credentials" ] || auth_source_missing="$auth_source_missing .git-credentials"
[ -f "$HOME_DIR/workspace/.secrets/.bashrc" ] || auth_source_missing="$auth_source_missing .bashrc"
[ -f "$HOME_DIR/workspace/.secrets/config.yml" ] || auth_source_missing="$auth_source_missing config.yml"
[ -f "$HOME_DIR/workspace/.secrets/hosts.yml" ] || auth_source_missing="$auth_source_missing hosts.yml"
if [ -n "$auth_source_missing" ]; then
  report_failed "git-gh-auth: source missing in ~/workspace/.secrets (re-stage manually)"
elif auth_check; then
  report_ok "git-gh-auth"
elif [ "$DRY_RUN" -eq 1 ]; then
  report_would "git-gh-auth: restore from ~/workspace/.secrets"
else
  chmod 700 "$HOME_DIR/workspace/.secrets" 2>/dev/null
  chmod 600 "$HOME_DIR/workspace/.secrets/.gitconfig" "$HOME_DIR/workspace/.secrets/.git-credentials" "$HOME_DIR/workspace/.secrets/.bashrc" "$HOME_DIR/workspace/.secrets/config.yml" "$HOME_DIR/workspace/.secrets/hosts.yml" 2>/dev/null
  auth_fail=""
  restore_auth_file "$HOME_DIR/workspace/.secrets/.gitconfig" "$HOME_DIR/.gitconfig" || auth_fail="gitconfig"
  restore_git_credentials || auth_fail="git-credentials"
  restore_auth_file "$HOME_DIR/workspace/.secrets/config.yml" "$HOME_DIR/.config/gh/config.yml" || auth_fail="gh-config"
  restore_gh_hosts || auth_fail="gh-hosts"
  ensure_secrets_block || auth_fail="secrets-block"
  repair_gh_userspace || auth_fail="gh-install"
  if [ -z "$auth_fail" ] && auth_check; then
    report_healed "git-gh-auth: restored from ~/workspace/.secrets"
  else
    report_failed "git-gh-auth: restore failed (${auth_fail:-verify})"
  fi
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
