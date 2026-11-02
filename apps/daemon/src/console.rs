//! A claude job in an interactive console, when tmux is installed: the user
//! can open the console of a running job (`localcron attach RUN`, Open
//! Terminal in the app), watch Claude Code work and type into it.
//!
//! ```text
//! run thread ─ tmux -L localcron-<job id> new-session -d ─► tmux server ─► claude "<prompt>" (interactive)
//!     │ every 300 ms: the events file, the pane, the attached clients        │ hooks append
//!     └────────────── events file ◄── "prompt" / "stop {Stop input as JSON}" ┘
//! ```
//!
//! A turn of claude ends with `stop`, but the work may not be done: claude
//! can end a turn to wait for background tasks (subagents, background
//! shells), and Claude Code wakes it with a new turn when one reports back:
//!
//! ```text
//! prompt                                        the job's prompt
//! stop {"background_tasks":[5 × subagent]}      waits: not finished
//! prompt                                        <task-notification>: a subagent reported
//! stop {"background_tasks":[]}                  finished
//! ```
//!
//! `background_tasks` is a documented field of the Stop hook input (Claude
//! Code hooks docs, "Stop input"; seen in 2.1.316). Every background task
//! counts, not only subagents: a subagent can end its own turn and leave a
//! background shell that wakes it later (seen on 2026-11-02), so only the
//! shell shows that its work goes on.
//!
//! Each running job has its own tmux server, named after the job
//! (`tmux -L localcron-weekly-review attach` opens it, no LocalCron needed):
//! a job never runs twice at once. The run's environment (secrets too)
//! reaches claude as the server's environment, never on a command line. The
//! user's ~/.tmux.conf is not read.
//!
//! The run ends when nobody is attached and the last line is a `stop` whose
//! `background_tasks` is empty, or when claude ends, or at `timeout_secs`. A
//! `stop` without `background_tasks` (a Claude Code that does not send it)
//! ends the run as before; the run log says that LocalCron could not see
//! background agents. When claude never starts its work (a dialog
//! such as "trust this folder?" waits, or claude ends at once), the console
//! is closed and the run goes on without one (`claude -p`).

use std::ffi::OsString;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

/// How long claude may take to start its work in the console.
const GRACE: Duration = Duration::from_secs(90);
const TICK: Duration = Duration::from_millis(300);

pub fn grace() -> Duration {
    if cfg!(debug_assertions)
        && let Some(ms) = std::env::var("LOCALCRON_TEST_CONSOLE_GRACE_MS").ok().and_then(|v| v.parse().ok())
    {
        return Duration::from_millis(ms);
    }
    GRACE
}

pub fn tick() -> Duration {
    TICK
}

/// The program in PATH, as a shell would find it.
pub fn find(program: &str, path: &str) -> Option<PathBuf> {
    path.split(':').filter(|d| !d.is_empty()).map(|d| Path::new(d).join(program)).find(|p| {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    })
}

/// What the console says about its claude.
#[derive(Debug, PartialEq, Eq)]
pub enum Pane {
    Alive,
    /// Ended, with its exit status when it had one.
    Dead(Option<i32>),
    /// The session is gone.
    Gone,
}

pub struct Console {
    tmux: PathBuf,
    /// The tmux server: `localcron-dev-weekly-review`.
    label: String,
    /// The session: the job id.
    session: String,
}

impl Console {
    /// The console of a job of an instance (`cli`: `localcron`, `localcron-dev`).
    pub fn new(tmux: PathBuf, cli: &str, job_id: &str) -> Self {
        Self { tmux, label: format!("{cli}-{job_id}"), session: job_id.to_string() }
    }

    /// The command that opens the console in a terminal.
    pub fn attach_command(&self) -> String {
        format!("{} -L {} attach", self.tmux.display(), self.label)
    }

    fn command(&self) -> Command {
        let mut command = Command::new(&self.tmux);
        command.arg("-L").arg(&self.label).stdin(Stdio::null());
        command
    }

    /// Start `argv` in a new detached session of a new server, in `dir`, with
    /// `env`. The pane stays after claude ends, so its screen can be saved.
    pub fn start(&self, argv: &[String], dir: &str, env: &[(OsString, OsString)]) -> Result<(), String> {
        // A server of an earlier run that LocalCron lost (it stopped during
        // the run) would keep its old environment: close it first.
        if self.query(&["has-session"]).is_some() {
            self.close();
        }
        let mut command = self.command();
        command
            .args(["-f", "/dev/null", "start-server", ";", "set", "-g", "history-limit", "100000", ";"])
            .args(["set", "-g", "remain-on-exit", "on", ";", "new-session", "-d", "-s", &self.session, "-x", "200", "-y", "50", "-c", dir, "--"])
            .args(argv)
            .env_remove("TMUX")
            .env("TERM", "xterm-256color")
            .envs(env.iter().map(|(k, v)| (k, v)))
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .process_group(0);
        crate::unblock_signals_in_child(&mut command);
        let out = command.output().map_err(|e| format!("cannot start tmux: {e}"))?;
        if out.status.success() { Ok(()) } else { Err(format!("tmux: {}", String::from_utf8_lossy(&out.stderr).trim())) }
    }

    fn query(&self, args: &[&str]) -> Option<String> {
        let out = self.command().args(args).stderr(Stdio::null()).output().ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    /// The pid of claude: the first process of the pane, in its own process
    /// group, so a stop reaches what it starts.
    pub fn pid(&self) -> Option<u32> {
        self.query(&["display", "-p", "-t", &self.session, "#{pane_pid}"])?.parse().ok()
    }

    pub fn pane(&self) -> Pane {
        match self.query(&["display", "-p", "-t", &self.session, "#{pane_dead} #{pane_dead_status}"]) {
            None => Pane::Gone,
            Some(text) => match text.split_once(' ') {
                Some(("1", status)) => Pane::Dead(status.parse().ok()),
                _ if text == "1" => Pane::Dead(None),
                _ => Pane::Alive,
            },
        }
    }

    /// Someone has the console open.
    pub fn attached(&self) -> bool {
        self.query(&["list-clients", "-t", &self.session]).is_some_and(|out| !out.is_empty())
    }

    /// The screen and its history, as text. A full-screen program leaves
    /// many empty lines: a run of them becomes one.
    pub fn screen(&self) -> String {
        squeeze(&self.query(&["capture-pane", "-p", "-J", "-S", "-", "-t", &self.session]).unwrap_or_default())
    }

    /// Close the console: claude gets SIGHUP when it still runs. tmux leaves
    /// its socket file behind; it is removed too.
    pub fn close(&self) {
        let socket = self.query(&["display", "-p", "#{socket_path}"]);
        let _ = self.command().arg("kill-server").stdout(Stdio::null()).stderr(Stdio::null()).status();
        if let Some(socket) = socket.filter(|s| s.contains(&self.label)) {
            let _ = std::fs::remove_file(socket);
        }
    }
}

fn squeeze(text: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for line in text.lines().map(str::trim_end) {
        if line.is_empty() && out.last().is_none_or(|l| l.is_empty()) {
            continue;
        }
        out.push(line);
    }
    out.join("\n").trim_end().to_string()
}

/// What the claude hooks wrote to the events file.
#[derive(Debug, PartialEq, Eq)]
pub struct Events {
    /// Claude started its work (a `prompt` line).
    pub started: bool,
    /// How many turns ended (`stop` lines), so a caller can say something
    /// once per turn.
    pub stops: usize,
    pub turn: Turn,
}

/// Where claude is, from the last line of the events file.
#[derive(Debug, PartialEq, Eq)]
pub enum Turn {
    /// No turn ended yet, or a new one runs.
    Working,
    /// The turn ended and no background task runs: the work is done.
    Done,
    /// The turn ended, but background tasks run (one line for each). When
    /// one reports back, Claude Code starts a new turn.
    Waiting(Vec<String>),
    /// The turn ended, and the Stop input has no `background_tasks`: this
    /// Claude Code does not say whether background agents run.
    DoneUnseen,
}

impl Turn {
    pub fn finished(&self) -> bool {
        matches!(self, Turn::Done | Turn::DoneUnseen)
    }
}

pub fn events(path: &Path) -> Events {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let started = text.lines().any(|l| l == "prompt");
    let stops = text.lines().filter(|l| *l == "stop" || l.starts_with("stop ")).count();
    // The Stop hook writes its line in parts: one without its newline is
    // still being written.
    let turn = match text.lines().next_back() {
        Some(line) if text.ends_with('\n') => stop_turn(line),
        _ => Turn::Working,
    };
    Events { started, stops, turn }
}

/// A line of the events file: `stop` and the Stop input, or another line.
fn stop_turn(line: &str) -> Turn {
    let input = match line.strip_prefix("stop") {
        Some("") => return Turn::DoneUnseen,
        Some(rest) if rest.starts_with(' ') => rest,
        _ => return Turn::Working,
    };
    let input: serde_json::Value = serde_json::from_str(input).unwrap_or_default();
    match input.get("background_tasks").and_then(|t| t.as_array()) {
        None => Turn::DoneUnseen,
        Some(tasks) if tasks.is_empty() => Turn::Done,
        Some(tasks) => Turn::Waiting(tasks.iter().map(task_line).collect()),
    }
}

/// One background task for the run log: `subagent "Translate de nl sv"`.
fn task_line(task: &serde_json::Value) -> String {
    let field = |name: &str| task.get(name).and_then(|v| v.as_str()).unwrap_or("");
    let mut description: String = field("description").chars().take(80).collect();
    if description.len() < field("description").len() {
        description.push('…');
    }
    format!("{} {description:?}", field("type"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::io::Write;

    /// The command of a hook of a console run, as `Job::console_argv` writes it.
    fn hook(event: &str) -> String {
        let job: localcron_core::job::Job = serde_json::from_value(
            json!({"id": "article", "schedule": "@daily", "kind": "claude", "prompt": "write the article", "dir": "/tmp"}),
        )
        .unwrap();
        let args = job.console_argv(None);
        let i = args.iter().position(|a| a == "--settings").unwrap();
        let settings: Value = serde_json::from_str(&args[i + 1]).unwrap();
        settings["hooks"][event][0]["hooks"][0]["command"].as_str().unwrap().to_string()
    }

    /// Run a hook as Claude Code 2.1.316 does: `sh -c`, its input on stdin.
    fn run_hook(event: &str, events: &Path, input: &Value) {
        let mut child = Command::new("sh")
            .arg("-c")
            .arg(hook(event))
            .env("LOCALCRON_EVENTS", events)
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        // A hook that does not read its input may end before it is written.
        let _ = child.stdin.take().unwrap().write_all(input.to_string().as_bytes());
        assert!(child.wait().unwrap().success());
    }

    /// The Stop input, in the shape Claude Code 2.1.316 sends it (captured
    /// with a test hook on 2026-11-02). `tasks`: (type, description).
    fn stop_input(tasks: &[(&str, &str)]) -> Value {
        let tasks: Vec<Value> = tasks
            .iter()
            .enumerate()
            .map(|(i, (kind, description))| json!({"id": format!("a{i}"), "type": kind, "status": "running", "description": description}))
            .collect();
        json!({
            "session_id": "f518d2ea-3568-4cf1-9f94-a4828d379c3d",
            "transcript_path": "/Users/u/.claude/projects/p/f518d2ea-3568-4cf1-9f94-a4828d379c3d.jsonl",
            "cwd": "/Users/u/article",
            "hook_event_name": "Stop",
            "stop_hook_active": false,
            "last_assistant_message": "I'm waiting for the 5 translation subagents to finish;\nI'll continue when they report.",
            "background_tasks": tasks,
            "session_crons": []
        })
    }

    const TRANSLATIONS: [(&str, &str); 5] = [
        ("subagent", "Translate de nl sv fi pl"),
        ("subagent", "Translate es pt it fr ro"),
        ("subagent", "Translate ru uk sr el tr"),
        ("subagent", "Translate zh zh-tw ja ko vi"),
        ("subagent", "Translate ar he hi id th"),
    ];

    /// Run weekly-wearton-article.9: the agent ended its turn to wait for 5
    /// background subagents, and the run ended with them.
    #[test]
    fn a_stop_while_background_agents_run_does_not_finish_the_run() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run.events");
        run_hook("UserPromptSubmit", &path, &json!({"hook_event_name": "UserPromptSubmit", "prompt": "write the article"}));
        run_hook("Stop", &path, &stop_input(&TRANSLATIONS));
        let ev = events(&path);
        assert!(ev.started);
        assert!(!ev.turn.finished(), "5 background agents still run: {:?}", std::fs::read_to_string(&path).unwrap());
        assert_eq!(
            ev.turn,
            Turn::Waiting(TRANSLATIONS.iter().map(|(kind, d)| format!("{kind} {d:?}")).collect()),
            "the run log names them"
        );
    }

    #[test]
    fn a_stop_with_no_background_task_finishes_the_run() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run.events");
        run_hook("UserPromptSubmit", &path, &json!({"prompt": "write the article"}));
        run_hook("Stop", &path, &stop_input(&[]));
        assert_eq!(events(&path), Events { started: true, stops: 1, turn: Turn::Done });
    }

    /// The order Claude Code 2.1.316 runs the hooks in, seen with a real
    /// session: a background agent that reports back starts a turn with
    /// UserPromptSubmit, and that turn ends with Stop.
    #[test]
    fn the_run_finishes_at_the_stop_after_the_background_agents_reported() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run.events");
        run_hook("UserPromptSubmit", &path, &json!({"prompt": "write the article"}));
        run_hook("Stop", &path, &stop_input(&TRANSLATIONS));
        assert!(!events(&path).turn.finished());
        run_hook("UserPromptSubmit", &path, &json!({"prompt": "<task-notification>\n<task-id>a0</task-id>\n</task-notification>"}));
        assert_eq!(events(&path).turn, Turn::Working);
        run_hook("Stop", &path, &stop_input(&TRANSLATIONS[1..]));
        assert!(!events(&path).turn.finished(), "4 still run");
        run_hook("UserPromptSubmit", &path, &json!({"prompt": "<task-notification>…</task-notification>"}));
        run_hook("Stop", &path, &stop_input(&[]));
        assert_eq!(events(&path), Events { started: true, stops: 3, turn: Turn::Done });
    }

    /// Seen on 2026-11-02: a subagent started `sleep 25` in the background
    /// and ended its own turn. Only the shell showed that it would go on.
    #[test]
    fn a_background_shell_counts_too() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run.events");
        run_hook("Stop", &path, &stop_input(&[("shell", "Sleep for 25 seconds in background")]));
        assert_eq!(events(&path).turn, Turn::Waiting(vec![r#"shell "Sleep for 25 seconds in background""#.into()]));
    }

    /// A Claude Code that does not send `background_tasks`: the run ends at
    /// the first stop, as before this field was read.
    #[test]
    fn a_stop_input_without_background_tasks_finishes_the_run_as_before() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run.events");
        run_hook("UserPromptSubmit", &path, &json!({"prompt": "write the article"}));
        run_hook("Stop", &path, &json!({"hook_event_name": "Stop", "stop_hook_active": false}));
        assert_eq!(events(&path), Events { started: true, stops: 1, turn: Turn::DoneUnseen });
        assert!(events(&path).turn.finished());
        // No input at all, or input that is not JSON.
        std::fs::write(&path, "prompt\nstop\n").unwrap();
        assert_eq!(events(&path).turn, Turn::DoneUnseen);
        std::fs::write(&path, "prompt\nstop not json\n").unwrap();
        assert_eq!(events(&path).turn, Turn::DoneUnseen);
    }

    /// Only the last line counts: what an earlier stop said is out of date.
    #[test]
    fn an_earlier_stop_input_is_ignored() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run.events");
        // Nothing ran at the first stop; the user typed more, and claude now waits.
        run_hook("Stop", &path, &stop_input(&[]));
        run_hook("UserPromptSubmit", &path, &json!({"prompt": "translate it too"}));
        run_hook("Stop", &path, &stop_input(&TRANSLATIONS[..1]));
        assert_eq!(events(&path).turn, Turn::Waiting(vec![r#"subagent "Translate de nl sv fi pl""#.into()]));
    }

    /// The Stop hook writes `stop `, the input, and the newline separately:
    /// a read in between must not see a finished turn.
    #[test]
    fn a_stop_line_still_being_written_is_not_finished() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run.events");
        std::fs::write(&path, "prompt\nstop ").unwrap();
        assert_eq!(events(&path).turn, Turn::Working);
        std::fs::write(&path, "prompt\nstop {\"background_tasks\":[]}").unwrap();
        assert_eq!(events(&path).turn, Turn::Working);
        std::fs::write(&path, "prompt\nstop {\"background_tasks\":[]}\n").unwrap();
        assert_eq!(events(&path).turn, Turn::Done);
    }

    #[test]
    fn events_from_the_hooks() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run.events");
        let at = |started, stops, turn| Events { started, stops, turn };
        assert_eq!(events(&path), at(false, 0, Turn::Working));
        std::fs::write(&path, "prompt\n").unwrap();
        assert_eq!(events(&path), at(true, 0, Turn::Working));
        std::fs::write(&path, "prompt\nstop {\"background_tasks\":[]}\n").unwrap();
        assert_eq!(events(&path), at(true, 1, Turn::Done));
        // The user typed more after the first answer.
        std::fs::write(&path, "prompt\nstop {\"background_tasks\":[]}\nprompt\n").unwrap();
        assert_eq!(events(&path), at(true, 1, Turn::Working));
    }

    #[test]
    fn a_long_task_description_is_cut_in_the_run_log() {
        let long = "x".repeat(300);
        assert_eq!(task_line(&json!({"type": "subagent", "description": long})), format!("subagent \"{}…\"", "x".repeat(80)));
        assert_eq!(task_line(&json!({})), " \"\"");
    }

    #[test]
    fn empty_lines_are_squeezed() {
        assert_eq!(squeeze("\n\na  \n\n\n\nb\n\n\n"), "a\n\nb");
    }

    #[test]
    fn programs_are_found_in_path() {
        assert_eq!(find("sh", "/nowhere:/bin"), Some(PathBuf::from("/bin/sh")));
        assert_eq!(find("no-such-program-x", "/bin:/usr/bin"), None);
    }
}
