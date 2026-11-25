//! The sampler of a run: a thread that reads the run's processes every
//! `INTERVAL_SECS` and appends one sample per line to its `.metrics` file.
//!
//! ```text
//! run thread ─ spawn ─► process group ◄── every 2 s ── sampler thread ─► <run id>.metrics
//!     │ wait4 (CPU of the run)                              │
//!     └── stop ─────────────────────────────────────────────┘ last sample, sums ─► Run.resources
//! ```
//!
//! One look costs about 15 µs for 10 processes, plus `proc_pidinfo` for the
//! processes that are new since the last look (see procs.rs).

use std::fs::File;
use std::io::Write;
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use localcron_core::metrics::{INTERVAL_SECS, Resources, Tally};

use crate::log;
use crate::procs::{self, Family};

struct Stop {
    done: Mutex<bool>,
    wake: Condvar,
}

pub struct Sampler {
    stop: Arc<Stop>,
    thread: Option<JoinHandle<Tally>>,
}

impl Sampler {
    /// Start sampling the run's family; `started` is when the run started.
    /// None when the file or the thread cannot be made: the run goes on
    /// without samples.
    pub fn start(run_id: &str, family: &Arc<Mutex<Family>>, path: &Path, started: Instant) -> Option<Self> {
        let mut file = match File::create(path) {
            Ok(f) => f,
            Err(e) => {
                log!("run {run_id}: cannot write its samples to {}: {e}", path.display());
                return None;
            }
        };
        let stop = Arc::new(Stop { done: Mutex::new(false), wake: Condvar::new() });
        let family = Arc::clone(family);
        let root = family.lock().unwrap_or_else(|e| e.into_inner()).root();
        let shared = Arc::clone(&stop);
        let thread = std::thread::Builder::new()
            .name(format!("meter-{run_id}"))
            .spawn(move || {
                let mut tally = Tally::new(root);
                let interval = Duration::from_secs_f64(INTERVAL_SECS);
                let mut next = started + interval;
                loop {
                    let done = {
                        let mut done = shared.done.lock().unwrap_or_else(|e| e.into_inner());
                        while !*done {
                            let left = next.saturating_duration_since(Instant::now());
                            if left.is_zero() {
                                break;
                            }
                            done = shared.wake.wait_timeout(done, left).unwrap_or_else(|e| e.into_inner()).0;
                        }
                        *done
                    };
                    // The last look, when stopped, sees what is left.
                    let pids = family.lock().unwrap_or_else(|e| e.into_inner()).look();
                    let readings: Vec<_> = pids.into_iter().filter_map(procs::read).collect();
                    let t = started.elapsed().as_secs_f64();
                    if !readings.is_empty() || !done {
                        let sample = tally.add(t, &readings);
                        if let Ok(line) = serde_json::to_string(&sample) {
                            let _ = writeln!(file, "{line}");
                        }
                    }
                    if done {
                        return tally;
                    }
                    next += interval;
                    // After a sleep of the Mac: no burst of missed looks.
                    if next < Instant::now() {
                        next = Instant::now() + interval;
                    }
                }
            });
        match thread {
            Ok(thread) => Some(Self { stop, thread: Some(thread) }),
            Err(e) => {
                log!("run {run_id}: cannot start its sampler: {e}");
                None
            }
        }
    }

    /// Take a last look and give the sums. `root_total_ns`: the CPU time
    /// `wait4` gave for the first process, when the daemon waited for it.
    pub fn finish(mut self, root_total_ns: Option<u64>) -> Option<Resources> {
        *self.stop.done.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.stop.wake.notify_all();
        let tally = self.thread.take()?.join().ok()?;
        Some(tally.resources(root_total_ns))
    }
}

impl Drop for Sampler {
    fn drop(&mut self) {
        *self.stop.done.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.stop.wake.notify_all();
    }
}
