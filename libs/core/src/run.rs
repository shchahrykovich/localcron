//! One execution of a job. The daemon keeps the recent runs in `runs.json`
//! and the output of each in its own log file.

use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Trigger {
    /// The schedule's time came.
    Schedule,
    /// The time passed while the Mac slept or LocalCron was not running.
    CatchUp,
    /// Someone asked: the app, the CLI or an agent.
    Manual,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    /// Waits for a free slot (`max_concurrent`).
    Queued,
    Running,
    /// Exit code 0.
    Succeeded,
    /// Another exit code, a signal, or the program could not start.
    Failed,
    /// Stopped after `timeout_secs`.
    TimedOut,
    /// Stopped by a person or an agent.
    Canceled,
    /// Not started: the job's previous run was still queued or running.
    Skipped,
}

impl RunStatus {
    pub fn is_finished(self) -> bool {
        !matches!(self, RunStatus::Queued | RunStatus::Running)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Run {
    /// `<job id>.<number>`, unique in this data folder.
    pub id: String,
    pub job_id: String,
    pub trigger: Trigger,
    pub status: RunStatus,
    /// The scheduled time this run is for; none for a manual run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due_at: Option<DateTime<FixedOffset>>,
    pub queued_at: DateTime<FixedOffset>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<DateTime<FixedOffset>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<DateTime<FixedOffset>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    /// Absolute path of the output file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub log: Option<String>,
    /// Why it failed, was skipped or stopped.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub message: String,
    /// The command that opens the run's interactive console (tmux), while a
    /// claude job runs in one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub console: Option<String>,
}
