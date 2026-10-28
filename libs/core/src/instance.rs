//! An instance is one complete copy of LocalCron: app, daemon, CLI, data
//! folder and links. Its suffix is fixed when the bundle is built: empty for
//! the release, `-dev` for a local build, so a local build runs next to the
//! installed release. Every name is the release name plus the suffix.
//!
//! The Swift app has a copy of these rules (`Instance.swift`). Both are
//! checked against `api/instance-names.json`.

use std::fmt;

/// Longest suffix, dash included. Keeps the socket path under the macOS limit.
pub const MAX_SUFFIX_LEN: usize = 16;

const DAEMON_PROGRAM: &str = "localcrond";
const CLI_PROGRAM: &str = "localcron";

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Instance {
    suffix: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum InstanceError {
    #[error("invalid instance suffix {0:?}: use \"\" or \"-\" followed by 1 to 15 of a-z and 0-9, like \"-dev\"")]
    BadSuffix(String),
    #[error("cannot tell the instance from the program name {0:?}: it must start with localcrond or localcron")]
    BadProgramName(String),
    #[error("cannot find this program's own path: {0}")]
    NoExePath(String),
}

impl Instance {
    pub fn release() -> Self {
        Self { suffix: String::new() }
    }

    pub fn new(suffix: &str) -> Result<Self, InstanceError> {
        if valid_suffix(suffix) {
            Ok(Self { suffix: suffix.to_string() })
        } else {
            Err(InstanceError::BadSuffix(suffix.to_string()))
        }
    }

    /// `localcrond-dev` and `localcron-dev` are `-dev`.
    pub fn from_program_name(name: &str) -> Result<Self, InstanceError> {
        let suffix = name
            .strip_prefix(DAEMON_PROGRAM)
            .or_else(|| name.strip_prefix(CLI_PROGRAM))
            .ok_or_else(|| InstanceError::BadProgramName(name.to_string()))?;
        Self::new(suffix)
    }

    /// The instance of the running program. Links are resolved first, so
    /// `~/.local/bin/localcron-dev` counts as the program in the bundle.
    /// `LOCALCRON_INSTANCE` wins: `cargo run` builds have no suffix in their names.
    pub fn of_this_program() -> Result<Self, InstanceError> {
        if let Ok(suffix) = std::env::var("LOCALCRON_INSTANCE") {
            return Self::new(&suffix);
        }
        let exe = std::env::current_exe().map_err(|e| InstanceError::NoExePath(e.to_string()))?;
        let exe = exe.canonicalize().unwrap_or(exe);
        let name = exe.file_name().and_then(|n| n.to_str()).unwrap_or_default();
        Self::from_program_name(name)
    }

    pub fn suffix(&self) -> &str {
        &self.suffix
    }

    pub fn is_release(&self) -> bool {
        self.suffix.is_empty()
    }

    /// `LocalCron-dev`: the app's name, and the name of its folders.
    pub fn app_name(&self) -> String {
        format!("LocalCron{}", self.suffix)
    }

    pub fn bundle_id(&self) -> String {
        format!("dev.localcron.app{}", self.suffix)
    }

    pub fn daemon_label(&self) -> String {
        format!("{}.daemon", self.bundle_id())
    }

    pub fn daemon_program(&self) -> String {
        format!("{DAEMON_PROGRAM}{}", self.suffix)
    }

    /// The CLI's name, also the MCP server's name.
    pub fn cli(&self) -> String {
        format!("{CLI_PROGRAM}{}", self.suffix)
    }

    /// Relative to the home folder.
    pub fn data_folder(&self) -> String {
        format!("Library/Application Support/{}", self.app_name())
    }

    /// Relative to the home folder.
    pub fn logs_folder(&self) -> String {
        format!("Library/Logs/{}", self.app_name())
    }

    /// The note for Claude Code and Codex, linked into ~/.claude and ~/.codex.
    pub fn note(&self) -> String {
        format!("{}.md", self.app_name())
    }
}

impl fmt::Display for Instance {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.app_name())
    }
}

fn valid_suffix(s: &str) -> bool {
    if s.is_empty() {
        return true;
    }
    let Some(rest) = s.strip_prefix('-') else { return false };
    !rest.is_empty() && s.len() <= MAX_SUFFIX_LEN && rest.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_from_program_names() {
        let dev = Instance::from_program_name("localcrond-dev").unwrap();
        assert_eq!(dev, Instance::from_program_name("localcron-dev").unwrap());
        assert_eq!(dev.app_name(), "LocalCron-dev");
        assert_eq!(dev.daemon_label(), "dev.localcron.app-dev.daemon");
        assert!(Instance::from_program_name("localcron").unwrap().is_release());
        assert!(Instance::from_program_name("cron").is_err());
        assert!(Instance::new("-Dev").is_err());
        assert!(Instance::new("dev").is_err());
        assert!(Instance::new("-").is_err());
    }
}
