//! `localcron`: command-line tool and MCP server for the LocalCron daemon.

mod client;
mod mcp;
mod secret_input;

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use anyhow::{Context, bail};
use chrono::{DateTime, FixedOffset, Local};
use clap::{Args, Parser, Subcommand};
use localcron_core::api::{
    CancelRunParams, Config, Empty, GetRunLogParams, GetRunLogResult, IdParams, JobResult, JobView, ListJobsResult, ListRunsParams,
    ListRunsResult, ListSecretsResult, NameParams, PreviewScheduleParams, PreviewScheduleResult, RemoveSecretResult, RunResult,
    SecretInfo, SecretState, SetConfigParams, SetJobEnabledParams, SetJobParams, SetJobResult, SetSecretParams, SetSecretResult,
    StatusResult,
};
use localcron_core::instance::Instance;
use localcron_core::job::{DEFAULT_TIMEOUT_SECS, Job, JobKind};
use localcron_core::paths::Paths;
use localcron_core::run::{Run, RunStatus};
use serde_json::Value;

#[derive(Parser)]
#[command(name = "localcron", version, about = "Run shell commands, Claude Code and Codex on a schedule.")]
struct Cli {
    /// Print the daemon's JSON reply.
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
// Parsed once per process: the size of the add variant does not matter.
#[allow(clippy::large_enum_variant)]
enum Command {
    /// Daemon version, jobs, runs and the next run.
    Status,
    /// List the jobs.
    List,
    /// Show one job.
    Show { id: String },
    /// Add a job, or change it with --replace.
    Add(AddArgs),
    /// Remove a job and its run history.
    Remove { id: String },
    /// Turn a job on.
    Enable { id: String },
    /// Turn a job off: it keeps its settings but does not run.
    Disable { id: String },
    /// Run a job now.
    Run {
        id: String,
        /// Wait for the end, print the output, and exit with the run's exit code.
        #[arg(long)]
        wait: bool,
    },
    /// Stop a queued or running run: SIGTERM, then SIGKILL after 10 s.
    Cancel {
        run_id: String,
        /// SIGKILL now, also when the run is already stopping.
        #[arg(long)]
        kill: bool,
    },
    /// Pause every schedule: no scheduled run starts until resume. `run` still works.
    Pause,
    /// Resume the schedules. Times missed while paused are not caught up.
    Resume,
    /// Recent runs, newest first.
    Runs {
        job_id: Option<String>,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    /// The output of a run.
    Log {
        run_id: String,
        /// At most this many bytes from the end.
        #[arg(long)]
        bytes: Option<u64>,
    },
    /// The next times of a schedule: localcron next "0 9 * * wed".
    Next {
        schedule: String,
        #[arg(long, default_value_t = 5)]
        count: usize,
    },
    /// Show or change the settings.
    Config {
        /// Runs at the same time; more wait in a queue.
        #[arg(long)]
        max_concurrent: Option<u32>,
        /// Finished runs kept per job.
        #[arg(long)]
        keep_runs: Option<u32>,
    },
    /// Values for jobs, such as API tokens, kept in the macOS Keychain.
    #[command(subcommand)]
    Secret(SecretCommand),
    /// The MCP server for coding agents, over stdio.
    Mcp,
    /// Print the note for Claude Code and Codex.
    Guide,
    /// Print the note (used by the app build).
    #[command(hide = true)]
    Note,
}

#[derive(Subcommand)]
enum SecretCommand {
    /// Store a value in the Keychain. It is asked for with no echo, or read
    /// from stdin: `pbpaste | localcron secret set NAME`. There is no
    /// argument for it, so it never stays in the shell history.
    Set {
        /// Letters, digits, '.', '_' and '-': github-token.
        name: String,
        /// How to make a new value: where, which scopes, when it expires.
        #[arg(long)]
        description: Option<String>,
    },
    /// Change only the description.
    Describe { name: String, description: String },
    /// The secrets, without their values.
    List,
    /// Remove a secret and its value.
    Remove { name: String },
}

#[derive(Args)]
struct AddArgs {
    /// a-z, 0-9 and '-': weekly-deps-check.
    id: String,
    /// Cron in local time ("0 9 * * wed"), @daily, @weekly, or "@at 2026-11-05 09:00".
    #[arg(long, short)]
    schedule: String,
    /// A shell command.
    #[arg(long, group = "what")]
    command: Option<String>,
    /// A Claude Code prompt: runs `claude -p <prompt>`.
    #[arg(long, group = "what")]
    claude: Option<String>,
    /// A Codex prompt: runs `codex exec <prompt>`.
    #[arg(long, group = "what")]
    codex: Option<String>,
    /// Working folder. Default: the current folder.
    #[arg(long)]
    dir: Option<PathBuf>,
    #[arg(long)]
    model: Option<String>,
    /// Claude only: acceptEdits, bypassPermissions, plan, …
    #[arg(long)]
    permission_mode: Option<String>,
    /// One more argument for claude or codex. Repeat it.
    #[arg(long = "arg", allow_hyphen_values = true)]
    args: Vec<String>,
    /// NAME=VALUE. Repeat it.
    #[arg(long = "env")]
    env: Vec<String>,
    /// NAME=SECRET: the variable NAME gets the value of the secret SECRET.
    /// Repeat it. Set the value with `localcron secret set SECRET`.
    #[arg(long = "secret-env")]
    secret_env: Vec<String>,
    /// 90s, 30m, 2h. Default 1h.
    #[arg(long)]
    timeout: Option<String>,
    /// Do not run a time missed while the Mac slept.
    #[arg(long)]
    no_catch_up: bool,
    /// Save it turned off.
    #[arg(long)]
    disabled: bool,
    #[arg(long)]
    note: Option<String>,
    /// Change the job if the id exists.
    #[arg(long)]
    replace: bool,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let instance = match Instance::of_this_program() {
        Ok(i) => i,
        Err(e) => {
            eprintln!("localcron: {e}");
            return ExitCode::from(2);
        }
    };
    let paths = Paths::from_env(&instance);
    match run(cli, &instance, &paths) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("{}: {e:#}", instance.cli());
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli, instance: &Instance, paths: &Paths) -> anyhow::Result<ExitCode> {
    let socket = paths.socket();
    let json = cli.json;
    let show = |value: &Value| -> anyhow::Result<()> {
        println!("{}", serde_json::to_string_pretty(value)?);
        Ok(())
    };
    let call = |method: &str, params: Value| client::call_value(&socket, "cli", method, params);
    match cli.command {
        Command::Mcp => {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
            runtime.block_on(mcp::run(socket.clone(), instance.clone()))?;
        }
        Command::Note | Command::Guide => print!("{}", localcron_core::note::render(instance)),
        Command::Status => {
            let v = call("status", serde_json::to_value(Empty {})?)?;
            if json {
                show(&v)?;
            } else {
                let s: StatusResult = serde_json::from_value(v)?;
                println!("{} {} (pid {}), running since {}", instance.daemon_program(), s.daemon_version, s.pid, when(&s.started_at));
                println!("jobs: {} ({} on), running: {}, queued: {}, max at once: {}", s.jobs, s.enabled_jobs, s.running, s.queued, s.max_concurrent);
                if s.paused {
                    println!("paused: scheduled runs do not start ({} resume)", instance.cli());
                }
                if let Some(next) = s.next {
                    println!("next: {} {}", next.job_id, when(&next.at));
                }
                println!("data: {}\nlogs: {}", s.data_dir, s.logs_dir);
            }
        }
        Command::List => {
            let v = call("list_jobs", serde_json::to_value(Empty {})?)?;
            if json {
                show(&v)?;
            } else {
                let list: ListJobsResult = serde_json::from_value(v)?;
                if list.jobs.is_empty() {
                    println!("No jobs. Add one: {} add <id> --schedule \"0 9 * * wed\" --claude \"<prompt>\"", instance.cli());
                }
                for job in &list.jobs {
                    print_job_line(job);
                }
            }
        }
        Command::Show { id } => {
            let v = call("get_job", serde_json::to_value(IdParams { id })?)?;
            if json {
                show(&v)?;
            } else {
                print_job(&serde_json::from_value::<JobResult>(v)?.job);
            }
        }
        Command::Add(args) => {
            let replace = args.replace;
            let job = args.into_job()?;
            let v = call("set_job", serde_json::to_value(SetJobParams { job, replace })?)?;
            if json {
                show(&v)?;
            } else {
                let r: SetJobResult = serde_json::from_value(v)?;
                println!("{} {}", if r.created { "Added" } else { "Changed" }, r.job.job.id);
                print_job(&r.job);
                if !r.missing_secrets.is_empty() {
                    println!("\nNot set yet; its runs fail until you run:");
                    for m in &r.missing_secrets {
                        println!("  {}", m.set_command);
                    }
                }
            }
        }
        Command::Remove { id } => {
            let v = call("remove_job", serde_json::to_value(IdParams { id: id.clone() })?)?;
            if json {
                show(&v)?;
            } else if v["removed"] == true {
                println!("Removed {id}");
            } else {
                bail!("no job {id:?}");
            }
        }
        Command::Enable { id } => set_enabled(&call, &id, true, json)?,
        Command::Disable { id } => set_enabled(&call, &id, false, json)?,
        Command::Run { id, wait } => {
            let v = call("run_job", serde_json::to_value(IdParams { id })?)?;
            let run = serde_json::from_value::<RunResult>(v.clone())?.run;
            if !wait {
                if json {
                    show(&v)?;
                } else {
                    println!("{} {}{}", run.id, status_word(run.status), message_part(&run));
                }
                return Ok(ExitCode::SUCCESS);
            }
            if run.status == RunStatus::Skipped {
                bail!("{} was skipped: {}", run.id, run.message);
            }
            let done = wait_for_run(&socket, &run.id)?;
            let log: GetRunLogResult =
                client::call(&socket, "get_run_log", GetRunLogParams { run_id: done.id.clone(), max_bytes: Some(1024 * 1024) })?;
            print!("{}", log.text);
            if json {
                show(&serde_json::to_value(&done)?)?;
            }
            return Ok(match (done.status, done.exit_code) {
                (RunStatus::Succeeded, _) => ExitCode::SUCCESS,
                (_, Some(code)) if (1..=255).contains(&code) => ExitCode::from(code as u8),
                _ => ExitCode::FAILURE,
            });
        }
        Command::Cancel { run_id, kill } => {
            let v = call("cancel_run", serde_json::to_value(CancelRunParams { run_id: run_id.clone(), force: kill })?)?;
            if json {
                show(&v)?;
            } else if v["canceled"] == true {
                println!("{} {run_id}", if kill { "Killing" } else { "Stopping" });
            } else if v["run"]["status"] == "running" {
                println!("{run_id} is already {}", if kill { "killed" } else { "stopping; --kill ends it now" });
            } else {
                println!("{run_id} has already ended");
            }
        }
        Command::Pause => set_paused(&call, instance, true, json)?,
        Command::Resume => set_paused(&call, instance, false, json)?,
        Command::Runs { job_id, limit } => {
            let v = call("list_runs", serde_json::to_value(ListRunsParams { job_id, limit: Some(limit) })?)?;
            if json {
                show(&v)?;
            } else {
                let list: ListRunsResult = serde_json::from_value(v)?;
                if list.runs.is_empty() {
                    println!("No runs yet.");
                }
                for run in &list.runs {
                    print_run_line(run);
                }
            }
        }
        Command::Log { run_id, bytes } => {
            let v = call("get_run_log", serde_json::to_value(GetRunLogParams { run_id, max_bytes: bytes })?)?;
            if json {
                show(&v)?;
            } else {
                let log: GetRunLogResult = serde_json::from_value(v)?;
                if log.truncated {
                    eprintln!("(the last {} of {} bytes)", log.text.len(), log.size);
                }
                print!("{}", log.text);
            }
        }
        Command::Next { schedule, count } => {
            let v = call("preview_schedule", serde_json::to_value(PreviewScheduleParams { schedule, count: Some(count) })?)?;
            if json {
                show(&v)?;
            } else {
                let p: PreviewScheduleResult = serde_json::from_value(v)?;
                println!("{}", p.description);
                for t in &p.next {
                    println!("  {}", when(t));
                }
            }
        }
        Command::Secret(command) => secret(&call, instance, command, json)?,
        Command::Config { max_concurrent, keep_runs } => {
            let v = if max_concurrent.is_none() && keep_runs.is_none() {
                call("get_config", serde_json::to_value(Empty {})?)?
            } else {
                call("set_config", serde_json::to_value(SetConfigParams { max_concurrent, keep_runs, paused: None })?)?
            };
            if json {
                show(&v)?;
            } else {
                let c: Config = serde_json::from_value(v)?;
                println!("max_concurrent: {}\nkeep_runs: {}\npaused: {}", c.max_concurrent, c.keep_runs, c.paused);
            }
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn secret(
    call: &dyn Fn(&str, Value) -> Result<Value, client::ClientError>,
    instance: &Instance,
    command: SecretCommand,
    json: bool,
) -> anyhow::Result<()> {
    let show = |v: &Value| -> anyhow::Result<()> {
        println!("{}", serde_json::to_string_pretty(v)?);
        Ok(())
    };
    match command {
        SecretCommand::Set { name, description } => {
            localcron_core::secret::check_name(&name).map_err(anyhow::Error::msg)?;
            let value = secret_input::read_value(&name)?;
            let v = call("set_secret", serde_json::to_value(SetSecretParams { name, value: Some(value), description })?)?;
            if json {
                return show(&v);
            }
            let r: SetSecretResult = serde_json::from_value(v)?;
            println!("{} {} in the Keychain.", if r.created { "Stored" } else { "Replaced" }, r.secret.name);
            if r.secret.description.is_empty() {
                println!("Add how to make a new one: {} secret describe {} \"<where, scopes, expiry>\"", instance.cli(), r.secret.name);
            }
            if !r.secret.used_by.is_empty() {
                println!("Used by: {}", r.secret.used_by.join(", "));
            }
        }
        SecretCommand::Describe { name, description } => {
            let v = call("set_secret", serde_json::to_value(SetSecretParams { name, value: None, description: Some(description) })?)?;
            if json {
                return show(&v);
            }
            print_secret(&serde_json::from_value::<SetSecretResult>(v)?.secret);
        }
        SecretCommand::List => {
            let v = call("list_secrets", serde_json::to_value(Empty {})?)?;
            if json {
                return show(&v);
            }
            let list: ListSecretsResult = serde_json::from_value(v)?;
            if list.secrets.is_empty() {
                println!("No secrets. Add one: {} secret set <name> --description \"<how to make a new one>\"", instance.cli());
            }
            for s in &list.secrets {
                print_secret(s);
            }
        }
        SecretCommand::Remove { name } => {
            let v = call("remove_secret", serde_json::to_value(NameParams { name: name.clone() })?)?;
            if json {
                return show(&v);
            }
            let r: RemoveSecretResult = serde_json::from_value(v)?;
            if !r.removed {
                bail!("no secret {name:?}");
            }
            println!("Removed {name}");
            if !r.used_by.is_empty() {
                println!("Still named by {}: their runs fail until it is set again.", r.used_by.join(", "));
            }
        }
    }
    Ok(())
}

fn print_secret(s: &SecretInfo) {
    let state = match s.state {
        SecretState::Ok => "ok".to_string(),
        SecretState::Missing => format!("missing: {}", s.message),
        SecretState::Unreadable => format!("cannot be read: {}", s.message),
    };
    let used = if s.used_by.is_empty() { String::new() } else { format!(", used by {}", s.used_by.join(", ")) };
    println!("{:<24} {state} (set {}{used})", s.name, when(&s.updated_at));
    if !s.description.is_empty() {
        println!("    {}", s.description);
    }
    if s.state != SecretState::Ok {
        println!("    set it again: {}", s.set_command);
    }
}

fn set_enabled(
    call: &dyn Fn(&str, Value) -> Result<Value, client::ClientError>,
    id: &str,
    enabled: bool,
    json: bool,
) -> anyhow::Result<()> {
    let v = call("set_job_enabled", serde_json::to_value(SetJobEnabledParams { id: id.into(), enabled })?)?;
    if json {
        println!("{}", serde_json::to_string_pretty(&v)?);
    } else {
        let job = serde_json::from_value::<JobResult>(v)?.job;
        print_job_line(&job);
    }
    Ok(())
}

fn set_paused(
    call: &dyn Fn(&str, Value) -> Result<Value, client::ClientError>,
    instance: &Instance,
    paused: bool,
    json: bool,
) -> anyhow::Result<()> {
    let v = call("set_config", serde_json::to_value(SetConfigParams { paused: Some(paused), ..Default::default() })?)?;
    if json {
        println!("{}", serde_json::to_string_pretty(&v)?);
    } else if paused {
        println!("Paused: no scheduled run starts until {} resume.", instance.cli());
    } else {
        println!("Resumed. Times missed while paused are not caught up.");
    }
    Ok(())
}

fn wait_for_run(socket: &std::path::Path, run_id: &str) -> anyhow::Result<Run> {
    loop {
        let runs: ListRunsResult = client::call(socket, "list_runs", ListRunsParams { job_id: None, limit: Some(1000) })?;
        let run = runs.runs.into_iter().find(|r| r.id == run_id).with_context(|| format!("run {run_id} is gone"))?;
        if run.status.is_finished() {
            return Ok(run);
        }
        std::thread::sleep(Duration::from_millis(300));
    }
}

impl AddArgs {
    fn into_job(self) -> anyhow::Result<Job> {
        let (kind, command, prompt) = match (self.command, self.claude, self.codex) {
            (Some(c), None, None) => (JobKind::Shell, Some(c), None),
            (None, Some(p), None) => (JobKind::Claude, None, Some(p)),
            (None, None, Some(p)) => (JobKind::Codex, None, Some(p)),
            _ => bail!("give one of --command, --claude or --codex"),
        };
        let dir = match self.dir {
            Some(d) => std::path::absolute(d)?,
            None => std::env::current_dir()?,
        };
        let mut env = BTreeMap::new();
        for pair in self.env {
            let (k, v) = pair.split_once('=').with_context(|| format!("--env {pair:?}: use NAME=VALUE"))?;
            env.insert(k.to_string(), v.to_string());
        }
        let mut secret_env = BTreeMap::new();
        for pair in self.secret_env {
            let (k, v) = pair.split_once('=').with_context(|| format!("--secret-env {pair:?}: use NAME=SECRET"))?;
            secret_env.insert(k.to_string(), v.to_string());
        }
        let timeout_secs = match self.timeout {
            Some(t) => parse_duration(&t)?,
            None => DEFAULT_TIMEOUT_SECS,
        };
        Ok(Job {
            id: self.id,
            schedule: self.schedule,
            kind,
            command,
            prompt,
            model: self.model,
            permission_mode: self.permission_mode,
            args: self.args,
            dir: dir.to_string_lossy().into_owned(),
            env,
            secret_env,
            timeout_secs,
            enabled: !self.disabled,
            catch_up: !self.no_catch_up,
            note: self.note.unwrap_or_default(),
            updated_at: None,
        })
    }
}

/// `90s`, `30m`, `2h`, or a number of seconds.
fn parse_duration(text: &str) -> anyhow::Result<u64> {
    let text = text.trim();
    let (number, unit) = match text.char_indices().find(|(_, c)| !c.is_ascii_digit()) {
        Some((i, _)) => text.split_at(i),
        None => (text, "s"),
    };
    let n: u64 = number.parse().with_context(|| format!("{text:?}: use 90s, 30m or 2h"))?;
    let factor = match unit {
        "s" => 1,
        "m" => 60,
        "h" => 3600,
        "d" => 86400,
        _ => bail!("{text:?}: use 90s, 30m or 2h"),
    };
    Ok(n * factor)
}

fn when(t: &DateTime<FixedOffset>) -> String {
    t.with_timezone(&Local).format("%a %-d %b %H:%M").to_string()
}

fn status_word(status: RunStatus) -> &'static str {
    match status {
        RunStatus::Queued => "queued",
        RunStatus::Running => "running",
        RunStatus::Succeeded => "succeeded",
        RunStatus::Failed => "failed",
        RunStatus::TimedOut => "timed out",
        RunStatus::Canceled => "canceled",
        RunStatus::Skipped => "skipped",
    }
}

fn message_part(run: &Run) -> String {
    if run.message.is_empty() { String::new() } else { format!(": {}", run.message) }
}

fn print_job_line(job: &JobView) {
    let state = if !job.job.enabled {
        "off".to_string()
    } else if let Some(run) = &job.active_run {
        status_word(run.status).to_string()
    } else {
        job.next_run.as_ref().map_or("no next run".into(), |t| format!("next {}", when(t)))
    };
    let last = job.last_run.as_ref().map_or(String::new(), |r| format!(", last {}", status_word(r.status)));
    println!("{:<24} {:<7} {} ({state}{last})", job.job.id, job.job.kind_name(), job.schedule_text);
}

fn print_job(job: &JobView) {
    let j = &job.job;
    println!("id:        {}", j.id);
    println!("schedule:  {} ({})", j.schedule, job.schedule_text);
    println!("enabled:   {}", j.enabled);
    if let Some(t) = &job.next_run {
        println!("next run:  {}", when(t));
    }
    println!("runs:      {}", j.command_line("$SHELL"));
    println!("in:        {}", j.dir);
    println!("timeout:   {} s, catch up: {}", j.timeout_secs, j.catch_up);
    for (k, v) in &j.env {
        println!("env:       {k}={v}");
    }
    for (k, name) in &j.secret_env {
        println!("secret:    {k} from {name}");
    }
    if job.secrets_allowed == Some(false) {
        println!("secrets:   not allowed yet: allow this job in the menu bar app (Jobs, Allow Secrets)");
    }
    if !j.note.is_empty() {
        println!("note:      {}", j.note);
    }
    if let Some(r) = &job.active_run {
        println!("now:       {} {}", r.id, status_word(r.status));
    }
    if let Some(r) = &job.last_run {
        println!("last run:  {} {}{}", r.id, status_word(r.status), message_part(r));
    }
}

fn print_run_line(run: &Run) {
    let started = run.started_at.as_ref().or(Some(&run.queued_at)).map(when).unwrap_or_default();
    let took = match (&run.started_at, &run.ended_at) {
        (Some(a), Some(b)) => format!(" {}s", (*b - *a).num_seconds()),
        _ => String::new(),
    };
    let code = run.exit_code.map_or(String::new(), |c| format!(" exit {c}"));
    println!("{:<30} {:<10} {started}{took}{code}{}", run.id, status_word(run.status), message_part(run));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations() {
        assert_eq!(parse_duration("90").unwrap(), 90);
        assert_eq!(parse_duration("30m").unwrap(), 1800);
        assert_eq!(parse_duration("2h").unwrap(), 7200);
        assert!(parse_duration("soon").is_err());
        assert!(parse_duration("5y").is_err());
    }
}
