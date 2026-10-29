# {{APP}} help

{{APP}} runs jobs on this Mac on a timer: a shell command, or a Claude Code
or Codex agent with a prompt. It needs no open terminal. A small daemon starts
at login, runs each job at its time, and runs a time once that the Mac slept
through. You manage jobs in the menu bar app, with the `{{CLI}}` command, or
by asking a coding agent.

This page is also for agents: **Copy as Markdown** at the top copies all of
it, ready to paste into Claude Code, Codex or another agent.

## Set up

1. Open {{APP}}. Its clock icon is in the menu bar.
2. In the icon's menu choose **Install Command Line Tool…**. It links
   `{{CLI}}` into `~/.local/bin`. Check it in a new terminal: `{{CLI}} status`.
3. For agents, choose **Add to Claude Code…** or **Add to Codex…**:
   - Claude Code: it links `~/.claude/{{APP}}.md` (the agent instructions
     below), adds `@{{APP}}.md` to `~/.claude/CLAUDE.md`, and runs
     `claude mcp add --scope user {{CLI}} -- ~/.local/bin/{{CLI}} mcp`.
   - Codex: it adds the MCP server to `~/.codex/config.toml` and the
     instructions to `~/.codex/AGENTS.md`:

     ```toml
     [mcp_servers.{{CLI}}]
     command = "/Users/you/.local/bin/{{CLI}}"
     args = ["mcp"]
     ```
4. Start a new agent session, so it loads the MCP server.

## Use it from a terminal

```
{{CLI}} add deps --schedule "0 9 * * wed" --claude "Update outdated dependencies and open a PR" --permission-mode acceptEdits
{{CLI}} add backup --schedule "30 2 * * *" --command "rsync -a ~/notes /Volumes/backup/"
{{CLI}} list
{{CLI}} run deps --wait
{{CLI}} runs deps
{{CLI}} log deps.3
```

A new job runs in the current folder; `--dir` changes it.

| Command | What it does |
|---|---|
| `{{CLI}} status` | Daemon version, jobs, runs and the next run |
| `{{CLI}} list` | The jobs |
| `{{CLI}} show ID` | One job |
| `{{CLI}} add ID --schedule S --command C` | A shell job; `--claude P` or `--codex P` for an agent job |
| `{{CLI}} add … --replace` | Change a job |
| `{{CLI}} remove ID` | Remove a job, its runs and logs |
| `{{CLI}} enable ID`, `{{CLI}} disable ID` | Turn a job on or off |
| `{{CLI}} run ID [--wait]` | Run now; `--wait` prints the output and exits with the run's code |
| `{{CLI}} cancel RUN [--kill]` | Stop a run: SIGTERM, then SIGKILL after 10 s; `--kill` at once |
| `{{CLI}} pause`, `{{CLI}} resume` | Stop or start every schedule |
| `{{CLI}} runs [ID]` | Recent runs, newest first |
| `{{CLI}} log RUN` | The output of a run |
| `{{CLI}} next "S"` | The next times of a schedule |
| `{{CLI}} config` | Show or change the settings: `--max-concurrent N`, `--keep-runs N` |
| `{{CLI}} secret set NAME` | Store a secret's value in the Keychain |
| `{{CLI}} secret describe NAME "TEXT"` | Change a secret's description |
| `{{CLI}} secret list` | The secrets, without values |
| `{{CLI}} secret remove NAME` | Remove a secret |
| `{{CLI}} guide` | The instructions for agents (the last part of this page) |
| `{{CLI}} mcp` | The MCP server, for agents |

Every command takes `--json` for the daemon's reply as JSON.

Options of `add`: `--dir DIR`, `--model M`, `--permission-mode MODE`
(Claude), `--arg A` (one more argument for claude or codex, repeat it),
`--env NAME=VALUE`, `--secret-env NAME=SECRET`, `--timeout 30m`,
`--no-catch-up`, `--disabled`, `--note TEXT`.

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
matches, as in classic cron. Check a schedule with `{{CLI}} next "0 9 * * wed"`.

## Secrets

A token or key goes in a secret, never in `--env`: `env` is saved as plain
text. The value is kept in your login keychain, so runs at night can read it.

1. Store it: `{{CLI}} secret set github-token --description "Fine-grained token, repo shop, github.com/settings/tokens, expires 2027-01-31"`.
   It asks for the value with no echo. Or pipe it in:
   `pbpaste | {{CLI}} secret set github-token`, or from 1Password:
   `op read "op://Private/GitHub/token" | {{CLI}} secret set github-token`.
   The menu bar app's **Secrets** tab does the same.
2. Name it in a job: `--secret-env GH_TOKEN=github-token`. The run gets the
   value as `$GH_TOKEN`.
3. Allow the job: in the icon's menu, **Waiting for your OK**, then
   **Allow Secrets for …**, with Touch ID or your password. Only the menu bar
   app can do this, and only for the job as you saw it: a change to its
   command, prompt, arguments, folder, env or secrets needs a new OK. A
   new schedule does not.

Run logs show a value as `<secret NAME>`. The description says how to make a
new value when this one expires or leaks.

## Runs

- At most 2 runs at a time by default (`{{CLI}} config --max-concurrent N`);
  others wait in a queue.
- A job never runs twice at once: a run that comes while one is queued or
  running is skipped.
- A run stops after its timeout, 1 hour by default (`--timeout`).
- A time missed while the Mac slept or was off runs once at wake, unless
  the job has `--no-catch-up`. Times missed while paused do not run.
- Runs use the PATH of your login shell, so `claude`, `codex`, `node` and
  `git` are found as in a terminal. A run also gets `LOCALCRON_JOB_ID` and
  `LOCALCRON_RUN_ID`.
- An agent run has nobody to approve its tools: a tool that needs approval
  is refused. Give `--permission-mode` or `--arg --allowedTools …` only for
  what you accept the job may do.

## Files

```
~/Library/Application Support/{{APP}}/   jobs.json, runs.json, config.json, secrets.json (no values), daemon.sock
~/Library/Logs/{{APP}}/                  daemon.log, runs/<job>/<run>.log
```

## When something is wrong

| You see | Do this |
|---|---|
| `{{CLI}}: command not found` | Menu: **Install Command Line Tool…**; open a new terminal |
| "{{APP}} is not running" | Open {{APP}}; allow it in System Settings, General, Login Items |
| A run failed: "may not read its secrets yet" | Menu: **Allow Secrets for …** |
| A run failed: "secret … is not set" | `{{CLI}} secret set NAME` |
| A secret "cannot be read" | `{{CLI}} secret set NAME` again; a rebuilt dev app cannot read values an older build stored |
| An agent run did nothing | `{{CLI}} log RUN`: a refused tool is in the output |

## Instructions for agents

{{NOTE}}
