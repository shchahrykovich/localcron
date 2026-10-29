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
- `list_secrets`: the secrets jobs can use, without their values.

## How to add a job

1. Choose an `id` that says what the job does: `weekly-deps-check`.
2. Write the `schedule` in local time. Five cron fields
   `minute hour day-of-month month day-of-week`: `0 9 * * wed` is every
   Wednesday at 09:00, `30 8 * * mon-fri` is weekdays at 08:30, `*/30 * * * *`
   is every 30 minutes. `@daily`, `@weekly`, `@hourly` also work. Once:
   `@at 2026-11-05 09:00`, or a time from now: `@in 20m`, `@in 1h30m`,
   `@in 45s` (saved as `@at`). A job that runs once is removed after its
   run; the run and its log stay (`list_runs`, `get_run_log`). Call
   `preview_schedule` when you are not sure.
3. Choose the `kind`:
   - `claude`: `prompt` is the task. It runs `claude -p <prompt>` in `dir`.
     The run has no person to approve tools, so a tool that needs approval is
     refused. Give `permission_mode` (`acceptEdits`, `bypassPermissions`, …)
     or `args` such as `["--allowedTools", "Bash(git *) Read Edit"]` only when
     the user agrees to what the job may do.
   - `codex`: `prompt` is the task. It runs `codex exec <prompt>` in `dir`.
   - `shell`: `command` runs with the user's shell in `dir`.
4. A token or key the job needs goes in `secret_env`, never in `env` or the
   prompt: see Secrets below.
5. `dir` is the project folder. The MCP server uses your current folder when
   you leave it out.
6. Tell the user the job id, the schedule in words (`schedule_text` in the
   reply) and the next run time (`next_run`).

The prompt of a scheduled agent must stand alone: the agent starts with no
memory of this conversation. Say what to do, where, and where to write the
result (a file, a pull request, a message).

## Secrets

A job gets a secret, such as an API token, as an environment variable. The
value is kept in the macOS Keychain, never in the job, and runs read it with
nobody there.

- In `add_job`, `secret_env` maps a variable to a secret name:
  `{"GH_TOKEN": "github-token"}`. Use `env` only for values that are not
  secret. `list_secrets` shows the names that exist: reuse one when it fits.
- You never see or send a secret value. No tool takes or returns one.
- A job with `secret_env` gets its secrets only after the user allows it in
  the {{APP}} menu bar app (Jobs, Allow Secrets), with Touch ID or their
  password. The reply says `secrets_allowed: false` until then: tell the user.
  A change to what the job runs (command, prompt, args, folder, env,
  secret_env) needs a new approval; a new schedule does not. You cannot
  allow it yourself, by any tool or command.
- Run logs show a secret's value as `<secret NAME>`.
- When the reply has `missing_secrets`, give the user each `set_command` to
  run in their own terminal, with a description that says how to make a new
  value when this one expires or leaks: where, which scopes, the expiry.
  Write it as one line:
  `{{CLI}} secret set github-token --description "GitHub fine-grained token, repo shop, Contents read/write, github.com/settings/tokens, expires 2027-01-31"`.
  The command asks for the value with no echo. From the clipboard or a
  password manager: `pbpaste | {{CLI}} secret set github-token` or
  `op read "op://Private/GitHub/token" | {{CLI}} secret set github-token`.
- When the value is in a file of settings, the command takes it from there,
  and the secret may have another name. `--key` is the path in the file; the
  format comes from the file's name, or `--format env|json|ini`:
  `{{CLI}} secret set github-token --key GH_TOKEN --file .env` (also a
  1Password Environments `.env`, which is a named pipe),
  `{{CLI}} secret set github-token --key services.github.token --file config.json`,
  `{{CLI}} secret set aws-secret --key default.aws_secret_access_key --file ~/.aws/credentials`,
  or `cat .env | {{CLI}} secret set github-token --key GH_TOKEN`. It prints
  no value, so you may run it yourself when the user asks; never read the
  file yourself. Its errors list the keys that are there.
- Do not suggest running it with `!` in this chat, and never ask the user to
  paste the value here: the chat goes to the model provider. If the user
  pastes a secret anyway, do not use it; tell them it is now in the chat and
  that they should make a new one.
- The command has no argument for the value, so it never stays in the shell
  history. Do not invent one.
- A `claude` or `codex` job can read its own environment and send it to its
  model. Tell the user when a job of that kind gets a secret.
- A secret with state `unreadable` or `missing` (`list_secrets`), or a run
  that failed with "secret … is not set": give the user its `set_command`.
- `{{CLI}} secret describe NAME "<text>"` changes only the description;
  `{{CLI}} secret remove NAME` removes the secret.

## Runs

- At most `max_concurrent` runs at a time (default 2); others wait in a queue.
- A job never runs twice at the same time: a run that comes while the
  previous one is still queued or running is skipped.
- A run is stopped after `timeout_secs` (default 3600).
- Output goes to a log file per run. Read it with `get_run_log`.
- With tmux installed, a `claude` run works in a console the user can open
  and type into (`{{CLI}} attach JOB`, or `tmux -L {{CLI}}-JOB attach`
  without {{APP}}, or Open Terminal in the app). Its
  log gets the console's text at the end. Tell the user about it when they
  want to watch a run; suggest `brew install tmux` when they do not have it.
- Runs use the PATH of the user's login shell, so `claude`, `codex`, `node`
  and `git` are found as in a terminal.

The CLI cannot be found: ask the user to choose **Install Command Line Tool…**
in the {{APP}} menu.
