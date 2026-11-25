//! What the processes of a run use: CPU, memory, disk. The daemon reads
//! every process of the run each `INTERVAL_SECS` and writes one `Sample`
//! per line to `<run id>.metrics` beside the run's log (`file_for`). When the
//! run ends, `Run.resources` holds the sums. No I/O here: `Tally` takes the
//! readings, so the arithmetic is tested without processes.
//!
//! CPU is counted from the sum, over the processes alive now, of each one's
//! own CPU time plus the CPU time of its children that it waited for
//! (`ri_child_user_time`). A process that ends and is waited for moves its
//! time to its parent, so the sum does not drop and a short process (300
//! `rustc` under `cargo`, each 0.5 s) is counted even when no sample saw it.
//! The sum drops only when a process ends and nobody of the run waits for
//! it; the growth after that still counts.
//!
//! Disk and memory have no such sum: macOS does not add a child's disk
//! bytes to its parent. A process that starts and ends between two samples
//! is missing from them (measured: 100 MB written by a 0.3 s process).
//!
//! ```text
//! sample at   t=2           t=4                 t=6
//! processes   cargo 0.1 s   cargo 0.1 s         cargo 0.1 + 3.9 waited
//!                           rustc 1.8 s         (rustc ended)
//! sum         0.1           1.9                 4.0
//! CPU         5%            90%                 105%
//! ```

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Seconds between two samples.
pub const INTERVAL_SECS: f64 = 2.0;
/// `get_run_metrics` returns at most this many samples by default.
pub const DEFAULT_MAX_POINTS: usize = 1000;
pub const MAX_POINTS: usize = 10_000;

/// The processes of a run at one moment.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Sample {
    /// Seconds since the run started.
    pub t: f64,
    /// CPU since the sample before, in percent of one core: 250 is two and a
    /// half cores busy.
    pub cpu: f64,
    /// Memory of all its processes, in bytes: the sum of what Activity
    /// Monitor shows as "Memory" (`phys_footprint`).
    pub mem: u64,
    /// Disk read and written since the sample before, in bytes per second.
    pub read: f64,
    pub write: f64,
    /// Processes alive.
    pub procs: u32,
}

/// The sums for a whole run.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Resources {
    /// CPU time of all its processes, user and system, in seconds.
    pub cpu_secs: f64,
    /// The highest `Sample.cpu`.
    pub peak_cpu: f64,
    /// The highest `Sample.mem`, in bytes.
    pub peak_mem: u64,
    pub read_bytes: u64,
    pub written_bytes: u64,
    /// The most processes alive at one sample.
    pub peak_procs: u32,
    /// How many samples there were; 0 for a run shorter than one interval.
    pub samples: u32,
}

/// One process at one moment, as the daemon reads it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Reading {
    pub pid: i32,
    /// When it started, in any clock that does not change while it lives:
    /// with `pid` it names the process, also when a pid is used again.
    pub started: u64,
    /// Its own CPU time and that of the children it waited for, in ns.
    pub cpu_ns: u64,
    pub mem: u64,
    /// Bytes read from and written to disk since it started.
    pub read: u64,
    pub written: u64,
}

/// Turns readings into samples and sums.
#[derive(Debug, Default)]
pub struct Tally {
    root: i32,
    last_t: f64,
    /// The CPU sum of the previous sample.
    last_cpu: u64,
    /// The newest reading of the first process: what `wait4` adds is after it.
    root_cpu: u64,
    disk: HashMap<(i32, u64), (u64, u64)>,
    cpu_ns: u64,
    sums: Resources,
}

impl Tally {
    /// `root` is the first process of the run.
    pub fn new(root: i32) -> Self {
        Self { root, ..Default::default() }
    }

    /// The sample at `t` seconds after the run started.
    pub fn add(&mut self, t: f64, readings: &[Reading]) -> Sample {
        let dt = (t - self.last_t).max(1e-3);
        let cpu: u64 = readings.iter().map(|r| r.cpu_ns).sum();
        let grew = cpu.saturating_sub(self.last_cpu);
        self.cpu_ns += grew;
        self.last_cpu = cpu;
        if let Some(root) = readings.iter().find(|r| r.pid == self.root) {
            self.root_cpu = root.cpu_ns;
        }

        let (mut read, mut written) = (0, 0);
        let mut disk = HashMap::with_capacity(readings.len());
        for r in readings {
            let (r0, w0) = self.disk.get(&(r.pid, r.started)).copied().unwrap_or((0, 0));
            read += r.read.saturating_sub(r0);
            written += r.written.saturating_sub(w0);
            disk.insert((r.pid, r.started), (r.read, r.written));
        }
        self.disk = disk;
        self.sums.read_bytes += read;
        self.sums.written_bytes += written;

        let sample = Sample {
            t: round(t, 1),
            cpu: round(grew as f64 / 1e9 / dt * 100.0, 1),
            mem: readings.iter().map(|r| r.mem).sum(),
            read: round(read as f64 / dt, 0),
            write: round(written as f64 / dt, 0),
            procs: readings.len() as u32,
        };
        self.last_t = t;
        self.sums.samples += 1;
        self.sums.peak_cpu = self.sums.peak_cpu.max(sample.cpu);
        self.sums.peak_mem = self.sums.peak_mem.max(sample.mem);
        self.sums.peak_procs = self.sums.peak_procs.max(sample.procs);
        sample
    }

    /// The sums. `root_total_ns`: the CPU time of the first process and its
    /// waited children when it ended (`wait4`); it adds what came after the
    /// last sample, or all of it for a run shorter than one interval.
    pub fn resources(&self, root_total_ns: Option<u64>) -> Resources {
        let tail = root_total_ns.map_or(0, |total| total.saturating_sub(self.root_cpu));
        Resources { cpu_secs: round((self.cpu_ns + tail) as f64 / 1e9, 2), ..self.sums }
    }
}

fn round(x: f64, digits: i32) -> f64 {
    let p = 10f64.powi(digits);
    (x * p).round() / p
}

/// The samples file of a run: `weekly.12.log` → `weekly.12.metrics`.
pub fn file_for(log: &Path) -> PathBuf {
    log.with_extension("metrics")
}

/// The samples in the lines of a samples file. A line that is not a sample
/// (the last one, while it is written) is left out.
pub fn parse(text: &str) -> Vec<Sample> {
    text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
}

/// At most `max` samples: each group of neighbours becomes one, with the
/// time of its last sample, the mean of the rates (CPU and disk: the area
/// under the line stays) and the highest memory and process count.
pub fn downsample(samples: &[Sample], max: usize) -> Vec<Sample> {
    let max = max.max(1);
    if samples.len() <= max {
        return samples.to_vec();
    }
    let size = samples.len().div_ceil(max);
    samples
        .chunks(size)
        .map(|group| {
            let n = group.len() as f64;
            let last = group[group.len() - 1];
            Sample {
                t: last.t,
                cpu: round(group.iter().map(|s| s.cpu).sum::<f64>() / n, 1),
                mem: group.iter().map(|s| s.mem).max().unwrap_or(0),
                read: round(group.iter().map(|s| s.read).sum::<f64>() / n, 0),
                write: round(group.iter().map(|s| s.write).sum::<f64>() / n, 0),
                procs: group.iter().map(|s| s.procs).max().unwrap_or(0),
            }
        })
        .collect()
}

/// `1.5 MB`, with 1 KB = 1024 bytes.
pub fn bytes(n: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = n as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 { format!("{n} B") } else { format!("{value:.1} {}", UNITS[unit]) }
}

/// One line for the run log.
pub fn describe(r: &Resources) -> String {
    format!(
        "CPU {:.1} s (peak {:.0}%), memory peak {}, disk read {}, written {}, peak {} processes",
        r.cpu_secs,
        r.peak_cpu,
        bytes(r.peak_mem),
        bytes(r.read_bytes),
        bytes(r.written_bytes),
        r.peak_procs
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reading(pid: i32, cpu_s: f64, mem: u64) -> Reading {
        Reading { pid, started: pid as u64, cpu_ns: (cpu_s * 1e9) as u64, mem, read: 0, written: 0 }
    }

    #[test]
    fn cpu_is_the_growth_of_the_sum_over_the_interval() {
        let mut t = Tally::new(1);
        let s = t.add(2.0, &[reading(1, 0.1, 100)]);
        assert_eq!((s.cpu, s.mem, s.procs), (5.0, 100, 1));
        // A child works 1.8 s of the next 2 s.
        let s = t.add(4.0, &[reading(1, 0.1, 100), reading(2, 1.8, 50)]);
        assert_eq!((s.cpu, s.mem, s.procs), (90.0, 150, 2));
    }

    #[test]
    fn a_child_that_ended_and_was_waited_for_is_counted_once() {
        let mut t = Tally::new(1);
        t.add(2.0, &[reading(1, 0.1, 0), reading(2, 1.8, 0)]);
        // The child ended at 3.9 s of CPU; its parent waited for it.
        let s = t.add(4.0, &[reading(1, 0.1 + 3.9, 0)]);
        assert_eq!(s.cpu, 105.0);
        assert_eq!(t.resources(None).cpu_secs, 4.0);
    }

    #[test]
    fn a_short_process_no_sample_saw_is_counted_through_its_parent() {
        let mut t = Tally::new(1);
        t.add(2.0, &[reading(1, 0.0, 0)]);
        // 10 compilers of 0.3 s each started and ended between two samples.
        let s = t.add(4.0, &[reading(1, 3.0, 0)]);
        assert_eq!(s.cpu, 150.0);
    }

    #[test]
    fn time_lost_with_a_process_nobody_waited_for_is_not_taken_back() {
        let mut t = Tally::new(1);
        t.add(2.0, &[reading(1, 1.0, 0), reading(2, 2.0, 0)]);
        // Process 2 ended and launchd waited for it: the sum drops.
        let s = t.add(4.0, &[reading(1, 1.0, 0)]);
        assert_eq!(s.cpu, 0.0);
        let s = t.add(6.0, &[reading(1, 2.0, 0)]);
        assert_eq!(s.cpu, 50.0);
        assert_eq!(t.resources(None).cpu_secs, 4.0);
    }

    #[test]
    fn wait4_adds_what_came_after_the_last_sample() {
        let mut t = Tally::new(1);
        t.add(2.0, &[reading(1, 1.5, 0)]);
        assert_eq!(t.resources(Some(2_500_000_000)).cpu_secs, 2.5);
        // A run shorter than one interval has only wait4.
        assert_eq!(Tally::new(1).resources(Some(700_000_000)).cpu_secs, 0.7);
    }

    #[test]
    fn disk_is_counted_per_process_and_a_new_pid_is_a_new_process() {
        let mut t = Tally::new(1);
        let r = |pid, started, read| Reading { pid, started, read, written: read / 2, ..Default::default() };
        let s = t.add(2.0, &[r(1, 1, 4000)]);
        assert_eq!((s.read, s.write), (2000.0, 1000.0));
        let s = t.add(4.0, &[r(1, 1, 6000), r(2, 2, 1000)]);
        assert_eq!((s.read, s.write), (1500.0, 750.0));
        // Pid 2 again, but another process: it started later.
        let s = t.add(6.0, &[r(1, 1, 6000), r(2, 9, 400)]);
        assert_eq!(s.read, 200.0);
        let sums = t.resources(None);
        assert_eq!((sums.read_bytes, sums.written_bytes), (7400, 3700));
    }

    #[test]
    fn peaks_and_sample_count() {
        let mut t = Tally::new(1);
        t.add(2.0, &[reading(1, 1.0, 300), reading(2, 1.0, 200)]);
        t.add(4.0, &[reading(1, 1.5, 100)]);
        let r = t.resources(None);
        assert_eq!((r.peak_cpu, r.peak_mem, r.peak_procs, r.samples), (100.0, 500, 2, 2));
    }

    #[test]
    fn samples_file_sits_beside_the_log() {
        assert_eq!(file_for(Path::new("/l/runs/a/a.12.log")), PathBuf::from("/l/runs/a/a.12.metrics"));
    }

    #[test]
    fn a_half_written_line_is_left_out() {
        let text = "{\"t\":2.0,\"cpu\":5.0,\"mem\":1,\"read\":0.0,\"write\":0.0,\"procs\":1}\n{\"t\":4.0,\"cp";
        assert_eq!(parse(text).len(), 1);
    }

    #[test]
    fn downsampling_keeps_the_area_and_the_peaks() {
        let s = |t: f64, cpu: f64, mem: u64| Sample { t, cpu, mem, read: cpu, write: 0.0, procs: mem as u32 };
        let samples = [s(2.0, 100.0, 1), s(4.0, 0.0, 5), s(6.0, 50.0, 2), s(8.0, 50.0, 2), s(10.0, 10.0, 3)];
        let out = downsample(&samples, 3);
        assert_eq!(out.len(), 3);
        assert_eq!(out[0], s(4.0, 50.0, 5));
        assert_eq!(out[1], s(8.0, 50.0, 2));
        assert_eq!(out[2], s(10.0, 10.0, 3));
        assert_eq!(downsample(&samples, 10).len(), 5);
    }

    #[test]
    fn sizes_and_the_log_line() {
        assert_eq!(bytes(512), "512 B");
        assert_eq!(bytes(1536), "1.5 KB");
        assert_eq!(bytes(412 * 1024 * 1024), "412.0 MB");
        let r = Resources { cpu_secs: 12.34, peak_cpu: 183.4, peak_mem: 2048, read_bytes: 0, written_bytes: 1024, peak_procs: 7, samples: 3 };
        assert_eq!(describe(&r), "CPU 12.3 s (peak 183%), memory peak 2.0 KB, disk read 0 B, written 1.0 KB, peak 7 processes");
    }
}
