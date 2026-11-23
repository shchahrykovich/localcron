# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

LocalCron is a macOS menu bar app that runs jobs on a timer: a shell command,
or a Claude Code (`claude -p`) or Codex (`codex exec`) agent with a prompt.
Coding agents manage jobs through an MCP server. The structure follows the
sibling project `../localrouter` (same release scripts, updater, installers
and instance suffix rules).

## Commands

```
cargo test --workspace                                   # all Rust tests
cargo clippy --workspace --all-targets                   # expected: no warnings
swift test --package-path apps/menubar                   # Swift tests
scripts/build-app.sh                                     # build/LocalCron.app, ad-hoc signed
scripts/build-app.sh --developer-id                      # signed with Developer ID + hardened runtime
scripts/install.sh --user --launch                       # build and install LocalCron-dev.app to ~/Applications
scripts/publish.sh [--patch|--minor|--major|--set X.Y.Z] # release to GitHub (needs .env.notarize)
```

Run the daemon by hand without touching `~/Library` (the socket path must
stay under 104 bytes, so use a short folder):

```
H=$(mktemp -d /tmp/lc.XXXX) && LOCALCRON_HOME=$H cargo run -p localcrond
LOCALCRON_HOME=$H cargo run -p localcron -- list
```

## Architecture

```
Claude Code / Codex ──MCP stdio──► localcron mcp ─┐
localcron CLI ────────────────────────────────────┼─ JSON lines, Unix socket daemon.sock ─► localcrond ─► jobs.json, runs.json, config.json
LocalCron.app (Swift) ────────────────────────────┘                                            │
                                                                       run thread ─ spawn ─► process group (claude -p / codex exec / $SHELL -c)
```

- `libs/core`: `schedule.rs` (cron parser, `next_after`, `describe`),
  `job.rs` (fields, validation, argv), `run.rs`, `api.rs` (socket types and
  `METHODS`), `instance.rs`, `paths.rs`, `note.md` (the agent note, also the
  MCP instructions), `help.md` (the help page for people, which ends with
  the note; the CLI's hidden `help-page` renders it to HTML and
  `build-app.sh` puts it in the bundle as `help.html`). No I/O. A new CLI
  command needs a line in `help.md`: a test checks every command is there.
- `apps/daemon` (`localcrond`): no async runtime, only threads. `engine.rs`
  holds all state under one mutex. The scheduler thread sleeps on a condvar
  until the next due time, a run deadline, or a change, at most 60 s (so a
  wake from sleep is seen). Each run has a thread that waits for its process.
  Every run starts in its own process group; cancel and timeout send SIGTERM
  to the group, SIGKILL after 10 s. The daemon blocks SIGTERM in all threads
  and waits for it with `sigwait`; `unblock_signals_in_child` clears the mask
  in children, or they could not be stopped. `shellenv.rs` gets PATH from the
  login shell. A missed time is caught up once, from the newest `due_at` in
  `runs.json` or the job's `updated_at`. `set_job` saves `@in 20m` as `@at`
  (`schedule::resolve`). A one-off job is removed when its scheduled run ends
  (`remove_done`); its runs stay until the log budget needs their space.
  `prune` keeps run logs within `log_budget_mb`: the oldest finished runs go
  first, the newest run of each existing job always stays, and at most
  `MAX_RUNS` runs are kept. A job's `icon` is an SVG that `icon::clean_svg`
  (core) cleans of scripts and links in `set_job`; a replace without an icon
  keeps the old one, `""` removes it.
  Tokens: a claude run gets `--session-id <uuid>` (not when its `args`
  choose a session); when a claude or codex run ends, `usage.rs` finds its
  session file (`~/.claude/projects/*/<uuid>.jsonl` with subagents, or the
  Codex rollout in the job's folder that began during the run) and
  `core::usage` sums it into `Run.usage`. At start a thread does the same
  for older runs (claude ones by time and first prompt).
- Secrets (`libs/core/src/secret.rs`, `apps/daemon/src/secrets.rs`): a job's
  `secret_env` maps a variable to a secret name. Only the daemon writes and
  reads the values, in the login keychain (service `<bundle id>.secrets`),
  so the item's access list names the daemon and a run at night needs no
  dialog. Keychain dialogs are off for the whole daemon: a read that would
  need one fails at once. `secrets.json` holds names and descriptions only.
  No reply, log line or file may contain a value; the value comes only from
  `localcron secret set` (prompt or stdin, never an argument), never from
  MCP. A run gets its secrets only when the user allowed the job in the menu
  bar app (`allow_job_secrets`): the grant in `secrets.json` holds
  `Job::secret_scope`, so a change to what the job runs needs a new one.
  `peer.rs` accepts that call only from this instance's app, checked by the
  connection's audit token and code requirement (Developer ID: the daemon's
  own team; ad hoc: the app program of the daemon's own bundle). Never
  relax it: anything that reaches the socket could otherwise write a job
  that prints a secret, and allow it. Run logs are cleaned of values when a
  run ends, and `get_run_log` hides them while it runs.
  Tests set `LOCALCRON_TEST_KEYCHAIN` to a keychain file in the temp
  folder, and `LOCALCRON_TEST_TRUST_PEERS=1` to allow from any peer (debug
  builds only), so they never touch the login keychain.
- Messages (`libs/core/src/message.rs`): a run sends the user a message
  (`send_message`) or reports how its work went (`set_run_status`, the
  run's `reported`, apart from its exit code). Only a run that is running
  now may, found by `LOCALCRON_RUN_ID` (the daemon also sets
  `LOCAL_CRON_RUN_ID`); at most `MAX_PER_RUN` messages per run, kept in
  `messages.json` (`MAX_KEPT`, read ones dropped first). `status` has
  `unread_messages`; the app draws a dot on its icon. The Chat page of the
  app window has one channel per job: each run is a post with its status
  and a View Log button, and the messages it sent under it (`ChatView`,
  logic in `LocalCronKit/Chat.swift`). A message's text is Markdown
  (`LocalCronKit/MessageMarkdown.swift`): Apple's parser reads it, `blocks`
  groups its text by block, and `MessageBody` draws each block; text goes in
  `LinkText`, an `NSTextView`, because SwiftUI's `Text` on macOS 14 cannot
  show the pointing hand over a link. A soft line break stays a line break.
  The user writes to the manager in the box at the bottom: the user's own
  `claude`, found on the login shell's PATH as jobs find it, one process
  per channel (`claude -p --input-format stream-json --output-format
  stream-json --permission-prompt-tool stdio`; `LocalCronKit/ClaudeStream.swift`
  holds the line protocol: a user message in, stream events out until
  `result`, `control_request` `can_use_tool` answered with a
  `control_response`). `LocalCronKit/Manager.swift` turns the lines into
  entries and builds the instructions, the prompt and the arguments;
  `LocalCron/ManagerStore.swift` runs the processes (stopped after 15 min
  idle), saves each conversation with its session id in
  `manager-chats.json` in the data folder and goes on with `--resume`. The
  session works in the job's folder, gets the bundled CLI as its MCP server
  (`--mcp-config`), and uses every LocalCron tool without asking
  (`Manager.allowedTools`: `mcp__<server>`, plus tools the user allowed for
  the conversation); every other tool shows a card with Allow / Always /
  Reject.
  ⌘F on any page opens the search palette (`Views/SearchPalette.swift`,
  logic in `LocalCronKit/QuickSearch.swift`); `PaletteKeys` reads its keys
  with a local event monitor, before any text field. The channel list sorts
  by `Chat.Order`, saved in UserDefaults.
  `Chat.timeline` puts the conversation between the run posts by time and
  joins posts of one author within 10 minutes, as Slack does.
  A channel's messages become read only while
  that window is the key window. A
  reported error counts as a failed run in the app (`Run.failed`). Codex
  does not pass the run's environment to MCP servers, so the tools take
  `run_id` too.
- `apps/cli` (`localcron`): stateless. Sync socket client; `localcron mcp` is
  the MCP server (rmcp on a current-thread tokio runtime). `add_job` takes the
  MCP server's current folder as the default `dir`. `apps/cli` must not
  depend on `apps/daemon`.
- `apps/menubar`: Swift package. `LocalCronKit` has the Swift copy of the API
  types, the socket client, the updater, and the CLI, Claude Code and Codex
  installers (note link + MCP registration); `LocalCron` is the AppKit
  `NSStatusItem` app, which registers the daemon as an `SMAppService`
  LaunchAgent. There is no popover: a left click on the icon opens the app
  window (`AppWindowView`), a Slack-style rail of pages (Jobs, Runs,
  Calendar, Logs, Chat, Secrets, Settings at the bottom) at the page the
  user left (`WindowPage`, saved in UserDefaults) and at its saved frame.
  Its footer shows only errors (`actionError`): a success says nothing.

### Changing the socket API

The JSON shapes exist twice (Rust and Swift). Update together:
`libs/core/src/api.rs` (types and `METHODS`), `apps/daemon/src/socket.rs` +
`engine.rs`, `api/examples/<method>.request.json` and `.reply.json`, and
`apps/menubar/Sources/LocalCronKit/Api.swift`. The contract tests
(`libs/core/tests/api_examples.rs` and the Swift `ApiContractTests`) decode
every example and fail on a method without one.

## Bundle and release

- `LocalCron.app/Contents/MacOS/LocalCron` (Swift), `Contents/MacOS/localcrond`
  (LaunchAgent `BundleProgram`), `Contents/Helpers/localcron` (CLI),
  `Contents/Resources/LocalCron.md` (the note, printed by the bundled CLI's
  hidden `note` command at build time).
- Bundle id `dev.localcron.app`, LaunchAgent label `dev.localcron.app.daemon`.
- Instances: `scripts/build-app.sh --suffix -dev` builds `LocalCron-dev.app`
  with its own names and folders. Names are in `instance.rs`, `Instance.swift`
  and `release-lib.sh`, checked against `api/instance-names.json`. The daemon
  and CLI read the suffix from their own file names (or `LOCALCRON_INSTANCE`).
  A suffixed instance never updates itself.
- Version: `[workspace.package] version` in `Cargo.toml` only.
- Releases: Developer ID signing with hardened runtime, notarized and stapled
  DMG, `gh release create` on `shchahrykovich/localcron`. The updater accepts
  only https GitHub URLs, images `spctl` accepts, and the same Team ID.
  `.env.notarize` holds credentials; it is git-ignored.
- Only `aarch64-apple-darwin` (Apple Silicon, macOS 14+).
