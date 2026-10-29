//! The daemon's files. Each is written whole to a temporary file and renamed,
//! so a crash leaves the old file or the new one, never half of one.

use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use chrono::{DateTime, FixedOffset};

use localcron_core::api::Config;
use localcron_core::job::Job;
use localcron_core::run::Run;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct JobsFile {
    pub version: u32,
    pub jobs: Vec<Job>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct RunsFile {
    pub version: u32,
    /// The number in the next run id.
    pub next_seq: u64,
    /// Oldest first.
    pub runs: Vec<Run>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct SecretsFile {
    pub version: u32,
    pub secrets: Vec<SecretEntry>,
    /// Jobs the user allowed, in the menu bar app, to read their secrets.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub grants: Vec<Grant>,
}

/// The user allowed this job, as `scope` says it was, to read its secrets.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Grant {
    pub job_id: String,
    /// `Job::secret_scope` when the user allowed it.
    pub scope: String,
    pub allowed_at: DateTime<FixedOffset>,
}

/// What is not secret about a secret. The value is in the Keychain.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SecretEntry {
    pub name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub description: String,
    pub updated_at: DateTime<FixedOffset>,
}

/// Only the user may read the files: a job's command and env can say more
/// than the user wants other accounts on the Mac to see.
pub fn save<T: Serialize>(path: &Path, value: &T) -> io::Result<()> {
    let mut text = serde_json::to_vec_pretty(value).map_err(io::Error::other)?;
    text.push(b'\n');
    let tmp = path.with_extension("json.tmp");
    // One left by a crash keeps its old mode.
    let _ = fs::remove_file(&tmp);
    {
        let mut file = fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp)?;
        file.write_all(&text)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)
}

/// A missing file is the default. A file that cannot be read as JSON is kept
/// next to the new one as `<name>.broken`, and the default is used: the
/// daemon must start, and the user's data must not be lost.
pub fn load<T: DeserializeOwned + Default>(path: &Path) -> (T, Option<String>) {
    let text = match fs::read(path) {
        Ok(text) => text,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return (T::default(), None),
        Err(e) => return (T::default(), Some(format!("cannot read {}: {e}", path.display()))),
    };
    match serde_json::from_slice(&text) {
        Ok(value) => (value, None),
        Err(e) => {
            let broken = path.with_extension("json.broken");
            let _ = fs::rename(path, &broken);
            (T::default(), Some(format!("{} is not valid ({e}); kept it as {}", path.display(), broken.display())))
        }
    }
}

pub fn load_config(path: &Path) -> (Config, Option<String>) {
    let (config, problem): (Config, _) = load(path);
    match config.validate() {
        Ok(()) => (config, problem),
        Err(e) => (Config::default(), Some(format!("{}: {e}; using the defaults", path.display()))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_missing_and_broken() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("jobs.json");
        let (empty, problem): (JobsFile, _) = load(&path);
        assert!(empty.jobs.is_empty() && problem.is_none());

        save(&path, &RunsFile { version: 1, next_seq: 7, runs: vec![] }).unwrap();
        let (runs, _): (RunsFile, _) = load(&path);
        assert_eq!(runs.next_seq, 7);

        fs::write(&path, "{not json").unwrap();
        let (_, problem): (RunsFile, _) = load(&path);
        assert!(problem.unwrap().contains("kept it as"));
        assert!(dir.path().join("jobs.json.broken").exists());
    }
}
