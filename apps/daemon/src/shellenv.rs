//! The environment a run gets. launchd starts the daemon with PATH
//! `/usr/bin:/bin:/usr/sbin:/sbin`, where `claude`, `codex`, `node` and
//! Homebrew tools are missing. So the daemon asks the user's shell for the
//! PATH a terminal has, the way editors do, and keeps the answer for 10
//! minutes.

use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const MARKER: &str = "__LOCALCRON_PATH__=";
const KEEP: Duration = Duration::from_secs(600);
const SHELL_TIMEOUT: Duration = Duration::from_secs(10);
const BASE_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellEnv {
    /// The user's shell; shell jobs run with `<shell> -c <command>`.
    pub shell: String,
    pub path: String,
}

#[derive(Default)]
pub struct ShellEnvCache {
    cached: Mutex<Option<(ShellEnv, Instant)>>,
}

impl ShellEnvCache {
    pub fn get(&self) -> ShellEnv {
        let mut cached = self.cached.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((env, at)) = cached.as_ref()
            && at.elapsed() < KEEP
        {
            return env.clone();
        }
        let env = resolve();
        *cached = Some((env.clone(), Instant::now()));
        env
    }
}

fn user_shell() -> String {
    if let Ok(shell) = std::env::var("SHELL")
        && !shell.is_empty()
    {
        return shell;
    }
    // SAFETY: getpwuid returns a pointer into static storage or null.
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if !pw.is_null() && !(*pw).pw_shell.is_null() {
            return std::ffi::CStr::from_ptr((*pw).pw_shell).to_string_lossy().into_owned();
        }
    }
    "/bin/zsh".into()
}

/// `$LOCALCRON_PATH` wins (tests); otherwise the login shell's PATH.
fn resolve() -> ShellEnv {
    let shell = user_shell();
    let home = std::env::var("HOME").unwrap_or_default();
    let found = std::env::var("LOCALCRON_PATH").ok().or_else(|| ask_shell(&shell));
    ShellEnv { path: with_extras(found.as_deref().unwrap_or(BASE_PATH), &home), shell }
}

/// An interactive login shell reads both ~/.zprofile and ~/.zshrc, where
/// installers add their folders. Its other output is ignored.
fn ask_shell(shell: &str) -> Option<String> {
    let mut command = Command::new(shell);
    command
        .args(["-l", "-i", "-c", &format!("printf '\\n{MARKER}%s\\n' \"$PATH\"")])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    crate::unblock_signals_in_child(&mut command);
    let mut child = command.spawn().ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < SHELL_TIMEOUT => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let mut out = String::new();
    child.stdout.take()?.read_to_string(&mut out).ok()?;
    parse_marker(&out)
}

fn parse_marker(out: &str) -> Option<String> {
    out.lines().rev().find_map(|line| line.strip_prefix(MARKER)).map(str::to_string).filter(|p| !p.is_empty())
}

/// Folders where agent CLIs are often installed, added at the end when the
/// shell did not list them.
fn with_extras(path: &str, home: &str) -> String {
    let mut dirs: Vec<String> = path.split(':').filter(|d| !d.is_empty()).map(str::to_string).collect();
    let mut extras = vec![format!("{home}/.local/bin"), "/opt/homebrew/bin".into(), "/usr/local/bin".into()];
    extras.extend(BASE_PATH.split(':').map(str::to_string));
    for extra in extras {
        if !dirs.contains(&extra) {
            dirs.push(extra);
        }
    }
    dirs.join(":")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marker_is_found_after_shell_noise() {
        let out = "Welcome!\nzsh: no job control\n\n__LOCALCRON_PATH__=/a:/b\n";
        assert_eq!(parse_marker(out).as_deref(), Some("/a:/b"));
        assert_eq!(parse_marker("nothing"), None);
    }

    #[test]
    fn extras_are_added_once() {
        let path = with_extras("/opt/homebrew/bin:/usr/bin", "/Users/me");
        assert_eq!(path, "/opt/homebrew/bin:/usr/bin:/Users/me/.local/bin:/usr/local/bin:/bin:/usr/sbin:/sbin");
    }

    #[test]
    fn the_real_shell_answers() {
        // Uses the shell of whoever runs the tests; it must give some PATH.
        let found = ask_shell(&user_shell());
        assert!(found.is_some_and(|p| p.contains("/usr/bin")));
    }
}
