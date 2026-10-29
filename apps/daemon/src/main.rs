//! `localcrond`: the LocalCron daemon. One per user, started by launchd.
//!
//! Threads: the scheduler, the socket's accept loop, one per client
//! connection, one per running job, and this one, which waits for SIGTERM.

mod engine;
mod lock;
mod secrets;
mod shellenv;
mod socket;
mod store;

use std::os::fd::AsRawFd;
use std::process::ExitCode;
use std::sync::Arc;

use localcron_core::instance::Instance;
use localcron_core::paths::Paths;

use crate::engine::{DAEMON_VERSION, Engine};

/// A line in the daemon log: `2026-10-28T09:00:00+00:00 run a.1: queued`.
#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => {
        eprintln!("{} {}", chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%:z"), format_args!($($arg)*))
    };
}

/// The daemon log is cut in two at this size when the daemon starts.
const MAX_LOG: u64 = 5 * 1024 * 1024;

fn main() -> ExitCode {
    let instance = match Instance::of_this_program() {
        Ok(instance) => instance,
        Err(e) => {
            eprintln!("localcrond: {e}");
            return ExitCode::from(2);
        }
    };
    let name = instance.daemon_program();
    if std::env::args().any(|a| a == "--version" || a == "-V") {
        println!("{name} {DAEMON_VERSION}");
        return ExitCode::SUCCESS;
    }
    let paths = Paths::from_env(&instance);
    if let Some(problem) = paths.socket_path_problem() {
        eprintln!("{name}: {problem}");
        return ExitCode::from(2);
    }
    for dir in [&paths.data, &paths.logs] {
        if let Err(e) = std::fs::create_dir_all(dir) {
            eprintln!("{name}: cannot create {}: {e}", dir.display());
            return ExitCode::from(2);
        }
    }
    let _lock = match lock::acquire(&paths.lock()) {
        Ok(lock) => lock,
        Err(lock::LockError::AlreadyRunning) => {
            eprintln!("{name}: already running for {}", paths.data.display());
            return ExitCode::from(3);
        }
        Err(lock::LockError::Io(e)) => {
            eprintln!("{name}: cannot lock {}: {e}", paths.lock().display());
            return ExitCode::from(2);
        }
    };
    log_to_file(&paths);
    // Before any thread starts, so every thread has them blocked and only
    // `sigwait` below receives them. Child processes start with an empty mask.
    let signals = block_stop_signals();

    log!("{name} {DAEMON_VERSION} starting, data in {}", paths.data.display());
    let engine = Engine::load(paths, instance);
    let listener = match socket::bind(&engine) {
        Ok(l) => l,
        Err(e) => {
            log!("cannot bind {}: {e}", engine.paths.socket().display());
            return ExitCode::FAILURE;
        }
    };
    let e = Arc::clone(&engine);
    std::thread::Builder::new().name("socket".into()).spawn(move || socket::serve(e, listener)).expect("socket thread");
    let e = Arc::clone(&engine);
    let scheduler = std::thread::Builder::new().name("scheduler".into()).spawn(move || e.run_scheduler()).expect("scheduler thread");

    let mut received = 0;
    // SAFETY: `signals` is an initialized set; `received` is a valid out pointer.
    unsafe { libc::sigwait(&signals, &mut received) };
    log!("stopping (signal {received})");
    engine.shutdown();
    let _ = scheduler.join();
    let _ = std::fs::remove_file(engine.paths.socket());
    ExitCode::SUCCESS
}

fn block_stop_signals() -> libc::sigset_t {
    // SAFETY: plain libc calls on a local set.
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGTERM);
        libc::sigaddset(&mut set, libc::SIGINT);
        libc::sigaddset(&mut set, libc::SIGHUP);
        libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
        set
    }
}

/// A child inherits the blocked signals of the thread that starts it, and
/// a program with SIGTERM blocked cannot be stopped. Clear the mask between
/// fork and exec.
pub fn unblock_signals_in_child(command: &mut std::process::Command) {
    use std::os::unix::process::CommandExt;
    // SAFETY: sigemptyset and sigprocmask are async-signal-safe.
    unsafe {
        command.pre_exec(|| {
            let mut set: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut set);
            libc::sigprocmask(libc::SIG_SETMASK, &set, std::ptr::null_mut());
            Ok(())
        });
    }
}

/// launchd gives the daemon no terminal: send stderr to `daemon.log`. From a
/// terminal (`cargo run`) the messages stay on the screen.
fn log_to_file(paths: &Paths) {
    // SAFETY: isatty only reads the descriptor.
    if unsafe { libc::isatty(2) } == 1 {
        return;
    }
    let path = paths.daemon_log();
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > MAX_LOG) {
        let _ = std::fs::rename(&path, path.with_extension("log.1"));
    }
    if let Ok(file) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        // SAFETY: both descriptors are valid; dup2 replaces fd 2.
        unsafe { libc::dup2(file.as_raw_fd(), 2) };
    }
}
