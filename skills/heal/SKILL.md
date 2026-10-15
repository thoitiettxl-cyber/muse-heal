# heal — self-healing for this Hatch VM

## What it is
`heal` (`~/workspace/heal/heal.sh`, command `~/.local/bin/heal`) verifies every
piece of the permanent setup living under `$HOME` and repairs what it can.
Only `$HOME` survives a VM replace — everything this script manages lives
under `$HOME`, so a fresh VM + one login shell restores the working environment
automatically.

Design: every check is idempotent (N runs == 1 run), state is written
atomically (tmp + mv) to `~/.config/heal/state.<caller>`, concurrent runs are
serialized with `flock` (loser exits quietly), the whole run is bounded by
`timeout` (300s), and one log lives at `~/workspace/logs/heal.log` (rotated to
200 lines). Secret *values* are never printed or logged — only key *names* are
matched.

## When Muse should use it
- After a VM replace / fresh session: run `heal` once to confirm the
  environment is intact.
- When `mcp`, `codemode`, or node tooling misbehaves: `heal check` first
  (dry run), then `heal` to repair.
- After changing anything under `~/.local/bin`, `~/.bashrc`, `~/.config`,
  or the `~/workspace/{mcp,codemode}` projects: `heal` to re-verify.
- To inspect health without touching anything: `heal status`, `heal log`.

## Manual commands
```
heal            # check + repair (default), prints summary
heal fix        # same as above
heal check      # dry run: reports what WOULD be healed, changes nothing
heal status     # last result per caller + recent log lines
heal log        # tail the log
heal --help
HEAL_QUIET=1 heal   # silent when result is OK (what the login hook uses)
```

## Checks (each reports OK / HEALED / FAIL)
1. **node** — runs `node --version`. Repair: extract `~/.cache/heal/node-v24.20.0-linux-x64.tar.xz`
   to `~/.local/node` (works offline); else download from nodejs.org; else FAIL.
2. **npm** — must run. Repair: reuse the node tarball (npm ships inside); else FAIL.
3. **login-path** — a *fresh* `bash -lc` must have `~/.local/bin` in PATH.
   Repair: append `export PATH=...` to `~/.bashrc` (grep-guarded).
4. **bin:mcp / bin:codemode** — exist, executable, content sanity
   (`workspace/mcp/bin/mcp.mjs`, `workspace/codemode/cli.mjs`). Repair:
   regenerate the wrapper from the template embedded in `heal.sh`.
5. **bin:heal** — `~/.local/bin/heal` symlinks to `~/workspace/heal/heal.sh`.
   Repair: recreate the symlink.
6. **node_modules:mcp / node_modules:codemode** — pinned dep's `package.json`
   present. Repair: `timeout 240 npm ci` in the project dir.
7. **symlink:servers.json** — `~/.config/mcp/servers.json` →
   `~/workspace/mcp/servers.json`. Repair: `ln -sfn` (backs up a real file first).
8. **env:\*** — the 7 `export *_API_KEY=` lines exist in `~/.bashrc` (names only).
   Missing = FAIL (a secret value cannot be regenerated; re-add manually).
9. **tokens.json** — exists and mode 600. Wrong mode = `chmod 600` (HEALED);
   missing = FAIL (re-run the OAuth flow manually).
10. **codemode-store** — `~/.config/codemode/store.json` exists; created as `{}`
    mode 600 if missing (HEALED).
11. **hooks** — the versioned `# >>> heal v2` block exists in both `~/.bashrc`
    and `~/.profile`. Repair: install it; a pre-v2 `# >>> heal` block is
    replaced (old text backed up once to `<rc>.heal.bak`), so hook changes
    reach already-installed VMs. Idempotent.
12. **skill:\*** — each expected skill dir has `SKILL.md`
    (api-design cli-creator codemode commit github librarian mcp-builder
    mcp-client summarize tmux update-changelog uv heal). Missing = FAIL
    (content is not regenerable; restore manually).

## Permanent registration
A guarded `# >>> heal` block lives at the end of **both** `~/.bashrc`
(interactive shells) **and** `~/.profile` (login shells — this VM has no
`~/.bash_profile` chain, so `~/.bashrc` alone never fires on login).
On new shells (throttled to one auto-run per 5 minutes via
`~/.config/heal/last-auto`) it launches `HEAL_QUIET=1 heal.sh fix login`
**in the background**, output appended to the log. Logins stay instant and
silent when healthy; any repair or failure is visible via `heal status` /
`heal log`. Heal check #11 verifies both hooks are the current version and
(re)installs them — the registration itself is self-healing. The same hook
also runs `heal-agents --alert ~/.config/heal/agents-alert.json` in the
background (same 5-minute throttle). `--alert` ALWAYS rewrites that file and
exits 0, whatever the detector found (orphaned / clean / malformed / detector
crashed -> `{"error":...}`); `summary.checked_at` says how fresh it is.

## Limits (be honest about these)
- Cannot restore anything outside `$HOME` — the base image owns that.
- Cannot regenerate secret values (API keys, OAuth tokens) — only detects absence.
- Network-dependent repairs (`npm ci`, node download) fail closed when offline.
- Never pushes to any repo.

---

# Agent work journal & orphan recovery (heal-agents)

## The problem it solves
A VM replace kills the main agent and its subagents mid-work with no notice.
`heal-agents` (`~/workspace/heal/heal-agents.sh`, command `~/.local/bin/heal-agents`)
finds work that died this way so it can be resumed instead of rediscovered by
accident. It is read-only: running it never changes anything.

## Session-start convention (for Muse)
At the start of a session — and whenever the user reports an interruption —
read `~/.config/heal/agents-alert.json` (written by the login hook; check
`summary.orphaned`, `summary.stale`, `summary.bad_lines`, an `error` key, and
that `summary.checked_at` is recent) and/or run `heal-agents` BEFORE other work. If it reports orphaned/stale tasks,
follow the resume protocol below. Do not silently re-do work the journal shows
as already done.

## When to journal (for Muse, the main agent)
Write a journal entry every time you delegate long-running work:
- spawning a subagent for a task that takes more than a few minutes, or
- a side chat / long task that must survive a VM replace.
Short, single-turn tasks don't need journaling.

```sh
ID=$(jlog start task="tóm tắt việc" brief="$HOME/workspace/agent-journal/briefs/<slug>.md" workdir="<dir>" [chat="<chat-id>"] | sed 's/JLOG_ID=//')
```
- `brief` should point at a real file under `~/workspace/agent-journal/briefs/`
  containing the full brief you gave the worker (so a resume can re-read it).
- Keep the returned `$ID` — pass it to the worker.

## Entry format
`~/workspace/agent-journal/journal.jsonl`, append-only, one JSON object per line:

| kind | fields |
|---|---|
| `start` | `id`, `task`, `brief`, `workdir`, `chat`, `ts` |
| `beat` | `id`, `ts`, `progress` (and/or `milestone`) |
| `done` | `id`, `ts`, `summary` |
| `fail` | `id`, `ts`, `error` |

Helper: `~/workspace/agent-journal/jlog.sh` (command `jlog`):
```
jlog start [--id ID] task="..." [brief="..."] [workdir="..."] [chat="..."]
jlog beat  --id ID progress="..."
jlog done  --id ID [summary="..."]
jlog fail  --id ID error="..."
jlog show  --id ID          # full history of one task
```
Env override for tests: `JOURNAL_FILE=/path/to/journal.jsonl`.

## jrun — automatic journaling for long commands
For a single long non-interactive command (decompile, download, build) don't
rely on remembering `jlog`: wrap it.
```
jrun [--beat N] [--label TEXT] -- <command> [args...]    # e.g. jrun --label "jadx app.apk" -- jadx -d out app.apk
```
- Writes `start`, a heartbeat every N s (default 60, min 10) **only while jrun
  itself is alive**, and exactly one terminal entry: `done` (exit 0) or `fail`
  (non-zero exit, or killed by INT/TERM/HUP -> exit 130/143/129; the child is
  sent TERM, then KILL after 5 s). Exit code and stdin are passed through.
- **Only the command name (or `--label`) is journaled, never the arguments** —
  they may carry tokens. Don't put secrets in `--label`.
- `kill -9` on jrun cannot be trapped: no terminal entry, but the heartbeat
  stops with it, so `heal-agents` shows the task as stale/orphaned (the
  command itself may keep running as an orphan — check `workdir`).

## What the worker's brief MUST require
Every brief for journaled work must include this convention (copy-paste):
> Trong lúc làm, ghi tiến độ vào journal sau mỗi milestone (hoặc mỗi vài phút):
> `jlog beat --id <ID> progress="<đã xong gì / đang ở đâu>"`.
> Khi xong: `jlog done --id <ID> summary="<kết quả>"`. Khi lỗi không tiếp tục
> được: `jlog fail --id <ID> error="<lỗi>"`.
> Journal mặc định: `~/workspace/agent-journal/journal.jsonl`.

Without heartbeats, the detector can only say "started, then silence" — the
finer the beats, the more precise the resume.

## The detector
```
heal-agents                  # human-readable report
heal-agents --json           # machine-readable
heal-agents --stale-minutes N   # default 30
```
For each task with no terminal entry (`done`/`fail`), it compares the current
boot time (`uptime -s`) against the task's last heartbeat:
- **orphaned** — boot is NEWER than the last heartbeat: the VM was replaced
  after the worker's last sign of life. This is the case that matters.
- **stale** — no heartbeat for N minutes but no replace detected: the worker
  may have died, or may just be slow/quiet.
- Anything with `done`/`fail` is ignored (no false positives).

Exit codes: 0 clean, 1 orphaned/stale found, 2 error or malformed journal
lines (malformed lines = tasks silently untracked; `--json` reports
`summary.bad_lines`). `--alert FILE` writes the `--json` report to FILE and
always exits 0.

## Resume protocol (human-gated — do NOT auto-resume)
For each orphaned/stale task, present to Boss:
1. What the task was (`task`, `brief` file).
2. How far it got — last `progress` from the journal PLUS the actual state of
   files in `workdir` (verify, don't trust the journal blindly).
3. What likely remains.

Then ask before re-spawning. If Boss approves, spawn with a resume brief:
> Bạn đang RESUME công việc dở dang (VM replace đã giết agent trước).
> - Task: <task> — Brief gốc: <đọc file brief>
> - Tiến độ cuối (journal): <progress> — Workdir: <workdir> (kiểm chứng file trước)
> - TIẾP TỤC từ chỗ dở, đừng làm lại từ đầu trừ khi file cho thấy cần.
> - Quy ước journal: `jlog beat --id <ID> progress="..."` mỗi milestone,
>   `jlog done/fail --id <ID>` khi kết thúc. ID=<ID>.

## Limits (be honest about these)
- Only journaled work can be detected. If nobody wrote `start`, the task is
  invisible to the detector.
- Heartbeat granularity = resume precision. No beats → "started, then silence".
- `stale` is ambiguous by design (dead vs. slow) — that's exactly why resume
  stays human-gated instead of automatic.
- Never pushes to any repo.
