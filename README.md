# muse-heal

Self-healing toolkit for an AI agent's Linux VM. Two systems, one repo:

1. **`heal`** — repairs the agent's permanent environment under `$HOME` after a
   VM replacement (only `$HOME` survives). Idempotent checks: node/npm, login
   `PATH`, heal symlink, login hooks, skills, git/gh auth (names only, values
   never logged).
2. **`heal-agents`** — finds agent *work* orphaned by a VM replacement. A work
   journal (`jlog`) records delegated tasks and heartbeats; the detector flags
   tasks whose last heartbeat predates the current boot.

## What's inside

| Path | Description |
|------|-------------|
| `heal.sh` | `$HOME` self-heal: idempotent checks + repairs (node/npm, login PATH, mcp/codemode bins + node_modules + servers.json + store, tool-env clean-env test, uv, heal symlink, login hooks, skills, git/gh auth) |
| `heal-agents.sh` | Orphaned-work detector (read-only) |
| `jlog.sh` | Work-journal helper (`start`/`beat`/`done`/`fail`/`show`) |
| `jrun.sh` | Wrap a long command: auto `start`, heartbeat while alive, `done`/`fail` on exit or signal; journals the command name only, never its arguments |
| `install.sh` | Idempotent installer: files, symlinks, login-shell hooks |
| `skills/heal/SKILL.md` | Agent skill: when to journal, detector usage, resume protocol |

## Quick start

```bash
git clone https://github.com/thoitiettxl-cyber/muse-heal.git ~/workspace/muse-heal
sh ~/workspace/muse-heal/install.sh
```

This installs `heal`, `heal-agents`, `jlog` into `~/.local/bin`, adds a
background self-heal hook (silent when healthy) to `~/.bashrc` and `~/.profile`,
and runs `heal` once to verify.

## Usage

```bash
heal                 # check + repair the environment
heal check           # dry run
heal status / heal log

# journaling long delegated work:
ID=$(jlog start task="build X" brief=briefs/x.md workdir=~/workspace/x | sed 's/JLOG_ID=//')
# ... worker beats: jlog beat --id $ID progress="..."
# ... then:       jlog done --id $ID summary="..."

jrun --label "jadx app.apk" -- jadx -d out app.apk   # or: auto start/beat/done/fail for one long command
heal-agents          # list work orphaned by VM replace (or gone stale)
heal-agents --alert ~/.config/heal/agents-alert.json   # what the login hook runs: always writes the report, exit 0
heal-agents --json
```

Resume is deliberately human-gated: `heal-agents` reports *what* died and *how
far it got*; a human decides whether to re-spawn. See `skills/heal/SKILL.md`
for the full protocol.

## Design notes

- Everything lives under `$HOME` — the only thing that survives a VM replace.
- `heal.sh`: atomic state writes, `flock` against concurrent runs, `timeout`
  bounds, centralized log; secret *values* are never printed or logged.
- `heal-agents.sh`: never modifies the journal; orphaned ⟺ current boot is
  newer than the task's last heartbeat.
- Node comes from the base image; if it ever goes missing, `heal.sh` reinstalls
  from `~/.cache/heal/node-v24.20.0-linux-x64.tar.xz` (pre-download, works
  offline) or downloads it.

## Hourly runtime cron (mechanical trigger after a VM replace)

The login-shell hook never fires in agent tool shells (`bash --norc
--noprofile`), so it alone cannot recreate outside-`$HOME` items after
a VM replace. The runtime cron `heal-hourly-fix` (hourly) runs
`HEAL_QUIET=1 heal fix` in a plain tool shell and reports only when
heal reports failed>0. Its definition lives in `~/workspace/cron.d/`
(inside `$HOME`) and the scheduler lives outside the VM, so the job
survives a replace. Recreate it if it is ever deleted; HEARTBEAT.md
is deliberately not used for this.

## Limits

- Cannot restore anything outside `$HOME`, except the single
  `/usr/local/bin/gh` symlink, re-applied by heal on every fix run.
- Cannot regenerate secret values — only detects their absence.
- Only journaled work can be detected as orphaned.
- Network-dependent repairs fail closed when offline.

MIT License.
