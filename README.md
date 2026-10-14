# muse-heal

Self-healing toolkit for an AI agent's Linux VM. Two systems, one repo:

1. **`heal`** — repairs the agent's permanent environment under `$HOME` after a
   VM replacement (only `$HOME` survives). Idempotent checks: node/npm, login
   `PATH`, CLI wrappers, `node_modules`, config symlinks, API-key exports
   (names only, values never logged), token permissions, skills, login hooks.
2. **`heal-agents`** — finds agent *work* orphaned by a VM replacement. A work
   journal (`jlog`) records delegated tasks and heartbeats; the detector flags
   tasks whose last heartbeat predates the current boot.

## What's inside

| Path | Description |
|------|-------------|
| `heal.sh` | `$HOME` self-heal: 12 idempotent checks + repairs |
| `heal-agents.sh` | Orphaned-work detector (read-only) |
| `jlog.sh` | Work-journal helper (`start`/`beat`/`done`/`fail`/`show`) |
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

heal-agents          # list work orphaned by VM replace (or gone stale)
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

## Limits

- Cannot restore anything outside `$HOME`.
- Cannot regenerate secret values — only detects their absence.
- Only journaled work can be detected as orphaned.
- Network-dependent repairs fail closed when offline.

MIT License.
