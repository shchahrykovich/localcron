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
- `apps/cli` (`localcron`): stateless. Sync socket client; `localcron mcp` is
  the MCP server (rmcp on a current-thread tokio runtime). `add_job` takes the
  MCP server's current folder as the default `dir`. `apps/cli` must not
  depend on `apps/daemon`.
- `apps/menubar`: Swift package. `LocalCronKit` has the Swift copy of the API
  types, the socket client, the updater, and the CLI, Claude Code and Codex
  installers (note link + MCP registration); `LocalCron` is the AppKit
  `NSStatusItem` + `NSPopover` app, which registers the daemon as an
  `SMAppService` LaunchAgent.

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
