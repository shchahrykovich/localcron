# LocalCron

LocalCron is a macOS menu bar app that runs jobs on a timer. A job is a shell
command, or a Claude Code or Codex agent with a prompt. It runs without a
terminal, on a cron schedule, in your project folder.

The main use: you ask Claude Code "every Wednesday at 9, check the
dependencies and open a pull request", and Claude adds the job through
LocalCron's MCP server. On Wednesday at 9, LocalCron starts
`claude -p "<prompt>"` in that folder and keeps the output.

## What it does

- Runs jobs on a cron schedule in local time (`0 9 * * wed`), or once
  (`@at 2026-11-05 09:00`).
- Three kinds of job: `shell`, `claude` (`claude -p`), `codex` (`codex exec`).
- Controls the runs: at most N at the same time (default 2), a queue for the
  others, no second run of a job that is still running, a timeout per job,
  and Cancel, which stops the job and every process it started (SIGTERM,
  then SIGKILL after 10 s; **Kill Now** sends SIGKILL at once).
- Pause: **Pause All Jobs** (menu bar menu, window header, `localcron pause`)
  stops every schedule until you resume. Run Now still works. Times missed
  while paused are not caught up.
- The menu bar icon shows a pause sign while paused, and a yellow warning
  triangle while the last run of a job has failed or timed out.
- Catches up: a time the Mac slept through runs once when it wakes.
- Keeps the output of each run in a log file, and the last 20 runs per job.
- Small: the daemon sleeps until the next due time. It has no polling loop
  and no web server.

## Install

1. Download the newest `localcron-<version>.dmg` from
   [Releases](https://github.com/shchahrykovich/localcron/releases/latest).
2. Drag LocalCron to Applications and open it. A clock appears in the menu bar.
3. In its menu choose **Add to Claude Code** and/or **Add to Codex**. This:
   1. links the `localcron` command to `~/.local/bin/localcron`,
   2. registers the MCP server (`claude mcp add --scope user localcron …`, or a
      `[mcp_servers.localcron]` table in `~/.codex/config.toml`),
   3. links a short note into `~/.claude` (imported from `CLAUDE.md`) or
      `~/.codex` (named in `AGENTS.md`), so the agent knows when to use it.

The app updates itself from GitHub Releases. Updates come only from a
notarized image signed by the same team.

## Use it from Claude Code

Ask in plain words:

> Every Wednesday at 9:00, run Claude in this repo: check for outdated
> dependencies, update them on a branch, run the tests, and open a PR.

Claude calls `add_job` and tells you the schedule in words and the next run.
The MCP tools: `add_job`, `list_jobs`, `get_job`, `remove_job`, `enable_job`,
`run_job`, `cancel_run`, `list_runs`, `get_run_log`, `preview_schedule`,
`set_paused`, `status`.

A scheduled agent has no person to approve its tools. Without permission
options, `claude -p` refuses a tool that needs approval. Give a job
`permission_mode` (for example `acceptEdits`) or `args` such as
`["--allowedTools", "Read Edit Bash(git *)"]` only when you accept what the
job may do.

## Use it from the terminal

```
localcron add deps --schedule "0 9 * * wed" --claude "Update outdated dependencies and open a PR" --permission-mode acceptEdits
localcron add backup --schedule "30 2 * * *" --command "rsync -a ~/notes /Volumes/backup/"
localcron list
localcron run deps --wait
localcron runs deps
localcron log deps.3
localcron next "30 8 * * mon-fri"
localcron config --max-concurrent 3
```

The folder of a new job is the current folder (`--dir` changes it).

## Schedules

Five fields in local time: `minute hour day-of-month month day-of-week`.

| Schedule | Means |
|---|---|
| `0 9 * * wed` | Every Wednesday at 09:00 |
| `30 8 * * mon-fri` | Weekdays at 08:30 |
| `*/15 * * * *` | Every 15 minutes |
| `0 9,17 * * *` | At 09:00 and 17:00 |
| `0 0 1 * *` | The first day of each month at 00:00 |
| `@daily`, `@weekly`, `@hourly` | Short forms |
| `@at 2026-11-05 09:00` | Once |

When both day-of-month and day-of-week are set, a day matches if either one
matches, as in classic cron.

## How runs get their environment

launchd starts the daemon with a short PATH, where `claude`, `codex` and
Homebrew tools are missing. Before a run, LocalCron asks your login shell for
its PATH (`$SHELL -l -i -c`), as editors do, and keeps it for 10 minutes. A
run also gets `LOCALCRON_JOB_ID`, `LOCALCRON_RUN_ID` and the job's own `env`.

## Files

```
~/Library/Application Support/LocalCron/   jobs.json, runs.json, config.json, daemon.sock
~/Library/Logs/LocalCron/                  daemon.log, runs/<job>/<run>.log
```

## Build from source

Needs Rust (see `rust-toolchain.toml`) and Xcode command line tools, macOS 14+
on Apple Silicon.

```
cargo test --workspace
swift test --package-path apps/menubar
scripts/install.sh --user --launch     # LocalCron-dev.app in ~/Applications, next to a release
```

`LocalCron-dev` has its own daemon, CLI (`localcron-dev`), folders and MCP
name, and an orange menu bar icon.

## License

MIT
