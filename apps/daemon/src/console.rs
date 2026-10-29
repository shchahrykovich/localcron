//! A claude job in an interactive console, when tmux is installed: the user
//! can open the console of a running job (`localcron attach RUN`, Open
//! Terminal in the app), watch Claude Code work and type into it.
//!
//! ```text
//! run thread ─ tmux -L localcron-<run id> new-session -d ─► tmux server ─► claude "<prompt>" (interactive)
//!     │ every 300 ms: the events file, the pane, the attached clients        │ hooks append
//!     └──────────────────────────── events file ◄───────── "prompt" / "stop" ┘
//! ```
//!
//! Each run has its own tmux server, so the run's environment (secrets too)
//! reaches claude as the server's environment, never on a command line. The
//! user's ~/.tmux.conf is not read.
//!
//! The run ends when claude has finished its answer (`stop`) and nobody is
//! attached, or when claude ends. When claude never starts its work (a dialog
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
const SESSION: &str = "run";

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
    label: String,
}

impl Console {
    /// `label` names the tmux server: `localcron-dev-weekly-review.12`.
    pub fn new(tmux: PathBuf, label: String) -> Self {
        Self { tmux, label }
    }

    /// The command that opens the console in a terminal.
    pub fn attach_command(&self) -> String {
        format!("{} -L {} attach -t {SESSION}", self.tmux.display(), self.label)
    }

    fn command(&self) -> Command {
        let mut command = Command::new(&self.tmux);
        command.arg("-L").arg(&self.label).stdin(Stdio::null());
        command
    }

    /// Start `argv` in a new detached session of a new server, in `dir`, with
    /// `env`. The pane stays after claude ends, so its screen can be saved.
    pub fn start(&self, argv: &[String], dir: &str, env: &[(OsString, OsString)]) -> Result<(), String> {
        let mut command = self.command();
        command
            .args(["-f", "/dev/null", "start-server", ";", "set", "-g", "history-limit", "100000", ";"])
            .args(["set", "-g", "remain-on-exit", "on", ";", "new-session", "-d", "-s", SESSION, "-x", "200", "-y", "50", "-c", dir, "--"])
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
        self.query(&["display", "-p", "-t", SESSION, "#{pane_pid}"])?.parse().ok()
    }

    pub fn pane(&self) -> Pane {
        match self.query(&["display", "-p", "-t", SESSION, "#{pane_dead} #{pane_dead_status}"]) {
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
        self.query(&["list-clients", "-t", SESSION]).is_some_and(|out| !out.is_empty())
    }

    /// The screen and its history, as text. A full-screen program leaves
    /// many empty lines: a run of them becomes one.
    pub fn screen(&self) -> String {
        squeeze(&self.query(&["capture-pane", "-p", "-J", "-S", "-", "-t", SESSION]).unwrap_or_default())
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

/// What the claude hooks wrote: did it start its work, is its last answer
/// finished.
pub fn events(path: &Path) -> (bool, bool) {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let started = text.lines().any(|l| l == "prompt");
    let finished = text.lines().next_back() == Some("stop");
    (started, finished)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_from_the_hooks() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run.events");
        assert_eq!(events(&path), (false, false));
        std::fs::write(&path, "prompt\n").unwrap();
        assert_eq!(events(&path), (true, false));
        std::fs::write(&path, "prompt\nstop\n").unwrap();
        assert_eq!(events(&path), (true, true));
        // The user typed more after the first answer.
        std::fs::write(&path, "prompt\nstop\nprompt\n").unwrap();
        assert_eq!(events(&path), (true, false));
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
