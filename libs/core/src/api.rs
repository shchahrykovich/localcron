//! Socket API types: newline-delimited JSON over `daemon.sock`.
//!
//! One line in: `{"id": 1, "method": "list_jobs", "params": {}}`.
//! One line out: `{"id": 1, "result": {...}}` or `{"id": 1, "error": {...}}`.
//!
//! The Swift app keeps its own copy of these shapes. Every file in
//! `api/examples/` must decode on both sides.

use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::job::Job;
use crate::run::Run;

/// Major.minor. A client stops when the major number differs.
pub const API_VERSION: &str = "1.2";

pub fn api_major(version: &str) -> Option<u32> {
    version.split('.').next()?.parse().ok()
}

pub const METHODS: [&str; 18] = [
    "hello",
    "status",
    "list_jobs",
    "get_job",
    "set_job",
    "remove_job",
    "set_job_enabled",
    "run_job",
    "cancel_run",
    "list_runs",
    "get_run_log",
    "preview_schedule",
    "get_config",
    "set_config",
    "list_secrets",
    "set_secret",
    "remove_secret",
    "allow_job_secrets",
];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub id: u64,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Response {
    pub id: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<ApiError>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    BadRequest,
    UnknownMethod,
    NotFound,
    Exists,
    Invalid,
    /// Only the menu bar app may do this, after the user confirms.
    NotAllowed,
    VersionMismatch,
    Internal,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, thiserror::Error)]
#[error("{message}")]
pub struct ApiError {
    pub code: ErrorCode,
    pub message: String,
}

impl ApiError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Empty {}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HelloParams {
    pub client: String,
    pub api_version: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HelloResult {
    pub daemon_version: String,
    pub api_version: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NextRun {
    pub job_id: String,
    pub at: DateTime<FixedOffset>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StatusResult {
    pub daemon_version: String,
    pub api_version: String,
    pub pid: u32,
    pub started_at: DateTime<FixedOffset>,
    pub jobs: usize,
    pub enabled_jobs: usize,
    pub running: usize,
    pub queued: usize,
    pub max_concurrent: u32,
    /// Scheduled runs do not start (`Config::paused`).
    #[serde(default)]
    pub paused: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next: Option<NextRun>,
    pub data_dir: String,
    pub logs_dir: String,
}

/// A job with what the daemon knows about it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JobView {
    #[serde(flatten)]
    pub job: Job,
    /// The schedule in plain English: "At 09:00 on Wednesday".
    pub schedule_text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_run: Option<DateTime<FixedOffset>>,
    /// The newest finished run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run: Option<Run>,
    /// A run that is queued or running now.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_run: Option<Run>,
    /// For a job with `secret_env`: the user allowed it, in the menu bar app,
    /// to read its secrets as it is now. Its runs fail until then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secrets_allowed: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ListJobsResult {
    pub jobs: Vec<JobView>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IdParams {
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetJobParams {
    pub job: Job,
    /// Without it an existing id is an error, so a job is never replaced by
    /// accident.
    #[serde(default)]
    pub replace: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetJobResult {
    pub job: JobView,
    pub created: bool,
    /// Secrets in `secret_env` that are not set yet. The job is saved; its
    /// runs fail until the user sets them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub missing_secrets: Vec<MissingSecret>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MissingSecret {
    pub name: String,
    /// The variable in `secret_env` that wants it.
    pub env: String,
    /// For the user to run in a terminal: `localcron secret set github-token`.
    pub set_command: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JobResult {
    pub job: JobView,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RemoveJobResult {
    pub removed: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetJobEnabledParams {
    pub id: String,
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunResult {
    pub run: Run,
}

fn is_false(b: &bool) -> bool {
    !*b
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CancelRunParams {
    pub run_id: String,
    /// SIGKILL now, without the SIGTERM and the grace time. Also works on a
    /// run that is already stopping.
    #[serde(default, skip_serializing_if = "is_false")]
    pub force: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CancelRunResult {
    /// False when the run had already finished, or was already being
    /// stopped (killed, with `force`).
    pub canceled: bool,
    pub run: Run,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ListRunsParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
    /// Newest first. Default 50.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ListRunsResult {
    pub runs: Vec<Run>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GetRunLogParams {
    pub run_id: String,
    /// The end of the file, at most this many bytes. Default 64 KiB.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GetRunLogResult {
    pub run: Run,
    pub text: String,
    /// The file is longer than `text`: only its end is here.
    pub truncated: bool,
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreviewScheduleParams {
    pub schedule: String,
    /// Default 5.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub count: Option<usize>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreviewScheduleResult {
    pub description: String,
    pub next: Vec<DateTime<FixedOffset>>,
}

pub const DEFAULT_MAX_CONCURRENT: u32 = 2;
pub const DEFAULT_KEEP_RUNS: u32 = 20;

fn default_max_concurrent() -> u32 {
    DEFAULT_MAX_CONCURRENT
}

fn default_keep_runs() -> u32 {
    DEFAULT_KEEP_RUNS
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Config {
    /// Runs at the same time. More wait in a queue.
    #[serde(default = "default_max_concurrent")]
    pub max_concurrent: u32,
    /// Finished runs kept per job, with their log files.
    #[serde(default = "default_keep_runs")]
    pub keep_runs: u32,
    /// No scheduled run starts. A run someone asks for (run_job) still does.
    #[serde(default)]
    pub paused: bool,
    /// The last resume. A time before it is not caught up: it was missed on
    /// purpose.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resumed_at: Option<DateTime<FixedOffset>>,
}

impl Default for Config {
    fn default() -> Self {
        Self { max_concurrent: DEFAULT_MAX_CONCURRENT, keep_runs: DEFAULT_KEEP_RUNS, paused: false, resumed_at: None }
    }
}

impl Config {
    pub fn validate(&self) -> Result<(), String> {
        if !(1..=16).contains(&self.max_concurrent) {
            return Err("max_concurrent must be 1 to 16".into());
        }
        if !(1..=1000).contains(&self.keep_runs) {
            return Err("keep_runs must be 1 to 1000".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SetConfigParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_concurrent: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keep_runs: Option<u32>,
    /// Pause (true) or resume (false) every schedule.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paused: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SecretState {
    /// The daemon can read the value.
    Ok,
    /// No value in the Keychain: it was removed there, or never set.
    Missing,
    /// The Keychain has a value the daemon cannot read without a dialog: it
    /// is locked, or another build of the daemon stored the value.
    Unreadable,
}

/// A secret without its value. No reply has the value.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SecretInfo {
    pub name: String,
    /// How to get a new value: where the token was made, its scopes, when it
    /// expires.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub description: String,
    pub updated_at: DateTime<FixedOffset>,
    pub state: SecretState,
    /// Why the state is not ok.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub message: String,
    /// The jobs that name it in `secret_env`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub used_by: Vec<String>,
    /// For the user to run in a terminal to set a new value.
    pub set_command: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ListSecretsResult {
    pub secrets: Vec<SecretInfo>,
}

/// Without `value` only the description changes, and the secret must exist.
/// Without `description` a new secret has none and an existing one keeps its
/// own.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct SetSecretParams {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

// Never print the value, also not by accident in a log line.
impl std::fmt::Debug for SetSecretParams {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SetSecretParams")
            .field("name", &self.name)
            .field("value", &self.value.as_ref().map(|_| "<hidden>"))
            .field("description", &self.description)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetSecretResult {
    pub secret: SecretInfo,
    pub created: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NameParams {
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RemoveSecretResult {
    pub removed: bool,
    /// Jobs that still name it; their runs fail until it is set again.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub used_by: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debug_hides_the_value() {
        let p = SetSecretParams { name: "a".into(), value: Some("ghp_secret".into()), description: None };
        let text = format!("{p:?}");
        assert!(!text.contains("ghp_secret") && text.contains("<hidden>"), "{text}");
    }
}

/// The menu bar app sends it after the user confirms: the job as the user
/// saw it. When what the job runs has changed since, it is refused.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AllowJobSecretsParams {
    pub job: Job,
}
