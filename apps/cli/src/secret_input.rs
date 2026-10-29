//! The value for `secret set`: typed at a prompt with echo off, or read
//! from stdin when it is not a terminal (`pbpaste | localcron secret set x`).
//! It is never an argument, so it does not stay in the shell history or show
//! in `ps`.

use std::io::{BufRead, Read, Write};
use std::path::Path;

use anyhow::{Context, bail};
use localcron_core::secret_file::{self, Format};

pub fn read_value(name: &str) -> anyhow::Result<String> {
    // SAFETY: isatty only reads the descriptor.
    let value = if unsafe { libc::isatty(0) } == 1 { prompt(name)? } else { from_reader(std::io::stdin().lock())? };
    localcron_core::secret::check_value(&value).map_err(anyhow::Error::msg)?;
    Ok(value)
}

/// The value at `key` in a file of settings (`file`, a named pipe, or
/// stdin), in `format` or the one its name says. A named pipe is opened and
/// read once: 1Password Environments asks the user at each read.
pub fn read_from_file(key: &str, file: Option<&Path>, format: Option<&str>) -> anyhow::Result<String> {
    let format = match (format, file) {
        (Some(f), _) => Format::parse(f).map_err(anyhow::Error::msg)?,
        (None, Some(path)) => Format::of_path(path),
        (None, None) => Format::Env,
    };
    let text = match file {
        Some(path) => std::fs::read_to_string(path).with_context(|| format!("cannot read {}", path.display()))?,
        None => {
            // SAFETY: isatty only reads the descriptor.
            if unsafe { libc::isatty(0) } == 1 {
                bail!("pipe the file in (cat .env | …) or give --file PATH");
            }
            let mut text = String::new();
            std::io::stdin().lock().read_to_string(&mut text).context("cannot read stdin")?;
            text
        }
    };
    let value = secret_file::lookup(format, &text, key).map_err(anyhow::Error::msg)?;
    localcron_core::secret::check_value(&value).map_err(|e| anyhow::anyhow!("{key}: {e}"))?;
    Ok(value)
}

/// All of it, without the one line end that `echo` and `op read` add.
fn from_reader(mut input: impl Read) -> anyhow::Result<String> {
    let mut value = String::new();
    input.read_to_string(&mut value).context("cannot read the value from stdin")?;
    if value.ends_with('\n') {
        value.pop();
        if value.ends_with('\r') {
            value.pop();
        }
    }
    if value.is_empty() {
        bail!("stdin was empty: type the value at the prompt, or pipe it in");
    }
    Ok(value)
}

fn prompt(name: &str) -> anyhow::Result<String> {
    eprint!("Value for {name} (not shown): ");
    std::io::stderr().flush()?;
    let line = {
        let _echo = EchoOff::new()?;
        let mut line = String::new();
        std::io::stdin().lock().read_line(&mut line).context("cannot read the value")?;
        line
    };
    eprintln!();
    let value = line.trim_end_matches(['\n', '\r']).to_string();
    if value.is_empty() {
        bail!("no value typed");
    }
    Ok(value)
}

/// Turns the terminal's echo off until dropped.
struct EchoOff(libc::termios);

impl EchoOff {
    fn new() -> anyhow::Result<Self> {
        // SAFETY: termios is plain data; tcgetattr fills it.
        let mut old: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(0, &mut old) } != 0 {
            bail!("cannot read the terminal settings: {}", std::io::Error::last_os_error());
        }
        let mut quiet = old;
        quiet.c_lflag &= !libc::ECHO;
        // SAFETY: a valid termios for fd 0.
        if unsafe { libc::tcsetattr(0, libc::TCSANOW, &quiet) } != 0 {
            bail!("cannot turn off the echo: {}", std::io::Error::last_os_error());
        }
        Ok(Self(old))
    }
}

impl Drop for EchoOff {
    fn drop(&mut self) {
        // SAFETY: restores the settings read in new.
        unsafe { libc::tcsetattr(0, libc::TCSANOW, &self.0) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_line_end_is_removed() {
        assert_eq!(from_reader(&b"ghp_x\n"[..]).unwrap(), "ghp_x");
        assert_eq!(from_reader(&b"ghp_x\r\n"[..]).unwrap(), "ghp_x");
        assert_eq!(from_reader(&b"ghp_x"[..]).unwrap(), "ghp_x");
        assert_eq!(from_reader(&b"a\nb\n\n"[..]).unwrap(), "a\nb\n");
        assert!(from_reader(&b""[..]).is_err());
        assert!(from_reader(&b"\n"[..]).is_err());
    }
}
