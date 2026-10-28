//! Test helpers: a real daemon in a temporary folder.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Once;
use std::time::{Duration, Instant};

pub fn bin(name: &str) -> PathBuf {
    Path::new(env!("CARGO_BIN_EXE_localcron")).with_file_name(name)
}

/// The CLI crate does not depend on the daemon crate, so build it once here.
pub fn build_daemon() -> PathBuf {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
        let status = Command::new(cargo)
            .args(["build", "--quiet", "-p", "localcrond"])
            .current_dir(env!("CARGO_MANIFEST_DIR"))
            .status()
            .expect("cargo build");
        assert!(status.success(), "building localcrond failed");
    });
    bin("localcrond")
}

pub struct Daemon {
    pub child: Child,
    pub dir: tempfile::TempDir,
}

impl Daemon {
    pub fn start() -> Self {
        // Short: the socket path must stay under 104 bytes.
        let dir = tempfile::Builder::new().prefix("lc").tempdir_in("/tmp").unwrap();
        let child = Command::new(build_daemon())
            .env("LOCALCRON_HOME", dir.path())
            .env("LOCALCRON_PATH", "/usr/bin:/bin")
            .env("HOME", dir.path())
            .env("SHELL", "/bin/sh")
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let d = Self { child, dir };
        let deadline = Instant::now() + Duration::from_secs(10);
        while std::os::unix::net::UnixStream::connect(d.home().join("daemon.sock")).is_err() {
            assert!(Instant::now() < deadline, "daemon did not start");
            std::thread::sleep(Duration::from_millis(20));
        }
        d
    }

    pub fn home(&self) -> &Path {
        self.dir.path()
    }

    /// Run the CLI against this daemon.
    pub fn cli(&self, args: &[&str]) -> (bool, String, String, Option<i32>) {
        let out = Command::new(env!("CARGO_BIN_EXE_localcron"))
            .args(args)
            .env("LOCALCRON_HOME", self.home())
            .current_dir(self.home())
            .output()
            .unwrap();
        (
            out.status.success(),
            String::from_utf8_lossy(&out.stdout).into_owned(),
            String::from_utf8_lossy(&out.stderr).into_owned(),
            out.status.code(),
        )
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
