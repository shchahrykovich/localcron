//! `localcron mcp`: the MCP server for coding agents, over stdio. Each tool
//! call opens the daemon socket, so this process holds no state and never
//! starts a daemon. Its instructions are the note (`note.md`).

use std::collections::BTreeMap;
use std::path::PathBuf;

use localcron_core::api::{
    CancelRunParams, Empty, GetRunLogParams, IdParams, ListRunsParams, PreviewScheduleParams, SetConfigParams, SetJobEnabledParams, SetJobParams,
};
use localcron_core::instance::Instance;
use localcron_core::job::{DEFAULT_TIMEOUT_SECS, Job, JobKind};
use localcron_core::note;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, ContentBlock, Implementation, ServerCapabilities, ServerConfig};
use rmcp::{ErrorData, ServerHandler, ServiceExt, schemars, tool, tool_handler, tool_router};
use serde::{Deserialize, Serialize};

use crate::client;

// Unknown arguments are refused, not dropped: an argument this server does
// not know would otherwise be lost without a word.
#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AddJobArgs {
    /// a-z, 0-9 and '-', says what the job does: "weekly-deps-check".
    pub id: String,
    /// Local time. Five cron fields "minute hour day-of-month month day-of-week": "0 9 * * wed" is every Wednesday at
    /// 09:00, "30 8 * * mon-fri" weekdays at 08:30. Also @hourly, @daily, @weekly, @monthly, or once: "@at 2026-11-05 09:00".
    pub schedule: String,
    /// "claude" (runs `claude -p <prompt>`), "codex" (runs `codex exec <prompt>`) or "shell" (runs command).
    pub kind: String,
    /// claude and codex: the task. It must stand alone: the agent starts with no memory of this conversation.
    #[serde(default)]
    pub prompt: Option<String>,
    /// shell: the command line.
    #[serde(default)]
    pub command: Option<String>,
    /// Absolute working folder. Default: the folder this MCP server runs in (your project).
    #[serde(default)]
    pub dir: Option<String>,
    /// claude and codex: the model, for example "sonnet".
    #[serde(default)]
    pub model: Option<String>,
    /// claude: --permission-mode, for example "acceptEdits". Only when the user agrees: a scheduled run has nobody to approve tools.
    #[serde(default)]
    pub permission_mode: Option<String>,
    /// claude and codex: more arguments, for example ["--allowedTools", "Read Edit Bash(git *)"].
    #[serde(default)]
    pub args: Option<Vec<String>>,
    /// Environment variables for the run. Not for tokens or keys: use secret_env.
    #[serde(default)]
    pub env: Option<BTreeMap<String, String>>,
    /// Variable name to secret name, for tokens and keys: {"GH_TOKEN": "github-token"}. Names only: the user sets the
    /// value in a terminal with the set_command the reply gives in missing_secrets. Never ask for the value.
    #[serde(default)]
    pub secret_env: Option<BTreeMap<String, String>>,
    /// Stop the run after this many minutes. Default 60.
    #[serde(default)]
    pub timeout_minutes: Option<u64>,
    /// Run once after the Mac wakes when a time was missed. Default true.
    #[serde(default)]
    pub catch_up: Option<bool>,
    /// Save the job turned off. Default true (on).
    #[serde(default)]
    pub enabled: Option<bool>,
    /// Why the job exists, for the user.
    #[serde(default)]
    pub note: Option<String>,
    /// Change the job when the id exists. Without it an existing id is an error.
    #[serde(default)]
    pub replace: Option<bool>,
}

impl AddJobArgs {
    pub fn into_params(self, cwd: Option<PathBuf>) -> Result<SetJobParams, String> {
        let kind = JobKind::parse(&self.kind)?;
        let dir = match self.dir {
            Some(d) => d,
            None => cwd.ok_or("give dir: this server cannot tell its folder")?.to_string_lossy().into_owned(),
        };
        let job = Job {
            id: self.id,
            schedule: self.schedule,
            kind,
            command: self.command,
            prompt: self.prompt,
            model: self.model,
            permission_mode: self.permission_mode,
            args: self.args.unwrap_or_default(),
            dir,
            env: self.env.unwrap_or_default(),
            secret_env: self.secret_env.unwrap_or_default(),
            timeout_secs: self.timeout_minutes.map_or(DEFAULT_TIMEOUT_SECS, |m| m * 60),
            enabled: self.enabled.unwrap_or(true),
            catch_up: self.catch_up.unwrap_or(true),
            note: self.note.unwrap_or_default(),
            updated_at: None,
        };
        Ok(SetJobParams { job, replace: self.replace.unwrap_or(false) })
    }
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct JobIdArgs {
    /// The job id.
    pub id: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EnableArgs {
    /// The job id.
    pub id: String,
    /// true runs it on its schedule, false keeps it but never runs it.
    pub enabled: bool,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CancelArgs {
    /// The run id, for example "weekly-review.12".
    pub run_id: String,
    /// SIGKILL now, without waiting. Also for a run that is already stopping. Default false.
    #[serde(default)]
    pub force: Option<bool>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PausedArgs {
    /// true: no scheduled run starts. false: the schedules run again.
    pub paused: bool,
}

#[derive(Debug, Default, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ListRunsArgs {
    /// Only this job's runs.
    #[serde(default)]
    pub job_id: Option<String>,
    /// Newest first. Default 20.
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RunLogArgs {
    /// The run id, for example "weekly-review.12".
    pub run_id: String,
    /// At most this many bytes from the end of the output. Default 64 KiB.
    #[serde(default)]
    pub max_bytes: Option<u64>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PreviewArgs {
    /// A schedule as add_job takes it.
    pub schedule: String,
    /// How many next times. Default 5.
    #[serde(default)]
    pub count: Option<usize>,
}

#[derive(Debug, Default, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct NoArgs {}

#[derive(Clone)]
pub struct LocalCronMcp {
    socket: PathBuf,
    instance: Instance,
    tool_router: ToolRouter<Self>,
}

fn text_result(value: serde_json::Value) -> CallToolResult {
    CallToolResult::success(vec![ContentBlock::text(serde_json::to_string_pretty(&value).unwrap_or_default())])
}

fn error_result(message: impl ToString) -> CallToolResult {
    CallToolResult::error(vec![ContentBlock::text(message.to_string())])
}

#[tool_router]
impl LocalCronMcp {
    pub fn new(socket: PathBuf, instance: Instance) -> Self {
        Self { socket, instance, tool_router: Self::tool_router() }
    }

    /// The socket calls block; they run on the blocking pool.
    async fn call(&self, method: &'static str, params: impl Serialize + Send + 'static) -> CallToolResult {
        let socket = self.socket.clone();
        let result = tokio::task::spawn_blocking(move || client::call_value(&socket, "mcp", method, params)).await;
        match result {
            Ok(Ok(v)) => text_result(v),
            Ok(Err(e)) => error_result(e),
            Err(e) => error_result(e),
        }
    }

    #[tool(description = "Create a job that runs on a schedule: a Claude Code or Codex agent with a prompt, or a \
shell command. Returns the job with schedule_text (the schedule in words) and next_run: tell the user both. An \
existing id is an error unless replace is true. missing_secrets lists secrets in secret_env that are not set: give \
the user each set_command to run in their own terminal, with --description saying how to make a new value. \
secrets_allowed false: the user must allow the job in the menu bar app before its runs get the secrets; tell them.")]
    async fn add_job(&self, Parameters(args): Parameters<AddJobArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(match args.into_params(std::env::current_dir().ok()) {
            Ok(params) => self.call("set_job", params).await,
            Err(e) => error_result(e),
        })
    }

    #[tool(description = "List all jobs with their schedule in words, next run, last run and a run in progress.")]
    async fn list_jobs(&self, Parameters(_): Parameters<NoArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(self.call("list_jobs", Empty {}).await)
    }

    #[tool(description = "One job with its schedule in words, next run, last run and a run in progress.")]
    async fn get_job(&self, Parameters(args): Parameters<JobIdArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(self.call("get_job", IdParams { id: args.id }).await)
    }

    #[tool(description = "Remove a job, its run history and its logs. A run in progress is stopped. Returns \
removed=false when there is no such job.")]
    async fn remove_job(&self, Parameters(args): Parameters<JobIdArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(self.call("remove_job", IdParams { id: args.id }).await)
    }

    #[tool(description = "Turn a job on (it runs on its schedule) or off (it is kept but never runs).")]
    async fn enable_job(&self, Parameters(args): Parameters<EnableArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(self.call("set_job_enabled", SetJobEnabledParams { id: args.id, enabled: args.enabled }).await)
    }

    #[tool(description = "Run a job now, outside its schedule. Returns the run: status queued (it waits for a free \
slot), or skipped when the job is already running. Check it later with list_runs and get_run_log.")]
    async fn run_job(&self, Parameters(args): Parameters<JobIdArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(self.call("run_job", IdParams { id: args.id }).await)
    }

    #[tool(description = "Stop a queued or running run. Its process and every process it started get SIGTERM, then \
SIGKILL after 10 seconds; with force, SIGKILL now.")]
    async fn cancel_run(&self, Parameters(args): Parameters<CancelArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(self.call("cancel_run", CancelRunParams { run_id: args.run_id, force: args.force.unwrap_or(false) }).await)
    }

    #[tool(description = "Pause or resume every schedule. While paused no scheduled run starts and queued \
scheduled runs are canceled; run_job still works and running runs go on. Times missed while paused are not caught \
up. Only when the user asks. Returns the settings with paused.")]
    async fn set_paused(&self, Parameters(args): Parameters<PausedArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(self.call("set_config", SetConfigParams { paused: Some(args.paused), ..Default::default() }).await)
    }

    #[tool(description = "Recent runs, newest first: status (queued, running, succeeded, failed, timed_out, \
canceled, skipped), trigger (schedule, catch_up, manual), times, exit code and the log file.")]
    async fn list_runs(&self, Parameters(args): Parameters<ListRunsArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(self.call("list_runs", ListRunsParams { job_id: args.job_id, limit: Some(args.limit.unwrap_or(20)) }).await)
    }

    #[tool(description = "The output of a run (stdout and stderr together), the end of it when it is long.")]
    async fn get_run_log(&self, Parameters(args): Parameters<RunLogArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(self.call("get_run_log", GetRunLogParams { run_id: args.run_id, max_bytes: args.max_bytes }).await)
    }

    #[tool(description = "Check a schedule before adding a job: the schedule in words and its next run times, or \
why it is not valid.")]
    async fn preview_schedule(&self, Parameters(args): Parameters<PreviewArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(self.call("preview_schedule", PreviewScheduleParams { schedule: args.schedule, count: args.count }).await)
    }

    #[tool(description = "The secrets jobs can use in secret_env: name, description (how to make a new value), \
state (ok, missing, unreadable), the jobs that use it, and set_command for the user. Never the values: no tool \
sets or returns a value.")]
    async fn list_secrets(&self, Parameters(_): Parameters<NoArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(self.call("list_secrets", Empty {}).await)
    }

    #[tool(description = "Daemon version, number of jobs, runs in progress and queued, the most runs at once, \
paused, and the next run.")]
    async fn status(&self, Parameters(_): Parameters<NoArgs>) -> Result<CallToolResult, ErrorData> {
        Ok(self.call("status", Empty {}).await)
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for LocalCronMcp {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new(self.instance.cli(), env!("CARGO_PKG_VERSION")))
            .with_instructions(note::render(&self.instance))
    }
}

pub async fn run(socket: PathBuf, instance: Instance) -> anyhow::Result<()> {
    let service = LocalCronMcp::new(socket, instance).serve(rmcp::transport::stdio()).await?;
    service.waiting().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(json: serde_json::Value) -> AddJobArgs {
        serde_json::from_value(json).unwrap()
    }

    #[test]
    fn dir_defaults_to_the_server_folder_and_minutes_become_seconds() {
        let p = args(serde_json::json!({"id": "a", "schedule": "@daily", "kind": "claude", "prompt": "hi", "timeout_minutes": 5}))
            .into_params(Some(PathBuf::from("/Users/me/shop")))
            .unwrap();
        assert_eq!(p.job.dir, "/Users/me/shop");
        assert_eq!(p.job.timeout_secs, 300);
        assert_eq!(p.job.kind, JobKind::Claude);
        assert!(!p.replace && p.job.enabled && p.job.catch_up);
    }

    #[test]
    fn secret_env_takes_names_and_there_is_no_field_for_a_value() {
        let p = args(serde_json::json!({"id": "a", "schedule": "@daily", "kind": "shell", "command": "ls", "dir": "/tmp",
            "secret_env": {"GH_TOKEN": "github-token"}}))
        .into_params(None)
        .unwrap();
        assert_eq!(p.job.secret_env["GH_TOKEN"], "github-token");
        let bad: Result<AddJobArgs, _> = serde_json::from_value(serde_json::json!({"id": "a", "schedule": "@daily",
            "kind": "shell", "command": "ls", "secrets": {"github-token": "ghp_x"}}));
        assert!(bad.is_err());
    }

    #[test]
    fn unknown_kind_and_unknown_fields_are_refused() {
        let e = args(serde_json::json!({"id": "a", "schedule": "@daily", "kind": "python"})).into_params(None).unwrap_err();
        assert!(e.contains("shell, claude or codex"));
        let bad: Result<AddJobArgs, _> = serde_json::from_value(serde_json::json!({"id": "a", "schedule": "@daily", "kind": "shell", "cmd": "ls"}));
        assert!(bad.is_err());
    }
}
