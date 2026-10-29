//! LocalCron core: no I/O except where a function says so.
//!
//! - `schedule`: cron expressions, `@at` and `@in` one-shot times, next run time.
//! - `job`: what a job runs and how its fields are checked.
//! - `run`: one execution of a job.
//! - `api`: socket API types, shared by the daemon and the CLI.
//! - `instance`, `paths`: names and folders of this copy of LocalCron.
//! - `note`: the text for Claude Code and Codex; `help`: the help page.

pub mod api;
pub mod dotenv;
pub mod instance;
pub mod job;
pub mod help;
pub mod note;
pub mod paths;
pub mod run;
pub mod schedule;
pub mod secret_file;
pub mod secret;
