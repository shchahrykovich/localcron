# {{APP}}

{{APP}} runs on this Mac. It runs jobs on a timer: a shell command, or a
Claude Code or Codex agent with a prompt, without a terminal. It is a small
daemon with a menu bar app; it starts at login and catches up on a run that
the Mac slept through. The {{APP}} menu bar app installed this note.

Use it when the user asks to do something later or again and again: "run the
dependency check every Wednesday", "every morning at 8, ask Claude to sum up
new issues", "tomorrow at 9, run the release script".

## Tools

The MCP server `{{CLI}}` has these tools. The CLI `{{CLI}}` does the same
(`{{CLI}} --help`).

- `add_job`: create a job. `replace: true` changes an existing one.
- `list_jobs`, `get_job`, `remove_job`, `enable_job`
- `run_job`: run now, outside the schedule. `cancel_run` stops it;
  `force: true` kills it at once.
- `set_paused`: pause or resume every schedule, only when the user asks.
  While paused no scheduled run starts; `run_job` still works.
- `list_runs`, `get_run_log`: status, exit code and output of past runs.
- `preview_schedule`: the next times of a schedule, and the schedule in words.

## How to add a job

1. Choose an `id` that says what the job does: `weekly-deps-check`.
2. Write the `schedule` in local time. Five cron fields
   `minute hour day-of-month month day-of-week`: `0 9 * * wed` is every
   Wednesday at 09:00, `30 8 * * mon-fri` is weekdays at 08:30, `*/30 * * * *`
   is every 30 minutes. `@daily`, `@weekly`, `@hourly` also work. Once:
   `@at 2026-11-05 09:00`. Call `preview_schedule` when you are not sure.
3. Choose the `kind`:
   - `claude`: `prompt` is the task. It runs `claude -p <prompt>` in `dir`.
     The run has no person to approve tools, so a tool that needs approval is
     refused. Give `permission_mode` (`acceptEdits`, `bypassPermissions`, …)
     or `args` such as `["--allowedTools", "Bash(git *) Read Edit"]` only when
     the user agrees to what the job may do.
   - `codex`: `prompt` is the task. It runs `codex exec <prompt>` in `dir`.
   - `shell`: `command` runs with the user's shell in `dir`.
4. `dir` is the project folder. The MCP server uses your current folder when
   you leave it out.
5. Tell the user the job id, the schedule in words (`schedule_text` in the
   reply) and the next run time (`next_run`).

The prompt of a scheduled agent must stand alone: the agent starts with no
memory of this conversation. Say what to do, where, and where to write the
result (a file, a pull request, a message).

## Runs

- At most `max_concurrent` runs at a time (default 2); others wait in a queue.
- A job never runs twice at the same time: a run that comes while the
  previous one is still queued or running is skipped.
- A run is stopped after `timeout_secs` (default 3600).
- Output goes to a log file per run. Read it with `get_run_log`.
- Runs use the PATH of the user's login shell, so `claude`, `codex`, `node`
  and `git` are found as in a terminal.

The CLI cannot be found: ask the user to choose **Install Command Line Tool…**
in the {{APP}} menu.
