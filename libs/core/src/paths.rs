//! Where an instance keeps its files.
//!
//! ```text
//! ~/Library/Application Support/LocalCron/   jobs.json, runs.json, config.json, daemon.sock, daemon.lock
//! ~/Library/Logs/LocalCron/                  daemon.log, runs/<job id>/<run id>.log
//! ```
//!
//! `$LOCALCRON_HOME` puts both under one folder, so tests never touch ~/Library.

use std::ffi::OsString;
use std::path::PathBuf;

use crate::instance::Instance;

/// macOS limits a Unix socket path to 104 bytes including the final NUL.
pub const MAX_SOCKET_PATH: usize = 103;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Paths {
    pub data: PathBuf,
    pub logs: PathBuf,
}

impl Paths {
    pub fn from_env(instance: &Instance) -> Self {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"));
        Self::resolve(instance, std::env::var_os("LOCALCRON_HOME"), home)
    }

    pub fn resolve(instance: &Instance, local_home: Option<OsString>, home: PathBuf) -> Self {
        match local_home.filter(|h| !h.is_empty()) {
            Some(root) => Self::under(PathBuf::from(root)),
            None => Self { data: home.join(instance.data_folder()), logs: home.join(instance.logs_folder()) },
        }
    }

    pub fn under(root: PathBuf) -> Self {
        Self { logs: root.join("logs"), data: root }
    }

    pub fn jobs(&self) -> PathBuf {
        self.data.join("jobs.json")
    }

    pub fn runs(&self) -> PathBuf {
        self.data.join("runs.json")
    }

    pub fn config(&self) -> PathBuf {
        self.data.join("config.json")
    }

    pub fn socket(&self) -> PathBuf {
        self.data.join("daemon.sock")
    }

    pub fn lock(&self) -> PathBuf {
        self.data.join("daemon.lock")
    }

    pub fn daemon_log(&self) -> PathBuf {
        self.logs.join("daemon.log")
    }

    pub fn run_logs(&self, job_id: &str) -> PathBuf {
        self.logs.join("runs").join(job_id)
    }

    /// Why the socket cannot be bound, or None.
    pub fn socket_path_problem(&self) -> Option<String> {
        let len = self.socket().as_os_str().len();
        (len > MAX_SOCKET_PATH).then(|| format!("the socket path {} is {len} bytes, more than macOS allows ({MAX_SOCKET_PATH})", self.socket().display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folders_per_instance_and_override() {
        let home = PathBuf::from("/Users/me");
        let p = Paths::resolve(&Instance::new("-dev").unwrap(), None, home.clone());
        assert_eq!(p.data, PathBuf::from("/Users/me/Library/Application Support/LocalCron-dev"));
        assert_eq!(p.run_logs("a"), PathBuf::from("/Users/me/Library/Logs/LocalCron-dev/runs/a"));
        let t = Paths::resolve(&Instance::release(), Some("/tmp/x".into()), home);
        assert_eq!(t.socket(), PathBuf::from("/tmp/x/daemon.sock"));
        assert_eq!(t.logs, PathBuf::from("/tmp/x/logs"));
        assert!(t.socket_path_problem().is_none());
    }
}
