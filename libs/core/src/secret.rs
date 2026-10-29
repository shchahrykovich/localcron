//! Secrets: values a job gets as environment variables, such as an API token.
//!
//! The value lives in the macOS Keychain; only the daemon writes and reads it,
//! and no reply ever has it. What is not secret lives in `secrets.json`: the
//! name, a description that says how to make a new value, and the time it was
//! set. A job names the secrets it needs in `secret_env`.
//!
//! A value comes from the user's terminal (`localcron secret set NAME`) or the
//! menu bar app, never from an agent: an agent's chat goes to its model.

use crate::instance::Instance;

/// A token or a key is small. The limit keeps a request under the socket's
/// line limit.
pub const MAX_VALUE: usize = 64 * 1024;
pub const MAX_DESCRIPTION: usize = 500;

/// 1 to 64 of letters, digits, '.', '_' and '-', not first '-' or '.':
/// `github-token`, `OPENAI_API_KEY`. Safe in a shell command without quotes.
pub fn check_name(name: &str) -> Result<(), String> {
    let ok = !name.is_empty()
        && name.len() <= 64
        && !name.starts_with(['-', '.'])
        && name.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c));
    if ok { Ok(()) } else { Err(format!("secret name {name:?}: use 1 to 64 of letters, digits, '.', '_' and '-', like \"github-token\"")) }
}

pub fn check_description(description: &str) -> Result<(), String> {
    if description.chars().count() > MAX_DESCRIPTION {
        return Err(format!("description: at most {MAX_DESCRIPTION} characters"));
    }
    Ok(())
}

pub fn check_value(value: &str) -> Result<(), String> {
    if value.is_empty() {
        return Err("the value is empty".into());
    }
    if value.len() > MAX_VALUE {
        return Err(format!("the value is longer than {MAX_VALUE} bytes"));
    }
    // An environment variable cannot hold one.
    if value.contains('\0') {
        return Err("the value has a NUL byte".into());
    }
    Ok(())
}

/// The command the user runs in a terminal to set the value:
/// `localcron-dev secret set github-token`.
pub fn set_command(instance: &Instance, name: &str) -> String {
    format!("{} secret set {name}", instance.cli())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        for good in ["github-token", "OPENAI_API_KEY", "a", "v1.2"] {
            assert!(check_name(good).is_ok(), "{good}");
        }
        for bad in ["", "-x", ".x", "a b", "a/b", "a$b", &"a".repeat(65)] {
            assert!(check_name(bad).unwrap_err().contains("secret name"), "{bad}");
        }
    }

    #[test]
    fn values_and_descriptions() {
        assert!(check_value("ghp_x").is_ok());
        assert!(check_value("").is_err());
        assert!(check_value("a\0b").is_err());
        assert!(check_value(&"x".repeat(MAX_VALUE + 1)).is_err());
        assert!(check_description(&"é".repeat(MAX_DESCRIPTION)).is_ok());
        assert!(check_description(&"é".repeat(MAX_DESCRIPTION + 1)).is_err());
    }

    #[test]
    fn the_command_names_the_instance() {
        assert_eq!(set_command(&Instance::new("-dev").unwrap(), "github-token"), "localcron-dev secret set github-token");
        assert_eq!(set_command(&Instance::release(), "a"), "localcron secret set a");
    }
}
