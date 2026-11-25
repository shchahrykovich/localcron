//! The processes of a run: find them, stop them, read what they use.
//!
//! A process belongs to a run when it is in the run's process group, or
//! when its parent belongs to the run. `Family` looks at the processes that
//! are new since its last look and keeps each member by pid and start time:
//!
//! ```text
//! look 1   sh (group) ─► node (group) ─► server (setsid: own group, parent node ✓)
//! look 2   node ended; server's parent is launchd (1), but it is known ✓
//! ```
//!
//! So a process that leaves the group (`setsid()`, Node's `spawn({detached:
//! true})`, a tmux server) is still found when its parent was alive at a
//! look. Missed: a daemon that forks twice and whose middle process ends
//! between two looks, so no look saw its parent. macOS gives no way to
//! read another process's environment any more (`KERN_PROCARGS2` returns
//! only the arguments on macOS 27), so a variable cannot mark the run.
//!
//! One look: `proc_listallpids`, then `proc_pidinfo` for each new pid; the
//! first look reads every process (about 1000), the others only new ones.

use std::collections::{HashMap, HashSet};
use std::os::unix::process::ExitStatusExt;
use std::process::ExitStatus;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use localcron_core::metrics::Reading;

/// Every pid on the Mac.
pub fn all() -> Vec<i32> {
    list(|buf, size| unsafe { libc::proc_listallpids(buf, size) })
}

/// The processes of the group, zombies too.
pub fn group(pgid: i32) -> Vec<i32> {
    list(|buf, size| unsafe { libc::proc_listpgrppids(pgid, buf, size) })
}

/// `call` fills the buffer and returns the number of pids, or how many
/// there are with a null buffer.
fn list(call: impl Fn(*mut libc::c_void, libc::c_int) -> libc::c_int) -> Vec<i32> {
    let mut want = call(std::ptr::null_mut(), 0).max(0) as usize + 64;
    for _ in 0..4 {
        let mut pids = vec![0i32; want];
        let n = call(pids.as_mut_ptr().cast(), (pids.len() * size_of::<i32>()) as libc::c_int);
        if n < 0 {
            return Vec::new();
        }
        let n = n as usize;
        if n < pids.len() {
            pids.truncate(n);
            pids.retain(|p| *p > 0);
            return pids;
        }
        // Full: more processes started since the count.
        want = n * 2;
    }
    Vec::new()
}

/// What a family needs to know of a process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Info {
    pub ppid: i32,
    pub pgid: i32,
    /// When it started, in µs since 1970: with the pid it names the process.
    pub started: u64,
    pub zombie: bool,
}

pub fn info(pid: i32) -> Option<Info> {
    let mut i: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: the buffer is a proc_bsdinfo of the size given.
    let n = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut i).cast(), size) };
    (n == size).then(|| Info {
        ppid: i.pbi_ppid as i32,
        pgid: i.pbi_pgid as i32,
        started: i.pbi_start_tvsec * 1_000_000 + i.pbi_start_tvusec,
        zombie: i.pbi_status == libc::SZOMB,
    })
}

/// The process's name, as `ps -c` shows it.
pub fn name(pid: i32) -> String {
    let mut buf = [0u8; 256];
    // SAFETY: proc_name writes at most the size given.
    let n = unsafe { libc::proc_name(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
    if n <= 0 { "?".into() } else { String::from_utf8_lossy(&buf[..n as usize]).into_owned() }
}

pub fn signal(pid: i32, signal: i32) {
    // SAFETY: kill has no memory effects.
    unsafe {
        libc::kill(pid, signal);
    }
}

/// The processes of one run, kept from one look to the next.
#[derive(Debug)]
pub struct Family {
    /// The first process; the run's process group has its pid.
    root: i32,
    /// Members by pid, with their start time.
    members: HashMap<i32, u64>,
    /// Every pid of the last look, so only new ones are read.
    seen: HashSet<i32>,
}

impl Family {
    pub fn new(root: i32) -> Self {
        Self { root, members: HashMap::new(), seen: HashSet::new() }
    }

    pub fn root(&self) -> i32 {
        self.root
    }

    /// Look at the processes now, and give the members alive, zombies too.
    pub fn look(&mut self) -> Vec<i32> {
        let me = std::process::id() as i32;
        let all: HashSet<i32> = all().into_iter().collect();
        // Parents before children: a child of a new process is new too.
        let mut new: Vec<(i32, Info)> =
            all.iter().filter(|p| !self.seen.contains(p) && **p != me).filter_map(|p| info(*p).map(|i| (*p, i))).collect();
        new.sort_by_key(|(_, i)| i.started);
        // A known pid that is now another process is not a member any more.
        self.members.retain(|pid, started| all.contains(pid) && info(*pid).is_some_and(|i| i.started == *started));
        for (pid, i) in new {
            if pid == self.root || i.pgid == self.root || self.members.contains_key(&i.ppid) {
                self.members.insert(pid, i.started);
            }
        }
        // A process that joined the group after it was first seen.
        for pid in group(self.root) {
            if let std::collections::hash_map::Entry::Vacant(e) = self.members.entry(pid)
                && let Some(i) = info(pid)
            {
                e.insert(i.started);
            }
        }
        self.seen = all;
        let mut pids: Vec<i32> = self.members.keys().copied().collect();
        pids.sort_unstable();
        pids
    }

    /// The members alive now, without zombies.
    pub fn alive(&mut self) -> Vec<i32> {
        self.look().into_iter().filter(|p| info(*p).is_some_and(|i| !i.zombie)).collect()
    }

    /// Send `sig` to the run's group and to every member.
    pub fn signal(&mut self, sig: i32) {
        let pids = self.look();
        signal(-self.root, sig);
        for pid in pids {
            signal(pid, sig);
        }
    }
}

/// Stop what is left of a run after its first process ended: SIGTERM, then
/// SIGKILL after `grace`. Returns `name (pid)` of each process that was
/// still running; empty when nothing was. The lock is taken only for each
/// look, so a stop from the scheduler never waits for the grace time.
pub fn sweep(family: &Mutex<Family>, grace: Duration) -> Vec<String> {
    let lock = || family.lock().unwrap_or_else(|e| e.into_inner());
    let left = lock().alive();
    if left.is_empty() {
        return Vec::new();
    }
    let names = left.iter().map(|p| format!("{} ({p})", name(*p))).collect();
    lock().signal(libc::SIGTERM);
    let start = Instant::now();
    while start.elapsed() < grace {
        std::thread::sleep(Duration::from_millis(100));
        if lock().alive().is_empty() {
            return names;
        }
    }
    lock().signal(libc::SIGKILL);
    names
}

/// Wait for a child like `Child::wait`, and give its CPU time and that of
/// its waited children, in ns (`wait4`).
pub fn wait(pid: i32) -> std::io::Result<(ExitStatus, u64)> {
    loop {
        let mut status = 0;
        let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
        // SAFETY: both out pointers are valid.
        let r = unsafe { libc::wait4(pid, &mut status, 0, &mut usage) };
        if r == pid {
            let ns = |t: libc::timeval| t.tv_sec as u64 * 1_000_000_000 + t.tv_usec as u64 * 1000;
            return Ok((ExitStatus::from_raw(status), ns(usage.ru_utime) + ns(usage.ru_stime)));
        }
        let e = std::io::Error::last_os_error();
        if e.kind() != std::io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
}

/// `mach_absolute_time` ticks in ns: on Apple silicon a tick is 125/3 ns,
/// and `proc_pid_rusage` gives its times in ticks.
fn ticks_to_ns(ticks: u64) -> u64 {
    static BASE: OnceLock<(u64, u64)> = OnceLock::new();
    // libc's binding is deprecated in favor of the mach2 crate; one call
    // does not need a crate.
    #[repr(C)]
    struct Timebase {
        numer: u32,
        denom: u32,
    }
    unsafe extern "C" {
        fn mach_timebase_info(info: *mut Timebase) -> libc::c_int;
    }
    let (numer, denom) = *BASE.get_or_init(|| {
        let mut info = Timebase { numer: 0, denom: 0 };
        // SAFETY: fills the struct.
        unsafe { mach_timebase_info(&mut info) };
        if info.denom == 0 { (1, 1) } else { (u64::from(info.numer), u64::from(info.denom)) }
    });
    (u128::from(ticks) * u128::from(numer) / u128::from(denom)) as u64
}

/// What the process has used so far; None when it is gone.
pub fn read(pid: i32) -> Option<Reading> {
    let mut ri: libc::rusage_info_v4 = unsafe { std::mem::zeroed() };
    // SAFETY: the buffer is a rusage_info_v4, the flavor asked for.
    let r = unsafe { libc::proc_pid_rusage(pid, libc::RUSAGE_INFO_V4, (&raw mut ri).cast()) };
    (r == 0).then(|| Reading {
        pid,
        started: ri.ri_proc_start_abstime,
        cpu_ns: ticks_to_ns(ri.ri_user_time + ri.ri_system_time + ri.ri_child_user_time + ri.ri_child_system_time),
        mem: ri.ri_phys_footprint,
        read: ri.ri_diskio_bytesread,
        written: ri.ri_diskio_byteswritten,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    fn wait_until(mut done: impl FnMut() -> bool) {
        let start = Instant::now();
        while !done() {
            assert!(start.elapsed() < Duration::from_secs(5), "timed out");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn a_child_that_left_the_group_stays_in_the_family_after_its_parent_ended() {
        let dir = tempfile::tempdir().unwrap();
        let pidfile = dir.path().join("pid");
        // sh starts perl, which leaves the group as a daemon would; sh ends later.
        let script = format!("/usr/bin/perl -e 'setpgrp(0, 0); sleep 30' & echo $! > {}; sleep 1", pidfile.display());
        let mut root = Command::new("/bin/sh").args(["-c", &script]).process_group(0).spawn().unwrap();
        let mut family = Family::new(root.id() as i32);
        family.look();
        wait_until(|| std::fs::read_to_string(&pidfile).is_ok_and(|t| t.ends_with('\n')));
        let child: i32 = std::fs::read_to_string(&pidfile).unwrap().trim().parse().unwrap();
        wait_until(|| info(child).is_some_and(|i| i.pgid == child));
        assert!(family.look().contains(&child), "a child of the root is a member");
        assert!(root.wait().unwrap().success());
        // Its parent is gone and it is in no group of the run.
        assert!(family.alive().contains(&child));

        let left = sweep(&Mutex::new(family), Duration::from_secs(5));
        assert_eq!(left.len(), 1, "{left:?}");
        assert!(left[0].starts_with("perl") && left[0].ends_with(&format!("({child})")), "{left:?}");
        wait_until(|| info(child).is_none());
    }

    #[test]
    fn processes_of_others_are_not_in_the_family() {
        let mut other = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let mut root = Command::new("/bin/sleep").arg("30").process_group(0).spawn().unwrap();
        let mut family = Family::new(root.id() as i32);
        assert_eq!(family.alive(), vec![root.id() as i32]);
        family.signal(libc::SIGKILL);
        assert_eq!(root.wait().unwrap().signal(), Some(libc::SIGKILL));
        assert!(info(other.id() as i32).is_some(), "a stranger was stopped");
        other.kill().unwrap();
        let _ = other.wait();
    }

    #[test]
    fn readings_are_in_ns_and_bytes() {
        // Busy for a moment, so the CPU time is clearly above zero.
        let start = Instant::now();
        let mut x = 0u64;
        while start.elapsed() < Duration::from_millis(200) {
            x = std::hint::black_box(x.wrapping_add(1));
        }
        let r = read(std::process::id() as i32).unwrap();
        // At least 0.15 s of CPU, and not 41 times too little (ticks).
        assert!(r.cpu_ns > 150_000_000, "{r:?}");
        assert!(r.mem > 0);
        assert!(read(-5).is_none());
    }

    #[test]
    // procs::wait (wait4) waits for it; clippy only knows Child::wait.
    #[allow(clippy::zombie_processes)]
    fn wait_gives_the_status_and_the_cpu_of_waited_children() {
        let child = Command::new("/bin/sh").args(["-c", "i=0; while [ $i -lt 20000 ]; do i=$((i+1)); done; exit 4"]).spawn().unwrap();
        let (status, ns) = wait(child.id() as i32).unwrap();
        assert_eq!(status.code(), Some(4));
        assert!(ns > 0);
    }
}
