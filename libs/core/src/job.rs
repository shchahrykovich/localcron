//! A job: a schedule and what to run. The daemon owns the list (`jobs.json`).
//!
//! Three kinds:
//! - `shell`: `command` runs with the user's shell, `$SHELL -c <command>`.
//! - `claude`: Claude Code without a terminal, `claude -p [options] <prompt>`.
//! - `codex`: Codex without a terminal, `codex exec [options] <prompt>`.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize};

use crate::icon;
use crate::schedule::Schedule;
use crate::secret;

/// One hour. An agent that is still busy after that is likely stuck.
pub const DEFAULT_TIMEOUT_SECS: u64 = 3600;
pub const MAX_TIMEOUT_SECS: u64 = 7 * 24 * 3600;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobKind {
    Shell,
    Claude,
    Codex,
}

impl JobKind {
    pub fn parse(text: &str) -> Result<Self, String> {
        match text {
            "shell" => Ok(JobKind::Shell),
            "claude" => Ok(JobKind::Claude),
            "codex" => Ok(JobKind::Codex),
            other => Err(format!("unknown kind {other:?}: use shell, claude or codex")),
        }
    }
}

fn default_timeout() -> u64 {
    DEFAULT_TIMEOUT_SECS
}

fn yes() -> bool {
    true
}

fn is_false(b: &bool) -> bool {
    !*b
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Job {
    /// a-z, 0-9 and '-': `weekly-deps-check`.
    pub id: String,
    /// A cron expression or `@at YYYY-MM-DD HH:MM[:SS]`, in local time. The
    /// daemon saves `@in 20m` as `@at`.
    pub schedule: String,
    pub kind: JobKind,
    /// `shell` only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// `claude` and `codex` only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    /// `claude` and `codex`: `--model`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// `claude` only: `--permission-mode`, for example `acceptEdits`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_mode: Option<String>,
    /// `claude` and `codex`: more arguments before the prompt.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    /// Absolute working folder.
    pub dir: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    /// Variable name to secret name: `{"GH_TOKEN": "github-token"}`. The
    /// daemon reads the value from the Keychain when the run starts.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub secret_env: BTreeMap<String, String>,
    #[serde(default = "default_timeout")]
    pub timeout_secs: u64,
    #[serde(default = "yes")]
    pub enabled: bool,
    /// Run once when the Mac wakes or LocalCron starts after a missed time.
    #[serde(default = "yes")]
    pub catch_up: bool,
    /// Why the job exists.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub note: String,
    /// An SVG drawing the menu bar app shows for the job, cleaned by
    /// `icon::clean_svg`. None: the default icon of its kind. In `set_job`
    /// with `replace`, None keeps the old icon and "" removes it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    /// Draw the icon in its own colors. Without it the app draws its shape
    /// in the text color.
    #[serde(default, skip_serializing_if = "is_false")]
    pub icon_colors: bool,
    /// Set by the daemon when the job is saved or turned on. Missed times
    /// before it are never caught up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<DateTime<FixedOffset>>,
}

impl Job {
    /// Checks every field that does not need the file system. Returns the
    /// parsed schedule.
    pub fn validate(&self) -> Result<Schedule, String> {
        check_id(&self.id)?;
        let schedule = Schedule::parse(&self.schedule).map_err(|e| e.0)?;
        let has = |v: &Option<String>| v.as_deref().is_some_and(|s| !s.trim().is_empty());
        match self.kind {
            JobKind::Shell => {
                if !has(&self.command) {
                    return Err("a shell job needs command".into());
                }
                if self.prompt.is_some() || self.model.is_some() || self.permission_mode.is_some() || !self.args.is_empty() {
                    return Err("a shell job takes command only: put everything in command; prompt, model, permission_mode and args are for claude and codex".into());
                }
            }
            JobKind::Claude | JobKind::Codex => {
                if !has(&self.prompt) {
                    return Err(format!("a {} job needs prompt", self.kind_name()));
                }
                if self.command.is_some() {
                    return Err(format!("a {} job takes prompt, not command", self.kind_name()));
                }
                // It would be read as an option.
                if self.prompt.as_deref().is_some_and(|p| p.trim_start().starts_with('-')) {
                    return Err("prompt must not start with '-'".into());
                }
                if self.kind == JobKind::Codex && self.permission_mode.is_some() {
                    return Err("permission_mode is for claude; give codex options in args, for example [\"--full-auto\"]".into());
                }
            }
        }
        if let Some(mode) = &self.permission_mode
            && (mode.is_empty() || mode.contains(char::is_whitespace))
        {
            return Err(format!("permission_mode {mode:?} is not a mode name"));
        }
        if !Path::new(&self.dir).is_absolute() {
            return Err(format!("dir must be an absolute path, not {:?}", self.dir));
        }
        for key in self.env.keys().chain(self.secret_env.keys()) {
            let ok = !key.is_empty()
                && !key.starts_with(|c: char| c.is_ascii_digit())
                && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
            if !ok {
                return Err(format!("env name {key:?}: use letters, digits and _"));
            }
        }
        for (key, name) in &self.secret_env {
            if self.env.contains_key(key) {
                return Err(format!("{key} is in env and in secret_env; keep it in one"));
            }
            secret::check_name(name)?;
        }
        if let Some(svg) = &self.icon {
            icon::clean_svg(svg)?;
        }
        if self.timeout_secs == 0 || self.timeout_secs > MAX_TIMEOUT_SECS {
            return Err(format!("timeout_secs must be 1 to {MAX_TIMEOUT_SECS} (7 days)"));
        }
        Ok(schedule)
    }

    pub fn kind_name(&self) -> &'static str {
        match self.kind {
            JobKind::Shell => "shell",
            JobKind::Claude => "claude",
            JobKind::Codex => "codex",
        }
    }

    /// The program and its arguments. `shell` is the user's login shell.
    /// `session`: the id a claude run gets for its session (`--session-id`),
    /// so its transcript, and the tokens it used, can be found after it.
    pub fn argv(&self, shell: &str, session: Option<&str>) -> (String, Vec<String>) {
        let prompt = self.prompt.clone().unwrap_or_default();
        match self.kind {
            JobKind::Shell => (shell.to_string(), vec!["-c".into(), self.command.clone().unwrap_or_default()]),
            JobKind::Claude => {
                let mut args = vec!["-p".to_string()];
                if let Some(id) = session {
                    args.extend(["--session-id".into(), id.to_string()]);
                }
                if let Some(model) = &self.model {
                    args.extend(["--model".into(), model.clone()]);
                }
                if let Some(mode) = &self.permission_mode {
                    args.extend(["--permission-mode".into(), mode.clone()]);
                }
                args.extend(self.args.iter().cloned());
                args.push(prompt);
                ("claude".into(), args)
            }
            JobKind::Codex => {
                let mut args = vec!["exec".to_string()];
                if let Some(model) = &self.model {
                    args.extend(["--model".into(), model.clone()]);
                }
                args.extend(self.args.iter().cloned());
                args.push(prompt);
                ("codex".into(), args)
            }
        }
    }

    /// A claude job in an interactive console (tmux): `claude` without `-p`,
    /// the same options, no AskUserQuestion (nobody may answer), and hooks
    /// that append `prompt` (the agent started) and `stop` (it finished its
    /// answer) to the file in `$LOCALCRON_EVENTS`.
    pub fn console_argv(&self, session: Option<&str>) -> Vec<String> {
        let mut args = vec!["claude".to_string()];
        if let Some(id) = session {
            args.extend(["--session-id".into(), id.to_string()]);
        }
        if let Some(model) = &self.model {
            args.extend(["--model".into(), model.clone()]);
        }
        if let Some(mode) = &self.permission_mode {
            args.extend(["--permission-mode".into(), mode.clone()]);
        }
        args.extend(self.args.iter().cloned());
        let event = |name: &str| serde_json::json!([{"hooks": [{"type": "command", "command": format!("printf '{name}\\n' >> \"$LOCALCRON_EVENTS\"")}]}]);
        let settings = serde_json::json!({"hooks": {"UserPromptSubmit": event("prompt"), "Stop": event("stop")}});
        args.extend(["--disallowedTools".into(), "AskUserQuestion".into(), "--settings".into(), settings.to_string()]);
        args.push(self.prompt.clone().unwrap_or_default());
        args
    }

    /// One line for the run header of a console run: without the hook
    /// settings, which say nothing to a person.
    pub fn console_command_line(&self) -> String {
        let args = self.console_argv(None);
        let mut shown = Vec::new();
        let mut skip = false;
        for a in &args {
            if skip {
                skip = false;
                continue;
            }
            if a == "--settings" {
                skip = true;
                continue;
            }
            shown.push(quote(a));
        }
        format!("{} (in a console)", shown.join(" "))
    }

    /// What the user allows when a job may read its secrets: everything that
    /// decides what the run does with them. A change to any of it needs a new
    /// approval; the schedule, timeout, note and on/off do not.
    pub fn secret_scope(&self) -> String {
        serde_json::json!({
            "kind": self.kind,
            "command": self.command,
            "prompt": self.prompt,
            "model": self.model,
            "permission_mode": self.permission_mode,
            "args": self.args,
            "dir": self.dir,
            "env": self.env,
            "secret_env": self.secret_env,
        })
        .to_string()
    }

    /// A claude run may get its own session id: not when its own arguments
    /// already choose a session (`--resume`, `--continue`, `--session-id`).
    pub fn names_its_session(&self) -> bool {
        const TAKEN: [&str; 6] = ["--session-id", "--resume", "-r", "--continue", "-c", "--fork-session"];
        self.kind == JobKind::Claude
            && !self.args.iter().any(|a| TAKEN.contains(&a.as_str()) || TAKEN.iter().any(|t| a.starts_with(&format!("{t}="))))
    }

    /// One line for logs and the run header.
    pub fn command_line(&self, shell: &str) -> String {
        let (program, args) = self.argv(shell, None);
        std::iter::once(program).chain(args.into_iter().map(|a| quote(&a))).collect::<Vec<_>>().join(" ")
    }
}

pub fn check_id(id: &str) -> Result<(), String> {
    let ok = !id.is_empty()
        && id.len() <= 64
        && !id.starts_with('-')
        && !id.ends_with('-')
        && id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
    if ok { Ok(()) } else { Err(format!("job id {id:?}: use 1 to 64 of a-z, 0-9 and '-', like \"weekly-deps-check\"")) }
}

/// Shell quoting, for display only.
fn quote(s: &str) -> String {
    if !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:@".contains(c)) {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub fn claude_job() -> Job {
        Job {
            id: "weekly-review".into(),
            schedule: "0 9 * * wed".into(),
            kind: JobKind::Claude,
            command: None,
            prompt: Some("Review open PRs".into()),
            model: Some("sonnet".into()),
            permission_mode: Some("acceptEdits".into()),
            args: vec!["--max-turns".into(), "20".into()],
            dir: "/Users/me/shop".into(),
            env: BTreeMap::new(),
            secret_env: BTreeMap::new(),
            timeout_secs: 600,
            enabled: true,
            catch_up: true,
            note: String::new(),
            icon: None,
            icon_colors: false,
            updated_at: None,
        }
    }

    #[test]
    fn claude_argv_puts_the_prompt_last() {
        let (program, args) = claude_job().argv("/bin/zsh", None);
        assert_eq!(program, "claude");
        assert_eq!(
            args,
            ["-p", "--model", "sonnet", "--permission-mode", "acceptEdits", "--max-turns", "20", "Review open PRs"]
        );
    }

    #[test]
    fn a_claude_run_gets_its_session_id_unless_its_arguments_choose_one() {
        let job = claude_job();
        assert!(job.names_its_session());
        assert_eq!(&job.argv("/bin/zsh", Some("abc")).1[..3], ["-p", "--session-id", "abc"]);
        assert_eq!(&job.console_argv(Some("abc"))[..3], ["claude", "--session-id", "abc"]);
        assert!(!job.command_line("/bin/zsh").contains("--session-id"), "the run header has no session id");
        for args in [vec!["--continue"], vec!["-r", "x"], vec!["--resume=x"], vec!["--session-id", "y"]] {
            let job = Job { args: args.iter().map(|a| a.to_string()).collect(), ..claude_job() };
            assert!(!job.names_its_session(), "{args:?}");
        }
        assert!(!Job { kind: JobKind::Codex, ..claude_job() }.names_its_session());
    }

    #[test]
    fn codex_and_shell_argv() {
        let mut job = claude_job();
        job.kind = JobKind::Codex;
        job.permission_mode = None;
        job.args = vec!["--full-auto".into()];
        assert_eq!(job.argv("/bin/zsh", None).1, ["exec", "--model", "sonnet", "--full-auto", "Review open PRs"]);

        let shell = Job { kind: JobKind::Shell, command: Some("make test".into()), prompt: None, model: None, permission_mode: None, args: vec![], ..claude_job() };
        assert_eq!(shell.argv("/bin/zsh", None), ("/bin/zsh".to_string(), vec!["-c".to_string(), "make test".to_string()]));
        assert!(shell.validate().is_ok());
        assert_eq!(shell.command_line("/bin/zsh"), "/bin/zsh -c 'make test'");
    }

    #[test]
    fn validation() {
        assert!(claude_job().validate().is_ok());
        let bad = |f: fn(&mut Job)| {
            let mut j = claude_job();
            f(&mut j);
            j.validate().unwrap_err()
        };
        assert!(bad(|j| j.id = "Weekly".into()).contains("job id"));
        assert!(bad(|j| j.id = "-x".into()).contains("job id"));
        assert!(bad(|j| j.schedule = "0 9 * *".into()).contains("5 fields"));
        assert!(bad(|j| j.prompt = None).contains("needs prompt"));
        assert!(bad(|j| j.prompt = Some("--help".into())).contains("'-'"));
        assert!(bad(|j| j.command = Some("ls".into())).contains("not command"));
        assert!(bad(|j| j.dir = "shop".into()).contains("absolute"));
        assert!(bad(|j| j.timeout_secs = 0).contains("timeout_secs"));
        assert!(bad(|j| {
            j.env.insert("1A".into(), "x".into());
        })
        .contains("env name"));
        assert!(bad(|j| {
            j.secret_env.insert("GH-TOKEN".into(), "github-token".into());
        })
        .contains("env name"));
        assert!(bad(|j| {
            j.secret_env.insert("GH_TOKEN".into(), "github token".into());
        })
        .contains("secret name"));
        assert!(bad(|j| {
            j.env.insert("GH_TOKEN".into(), "x".into());
            j.secret_env.insert("GH_TOKEN".into(), "github-token".into());
        })
        .contains("in env and in secret_env"));
        assert!(bad(|j| {
            j.kind = JobKind::Codex;
        })
        .contains("permission_mode is for claude"));
        assert!(bad(|j| {
            j.kind = JobKind::Shell;
            j.command = Some("ls".into());
        })
        .contains("command only"));
        assert!(bad(|j| j.icon = Some("<html/>".into())).contains("no <svg>"));
    }

    #[test]
    fn json_defaults() {
        let job: Job = serde_json::from_str(r#"{"id":"a","schedule":"@daily","kind":"shell","command":"ls","dir":"/tmp"}"#).unwrap();
        assert!(job.enabled && job.catch_up);
        assert_eq!(job.timeout_secs, DEFAULT_TIMEOUT_SECS);
        let text = serde_json::to_string(&job).unwrap();
        assert!(!text.contains("prompt") && !text.contains("env"), "{text}");
    }

    #[test]
    fn the_secret_scope_changes_with_what_the_run_does_only() {
        let job = claude_job();
        let scope = job.secret_scope();
        let same = Job {
            schedule: "@daily".into(),
            timeout_secs: 5,
            enabled: false,
            catch_up: false,
            note: "n".into(),
            icon: Some("<svg/>".into()),
            icon_colors: true,
            ..job.clone()
        };
        assert_eq!(same.secret_scope(), scope);
        for changed in [
            Job { prompt: Some("Print $GH_TOKEN".into()), ..job.clone() },
            Job { args: vec![], ..job.clone() },
            Job { dir: "/tmp".into(), ..job.clone() },
            Job { permission_mode: None, ..job.clone() },
            Job { env: [("A".to_string(), "1".to_string())].into(), ..job.clone() },
            Job { secret_env: [("A".to_string(), "b".to_string())].into(), ..job.clone() },
        ] {
            assert_ne!(changed.secret_scope(), scope);
        }
    }

    #[test]
    fn the_console_runs_claude_without_print_and_with_hooks() {
        let args = claude_job().console_argv(None);
        assert_eq!(&args[..5], ["claude", "--model", "sonnet", "--permission-mode", "acceptEdits"]);
        assert!(!args.contains(&"-p".to_string()));
        assert_eq!(args.last().unwrap(), "Review open PRs", "the prompt is last");
        let i = args.iter().position(|a| a == "--settings").unwrap();
        let settings: serde_json::Value = serde_json::from_str(&args[i + 1]).unwrap();
        assert_eq!(settings["hooks"]["Stop"][0]["hooks"][0]["command"], "printf 'stop\\n' >> \"$LOCALCRON_EVENTS\"");
        assert_eq!(settings["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"], "printf 'prompt\\n' >> \"$LOCALCRON_EVENTS\"");
        assert!(args.windows(2).any(|w| w == ["--disallowedTools", "AskUserQuestion"]));
        assert!(args.windows(2).any(|w| w == ["--max-turns", "20"]), "the job's own arguments");
        assert_eq!(
            claude_job().console_command_line(),
            "claude --model sonnet --permission-mode acceptEdits --max-turns 20 --disallowedTools AskUserQuestion 'Review open PRs' (in a console)"
        );
    }

    #[test]
    fn secret_env_holds_names_only() {
        let mut job = claude_job();
        job.secret_env.insert("GH_TOKEN".into(), "github-token".into());
        assert!(job.validate().is_ok());
        let text = serde_json::to_string(&job).unwrap();
        assert!(text.contains(r#""secret_env":{"GH_TOKEN":"github-token"}"#), "{text}");
    }
}
