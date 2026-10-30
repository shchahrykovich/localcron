//! The scheduler and the runner. One lock holds all state; the scheduler
//! thread sleeps until the next due time, a deadline, or a change, so an idle
//! daemon uses no CPU. Each run has one thread that waits for its process.
//!
//! ```text
//! scheduler thread ─ due job ─► queue ─ free slot ─► run thread ─ spawn ─► process group
//!        ▲                                                │ wait
//!        └──────────── notify (job saved, run finished) ◄─┘
//! ```

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use chrono::{DateTime, FixedOffset, Local, Timelike};
use localcron_core::api::{
    self, AllowJobSecretsParams, ApiError, CancelRunResult, Config, ErrorCode, GetRunLogParams, GetRunLogResult, JobView, ListJobsResult, ListRunsParams,
    ListRunsResult, ListSecretsResult, MissingSecret, NextRun, PreviewScheduleParams, PreviewScheduleResult, RemoveJobResult,
    RemoveSecretResult, RunJobParams, SecretInfo, SecretState, SetConfigParams, SetJobParams, SetJobResult, SetSecretParams, SetSecretResult,
    StatusResult,
};
use localcron_core::instance::Instance;
use localcron_core::job::{Job, JobKind};
use localcron_core::paths::Paths;
use localcron_core::run::{Run, RunStatus, Trigger};
use localcron_core::schedule::{self, Schedule};
use localcron_core::secret;

use crate::console::{self, Console, Pane};
use crate::log;
use crate::peer::{AppCheck, Trust};
use crate::secrets::{Keychain, ReadError};
use crate::shellenv::ShellEnvCache;
use crate::store::{self, Grant, JobsFile, RunsFile, SecretEntry, SecretsFile};

pub const DAEMON_VERSION: &str = env!("CARGO_PKG_VERSION");

/// The scheduler looks at the clock at least this often, so a Mac that wakes
/// from sleep or a changed clock is noticed within a minute.
const MAX_SLEEP: Duration = Duration::from_secs(60);
/// A due time older than this when the scheduler sees it is a catch-up run.
const LATE: chrono::Duration = chrono::Duration::seconds(90);
/// After SIGTERM, a run has this long to stop before SIGKILL.
const KILL_GRACE: Duration = Duration::from_secs(10);
const DEFAULT_LOG_BYTES: u64 = 64 * 1024;
const MAX_LOG_BYTES: u64 = 1024 * 1024;

type ApiResult<T> = Result<T, ApiError>;

/// Whole seconds: easier to read, and every client parses them.
fn now() -> DateTime<FixedOffset> {
    let t = Local::now().fixed_offset();
    t.with_nanosecond(0).unwrap_or(t)
}

fn invalid(message: impl Into<String>) -> ApiError {
    ApiError::new(ErrorCode::Invalid, message)
}

fn internal(message: impl Into<String>) -> ApiError {
    ApiError::new(ErrorCode::Internal, message)
}

fn not_found_job(id: &str) -> ApiError {
    ApiError::new(ErrorCode::NotFound, format!("no job {id:?}"))
}

struct Slot {
    job: Job,
    schedule: Schedule,
    next_due: Option<DateTime<Local>>,
}

struct Active {
    pid: Option<u32>,
    deadline: Instant,
    /// Set when the run is being stopped: why, and when SIGTERM was sent.
    stop: Option<(RunStatus, Option<Instant>)>,
    killed: bool,
}

struct State {
    jobs: BTreeMap<String, Slot>,
    /// Oldest first.
    runs: Vec<Run>,
    next_seq: u64,
    queue: VecDeque<String>,
    running: HashMap<String, Active>,
    config: Config,
    /// Names and descriptions; the values are in the Keychain.
    secrets: BTreeMap<String, SecretEntry>,
    /// By job id.
    grants: BTreeMap<String, Grant>,
    stopping: bool,
}

pub struct Engine {
    pub paths: Paths,
    pub instance: Instance,
    started_at: DateTime<FixedOffset>,
    state: Mutex<State>,
    wake: Condvar,
    shell_env: ShellEnvCache,
    keychain: Keychain,
    pub app_check: AppCheck,
}

impl Engine {
    /// Reads the files. Runs that were queued or running when the daemon
    /// stopped are marked as failed: their processes are not ours any more.
    pub fn load(paths: Paths, instance: Instance) -> Arc<Self> {
        let (jobs_file, problem): (JobsFile, _) = store::load(&paths.jobs());
        problem.into_iter().for_each(|p| log!("{p}"));
        let (mut runs_file, problem): (RunsFile, _) = store::load(&paths.runs());
        problem.into_iter().for_each(|p| log!("{p}"));
        let (config, problem) = store::load_config(&paths.config());
        problem.into_iter().for_each(|p| log!("{p}"));
        let (secrets_file, problem): (SecretsFile, _) = store::load(&paths.secrets());
        problem.into_iter().for_each(|p| log!("{p}"));
        let keychain = Keychain::for_instance(&instance);
        let app_check = AppCheck::for_this_daemon(&instance);

        let started = now();
        let mut lost = 0;
        for run in runs_file.runs.iter_mut().filter(|r| !r.status.is_finished()) {
            run.status = RunStatus::Failed;
            run.ended_at.get_or_insert(started);
            run.message = "LocalCron stopped during this run".into();
            lost += 1;
        }
        if lost > 0 {
            log!("{lost} runs were unfinished when the daemon stopped");
        }

        let local_now = Local::now();
        let mut jobs = BTreeMap::new();
        for job in jobs_file.jobs {
            let schedule = match job.validate() {
                Ok(s) => s,
                Err(e) => {
                    log!("job {:?} is kept but never runs: {e}", job.id);
                    match Schedule::parse("0 0 31 2 *") {
                        Ok(never) => never,
                        Err(_) => continue,
                    }
                }
            };
            let last_due = runs_file.runs.iter().filter(|r| r.job_id == job.id).filter_map(|r| r.due_at).max();
            let next_due = first_due(&job, &schedule, last_due.max(config.resumed_at), local_now);
            jobs.insert(job.id.clone(), Slot { job, schedule, next_due });
        }
        let next_seq = runs_file.next_seq.max(1);
        let engine = Arc::new(Engine {
            paths,
            instance,
            started_at: started,
            state: Mutex::new(State {
                jobs,
                runs: runs_file.runs,
                next_seq,
                queue: VecDeque::new(),
                running: HashMap::new(),
                config,
                secrets: secrets_file.secrets.into_iter().map(|s| (s.name.clone(), s)).collect(),
                grants: secrets_file.grants.into_iter().map(|g| (g.job_id.clone(), g)).collect(),
                stopping: false,
            }),
            wake: Condvar::new(),
            shell_env: ShellEnvCache::default(),
            keychain,
            app_check,
        });
        if lost > 0 {
            let st = engine.lock();
            engine.save_runs(&st);
        }
        engine
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    // MARK: Scheduler

    /// The scheduler thread's body. Returns when `shutdown` is called.
    pub fn run_scheduler(self: &Arc<Self>) {
        let mut st = self.lock();
        loop {
            if st.stopping {
                return;
            }
            let wait = self.tick(&mut st);
            st = self.wake.wait_timeout(st, wait).unwrap_or_else(|e| e.into_inner()).0;
        }
    }

    /// Wake the scheduler now: a job or the config changed, a run ended.
    fn notify(&self) {
        self.wake.notify_all();
    }

    /// Queue due jobs, start queued runs, stop late ones. Returns how long
    /// the scheduler may sleep.
    fn tick(self: &Arc<Self>, st: &mut State) -> Duration {
        let local_now = Local::now();
        let mut jobs_changed = false;
        let paused = st.config.paused;
        let due: Vec<(String, DateTime<Local>)> = st
            .jobs
            .values()
            .filter(|s| s.job.enabled)
            .filter_map(|s| s.next_due.filter(|d| *d <= local_now).map(|d| (s.job.id.clone(), d)))
            .collect();
        for (id, due_at) in due {
            let Some(slot) = st.jobs.get_mut(&id) else { continue };
            let late = local_now - due_at > LATE;
            slot.next_due = slot.schedule.next_after(&local_now);
            if slot.schedule.is_once() {
                slot.job.enabled = false;
                jobs_changed = true;
            }
            if paused {
                if slot.schedule.is_once() {
                    log!("job {id}: missed {due_at}, LocalCron is paused");
                }
                continue;
            }
            if late && !slot.job.catch_up {
                log!("job {id}: missed {due_at}, catch_up is off");
                continue;
            }
            let trigger = if late { Trigger::CatchUp } else { Trigger::Schedule };
            self.enqueue(st, &id, trigger, Some(due_at.fixed_offset()));
        }
        if jobs_changed {
            let _ = self.save_jobs(st);
        }

        while st.running.len() < st.config.max_concurrent as usize {
            let Some(run_id) = st.queue.pop_front() else { break };
            self.start(st, &run_id);
        }

        let mut wait = MAX_SLEEP;
        let now_i = Instant::now();
        for (run_id, active) in st.running.iter_mut() {
            match active.stop {
                None if now_i >= active.deadline => {
                    log!("run {run_id}: timed out");
                    active.stop = Some((RunStatus::TimedOut, None));
                }
                _ => {}
            }
            if let Some((_, sent)) = active.stop {
                match (sent, active.pid) {
                    (None, Some(pid)) => {
                        signal_group(pid, libc::SIGTERM);
                        active.stop = active.stop.map(|(s, _)| (s, Some(now_i)));
                        wait = wait.min(KILL_GRACE);
                    }
                    (Some(at), Some(pid)) if !active.killed => {
                        let left = (at + KILL_GRACE).saturating_duration_since(now_i);
                        if left.is_zero() {
                            signal_group(pid, libc::SIGKILL);
                            active.killed = true;
                        } else {
                            wait = wait.min(left);
                        }
                    }
                    _ => {}
                }
            } else {
                wait = wait.min(active.deadline.saturating_duration_since(now_i));
            }
        }
        if let Some(next) = st.jobs.values().filter(|s| s.job.enabled).filter_map(|s| s.next_due).min() {
            let until = (next - Local::now()).to_std().unwrap_or(Duration::ZERO);
            wait = wait.min(until);
        }
        wait.max(Duration::from_millis(5))
    }

    /// A new run for the job: queued, or skipped when the job already has one
    /// queued or running.
    fn enqueue(&self, st: &mut State, job_id: &str, trigger: Trigger, due_at: Option<DateTime<FixedOffset>>) -> Run {
        let id = format!("{job_id}.{}", st.next_seq);
        st.next_seq += 1;
        let mut run = Run {
            id,
            job_id: job_id.to_string(),
            trigger,
            status: RunStatus::Queued,
            due_at,
            queued_at: now(),
            started_at: None,
            ended_at: None,
            exit_code: None,
            pid: None,
            log: None,
            message: String::new(),
            console: None,
        };
        if let Some(busy) = st.runs.iter().find(|r| r.job_id == job_id && !r.status.is_finished()) {
            run.status = RunStatus::Skipped;
            run.ended_at = Some(run.queued_at);
            run.message = format!("run {} was still {}", busy.id, if busy.status == RunStatus::Queued { "queued" } else { "running" });
            // An early run that does not start takes no time from the schedule.
            if trigger == Trigger::Early {
                run.due_at = None;
            }
            log!("run {}: skipped, {}", run.id, run.message);
        } else {
            st.queue.push_back(run.id.clone());
            log!("run {}: queued ({trigger:?})", run.id);
        }
        st.runs.push(run.clone());
        self.prune(st, job_id);
        self.save_runs(st);
        run
    }

    /// Mark the run as running and give it a thread.
    fn start(self: &Arc<Self>, st: &mut State, run_id: &str) {
        let Some(job) = st.runs.iter().find(|r| r.id == run_id).and_then(|r| st.jobs.get(&r.job_id)).map(|s| s.job.clone())
        else {
            return;
        };
        let log_path = self.paths.run_logs(&job.id).join(format!("{run_id}.log"));
        if let Some(run) = st.runs.iter_mut().find(|r| r.id == run_id) {
            run.status = RunStatus::Running;
            run.started_at = Some(now());
            run.log = Some(log_path.to_string_lossy().into_owned());
        }
        st.running.insert(
            run_id.to_string(),
            Active { pid: None, deadline: Instant::now() + Duration::from_secs(job.timeout_secs), stop: None, killed: false },
        );
        self.save_runs(st);
        let engine = Arc::clone(self);
        let run_id = run_id.to_string();
        let spawned = std::thread::Builder::new()
            .name(format!("run-{run_id}"))
            .spawn(move || engine.execute(&run_id, &job, &log_path));
        if let Err(e) = spawned {
            log!("cannot start a thread for a run: {e}");
        }
    }

    /// The run thread: start the process, wait for it, record the end.
    fn execute(self: &Arc<Self>, run_id: &str, job: &Job, log_path: &Path) {
        let env = self.shell_env.get();
        // With tmux, a claude job runs in a console the user can open.
        let tmux = (job.kind == JobKind::Claude && console::find("claude", &env.path).is_some())
            .then(|| console::find("tmux", &env.path))
            .flatten();
        let command_line = if tmux.is_some() { job.console_command_line() } else { job.command_line(&env.shell) };
        let mut file = match open_log(log_path) {
            Ok(f) => f,
            Err(e) => return self.finish(run_id, None, format!("cannot open the log file {}: {e}", log_path.display())),
        };
        let _ = writeln!(file, "# {} run {run_id} started {}\n# in {}\n# {command_line}\n", self.instance, now().to_rfc3339(), job.dir);
        if !Path::new(&job.dir).is_dir() {
            return self.finish(run_id, None, format!("the folder {} does not exist", job.dir));
        }
        let secret_env = match self.read_secrets(job) {
            Ok(values) => values,
            Err(why) => return self.finish(run_id, None, why),
        };
        if !job.secret_env.is_empty() {
            let names: Vec<String> = job.secret_env.iter().map(|(var, name)| format!("{var} from {name}")).collect();
            let _ = writeln!(file, "# secrets: {}\n", names.join(", "));
        }
        // read_secrets gives the values in the order of secret_env.
        let values: Vec<(&str, &[u8])> =
            job.secret_env.values().map(String::as_str).zip(secret_env.iter().map(|(_, v)| v.as_bytes())).collect();
        let mut run_env: Vec<(OsString, OsString)> = vec![
            ("PATH".into(), env.path.clone().into()),
            ("SHELL".into(), env.shell.clone().into()),
            ("LOCALCRON_JOB_ID".into(), job.id.clone().into()),
            ("LOCALCRON_RUN_ID".into(), run_id.into()),
        ];
        if std::env::var_os("LANG").is_none() {
            run_env.push(("LANG".into(), "en_US.UTF-8".into()));
        }
        run_env.extend(job.env.iter().map(|(k, v)| (k.into(), v.into())));
        run_env.extend(secret_env.iter().map(|(k, v)| (k.into(), v.clone())));

        if let Some(tmux) = tmux
            && let Some((code, message)) = self.run_in_console(run_id, job, log_path, &mut file, tmux, &run_env)
        {
            if let Err(e) = scrub_file(log_path, &values) {
                log!("run {run_id}: cannot hide the secrets in its log: {e}");
            }
            return self.finish(run_id, code, message);
        }

        let (program, args) = job.argv(&env.shell);
        let (Ok(out), Ok(err)) = (file.try_clone(), file.try_clone()) else {
            return self.finish(run_id, None, "cannot share the log file with the process".into());
        };
        let mut command = Command::new(&program);
        command
            .args(&args)
            .current_dir(&job.dir)
            .stdin(Stdio::null())
            .stdout(out)
            .stderr(err)
            .envs(run_env.iter().map(|(k, v)| (k, v)))
            // Its own process group: a stop reaches every process it starts.
            .process_group(0);
        crate::unblock_signals_in_child(&mut command);
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(e) => {
                let why = if e.kind() == std::io::ErrorKind::NotFound {
                    format!("{program} was not found in PATH {}", env.path)
                } else {
                    format!("cannot start {program}: {e}")
                };
                return self.finish(run_id, None, why);
            }
        };
        let pid = child.id();
        {
            let mut st = self.lock();
            if let Some(active) = st.running.get_mut(run_id) {
                active.pid = Some(pid);
            }
            if let Some(run) = st.runs.iter_mut().find(|r| r.id == run_id) {
                run.pid = Some(pid);
            }
            self.save_runs(&st);
        }
        // A stop that came before the pid was known.
        self.notify();
        let status = child.wait();
        if let Err(e) = scrub_file(log_path, &values) {
            log!("run {run_id}: cannot hide the secrets in its log: {e}");
        }
        let message = match &status {
            Ok(s) => match (s.code(), s.signal()) {
                (Some(_), _) => String::new(),
                (None, Some(sig)) => format!("ended by signal {sig}"),
                _ => String::new(),
            },
            Err(e) => format!("cannot wait for the process: {e}"),
        };
        let code = status.ok().and_then(|s| s.code());
        self.finish(run_id, code, message);
    }

    /// A claude job in a tmux console (see console.rs). None when claude did
    /// not start its work there: the caller runs it without a console.
    /// Otherwise the exit code and message for `finish`.
    fn run_in_console(
        &self,
        run_id: &str,
        job: &Job,
        log_path: &Path,
        file: &mut File,
        tmux: std::path::PathBuf,
        run_env: &[(OsString, OsString)],
    ) -> Option<(Option<i32>, String)> {
        let console = Console::new(tmux, &self.instance.cli(), &job.id);
        let events = log_path.with_extension("events");
        let _ = fs::remove_file(&events);
        let mut env = run_env.to_vec();
        env.push(("LOCALCRON_EVENTS".into(), events.clone().into()));
        if let Err(e) = console.start(&job.console_argv(), &job.dir, &env) {
            let _ = writeln!(file, "# no console: {e}\n");
            return None;
        }
        let attach = console.attach_command();
        let pid = console.pid();
        {
            let mut st = self.lock();
            if let Some(active) = st.running.get_mut(run_id) {
                active.pid = pid;
            }
            if let Some(run) = st.runs.iter_mut().find(|r| r.id == run_id) {
                run.pid = pid;
                run.console = Some(attach.clone());
            }
            self.save_runs(&st);
        }
        // A stop that came before the pid was known.
        self.notify();
        let _ = writeln!(file, "# in a console; open it with: {attach}\n");
        let started_at = Instant::now();
        let grace = console::grace();
        let result = loop {
            std::thread::sleep(console::tick());
            let (started, finished) = console::events(&events);
            let stopping = self.lock().running.get(run_id).is_none_or(|a| a.stop.is_some());
            match console.pane() {
                Pane::Gone if started || stopping => break Some((None, "the console was closed".to_string())),
                Pane::Dead(status) if started || stopping => break Some((if finished { Some(0) } else { status }, String::new())),
                // Claude ended before it started: the run without a console says why.
                Pane::Gone | Pane::Dead(_) => break None,
                Pane::Alive if !started && !stopping && started_at.elapsed() > grace => break None,
                Pane::Alive if finished && !console.attached() => break Some((Some(0), String::new())),
                Pane::Alive => {}
            }
        };
        let screen = console.screen();
        console.close();
        let _ = fs::remove_file(&events);
        let _ = writeln!(file, "# the console at the end:\n{screen}\n");
        if result.is_none() {
            let _ = writeln!(
                file,
                "# Claude Code did not start its work in the console. A dialog may wait there, such as \"trust this \
                 folder?\": open the folder once in Claude Code and answer it. This run goes on without a console.\n"
            );
        }
        let mut st = self.lock();
        if let Some(run) = st.runs.iter_mut().find(|r| r.id == run_id) {
            run.console = None;
        }
        self.save_runs(&st);
        result
    }

    /// The values of the job's `secret_env`, read from the Keychain without
    /// the state lock. An error says which secret and the command that sets it.
    fn read_secrets(&self, job: &Job) -> Result<Vec<(String, std::ffi::OsString)>, String> {
        use std::os::unix::ffi::OsStringExt;
        if job.secret_env.is_empty() {
            return Ok(Vec::new());
        }
        if !Self::allowed(&self.lock(), job) {
            return Err(format!(
                "job {} may not read its secrets yet: the user allows it in the {} menu bar app (Jobs, Allow Secrets). \
                 A change to what the job runs needs a new approval",
                job.id, self.instance
            ));
        }
        let mut values = Vec::with_capacity(job.secret_env.len());
        for (var, name) in &job.secret_env {
            let command = secret::set_command(&self.instance, name);
            match self.keychain.get(name) {
                Ok(value) => values.push((var.clone(), std::ffi::OsString::from_vec(value))),
                Err(ReadError::Missing) => return Err(format!("secret {name} is not set: run {command} in a terminal")),
                Err(ReadError::Unreadable(why)) => {
                    return Err(format!("secret {name} cannot be read: {why}. Run {command} in a terminal to store it again"));
                }
            }
        }
        Ok(values)
    }

    /// Record the end of a run. `code` is None when the process never
    /// started or ended by a signal.
    fn finish(self: &Arc<Self>, run_id: &str, code: Option<i32>, message: String) {
        let mut st = self.lock();
        // shutdown has recorded the end already.
        if st.stopping {
            return;
        }
        let active = st.running.remove(run_id);
        let stop = active.and_then(|a| a.stop.map(|(s, _)| s));
        let Some(run) = st.runs.iter_mut().find(|r| r.id == run_id) else { return };
        run.ended_at = Some(now());
        run.exit_code = code;
        run.status = match (stop, code) {
            (Some(s), _) => s,
            (None, Some(0)) => RunStatus::Succeeded,
            _ => RunStatus::Failed,
        };
        run.message = match run.status {
            RunStatus::TimedOut => "stopped after timeout_secs".into(),
            RunStatus::Canceled if run.message.is_empty() => "canceled".into(),
            RunStatus::Canceled => run.message.clone(),
            _ => message,
        };
        let footer = format!(
            "\n# {} {:?} exit code {} {}\n",
            now().to_rfc3339(),
            run.status,
            code.map_or("none".into(), |c| c.to_string()),
            run.message
        );
        if let Some(path) = &run.log
            && let Ok(mut file) = OpenOptions::new().append(true).open(path)
        {
            let _ = file.write_all(footer.as_bytes());
        }
        log!("run {run_id}: {:?} {}", run.status, run.message);
        let (job_id, trigger, queued_at) = (run.job_id.clone(), run.trigger, run.queued_at);
        if !st.jobs.contains_key(&job_id) {
            self.forget_job_runs(&mut st, &job_id);
        }
        // A one-off job is done after its time came. Only when it is still
        // the job that was queued: a change since then gave it a new time.
        let done = st.jobs.get(&job_id).is_some_and(|s| {
            s.schedule.is_once() && !s.job.enabled && trigger != Trigger::Manual && s.job.updated_at.is_none_or(|u| u <= queued_at)
        });
        if done {
            self.remove_done(&mut st, &job_id);
        }
        self.prune(&mut st, &job_id);
        self.save_runs(&st);
        drop(st);
        self.notify();
    }

    /// Keep the newest `keep_runs` finished runs of a job; delete the logs of
    /// the others.
    fn prune(&self, st: &mut State, job_id: &str) {
        let keep = st.config.keep_runs as usize;
        let finished: Vec<usize> =
            st.runs.iter().enumerate().filter(|(_, r)| r.job_id == job_id && r.status.is_finished()).map(|(i, _)| i).collect();
        if finished.len() <= keep {
            return;
        }
        let drop_set: Vec<usize> = finished[..finished.len() - keep].to_vec();
        for i in drop_set.iter().rev() {
            let run = st.runs.remove(*i);
            if let Some(path) = run.log {
                let _ = fs::remove_file(path);
            }
        }
    }

    /// Remove a one-off job after its run. Unlike `remove_job`, its runs
    /// stay, so the output can still be read.
    fn remove_done(&self, st: &mut State, job_id: &str) {
        let Some(old) = st.jobs.remove(job_id) else { return };
        if self.save_jobs(st).is_err() {
            st.jobs.insert(job_id.to_string(), old);
            return;
        }
        if st.grants.remove(job_id).is_some() {
            let _ = self.save_secrets(st);
        }
        log!("job {job_id}: removed after its one run");
        self.prune_removed(st);
    }

    /// Keep the newest `keep_runs` finished runs of removed one-off jobs, in
    /// all; delete the logs of the others.
    fn prune_removed(&self, st: &mut State) {
        let keep = st.config.keep_runs as usize;
        let gone: Vec<usize> = st
            .runs
            .iter()
            .enumerate()
            .filter(|(_, r)| r.status.is_finished() && !st.jobs.contains_key(&r.job_id))
            .map(|(i, _)| i)
            .collect();
        if gone.len() <= keep {
            return;
        }
        for i in gone[..gone.len() - keep].iter().rev() {
            let run = st.runs.remove(*i);
            if let Some(path) = run.log {
                let _ = fs::remove_file(path);
            }
            if !st.runs.iter().any(|r| r.job_id == run.job_id) {
                let _ = fs::remove_dir_all(self.paths.run_logs(&run.job_id));
            }
        }
    }

    fn forget_job_runs(&self, st: &mut State, job_id: &str) {
        st.runs.retain(|r| r.job_id != job_id || !r.status.is_finished());
        if !st.runs.iter().any(|r| r.job_id == job_id) {
            let _ = fs::remove_dir_all(self.paths.run_logs(job_id));
        }
    }

    fn save_runs(&self, st: &State) {
        let file = RunsFile { version: 1, next_seq: st.next_seq, runs: st.runs.clone() };
        if let Err(e) = store::save(&self.paths.runs(), &file) {
            log!("cannot save {}: {e}", self.paths.runs().display());
        }
    }

    fn save_jobs(&self, st: &State) -> ApiResult<()> {
        let file = JobsFile { version: 1, jobs: st.jobs.values().map(|s| s.job.clone()).collect() };
        store::save(&self.paths.jobs(), &file).map_err(|e| {
            log!("cannot save {}: {e}", self.paths.jobs().display());
            internal(format!("cannot save {}: {e}", self.paths.jobs().display()))
        })
    }

    /// Stop the scheduler and every running process. Runs end as canceled.
    pub fn shutdown(&self) {
        let mut st = self.lock();
        st.stopping = true;
        let at = now();
        let running: Vec<(String, Option<u32>)> = st.running.iter().map(|(id, a)| (id.clone(), a.pid)).collect();
        for (run_id, pid) in running {
            if let Some(pid) = pid {
                signal_group(pid, libc::SIGTERM);
            }
            if let Some(run) = st.runs.iter_mut().find(|r| r.id == run_id) {
                run.status = RunStatus::Canceled;
                run.ended_at = Some(at);
                run.message = "LocalCron stopped".into();
            }
        }
        for run in st.runs.iter_mut().filter(|r| r.status == RunStatus::Queued) {
            run.status = RunStatus::Canceled;
            run.ended_at = Some(at);
            run.message = "LocalCron stopped".into();
        }
        st.running.clear();
        st.queue.clear();
        self.save_runs(&st);
        drop(st);
        self.notify();
    }

    // MARK: API

    /// The user allowed the job, as it is now, to read its secrets.
    fn allowed(st: &State, job: &Job) -> bool {
        st.grants.get(&job.id).is_some_and(|g| g.scope == job.secret_scope())
    }

    fn view(&self, st: &State, slot: &Slot) -> JobView {
        let mut runs = st.runs.iter().filter(|r| r.job_id == slot.job.id);
        JobView {
            secrets_allowed: (!slot.job.secret_env.is_empty()).then(|| Self::allowed(st, &slot.job)),
            job: slot.job.clone(),
            schedule_text: slot.schedule.describe(),
            next_run: slot.job.enabled.then_some(slot.next_due).flatten().map(|d| d.fixed_offset()),
            last_run: runs.clone().rfind(|r| r.status.is_finished()).cloned(),
            active_run: runs.rfind(|r| !r.status.is_finished()).cloned(),
        }
    }

    pub fn status(&self) -> StatusResult {
        let st = self.lock();
        let next = st
            .jobs
            .values()
            .filter(|s| s.job.enabled)
            .filter_map(|s| s.next_due.map(|d| (d, &s.job.id)))
            .min()
            .map(|(at, id)| NextRun { job_id: id.clone(), at: at.fixed_offset() });
        StatusResult {
            daemon_version: DAEMON_VERSION.into(),
            api_version: api::API_VERSION.into(),
            pid: std::process::id(),
            started_at: self.started_at,
            jobs: st.jobs.len(),
            enabled_jobs: st.jobs.values().filter(|s| s.job.enabled).count(),
            running: st.running.len(),
            queued: st.queue.len(),
            max_concurrent: st.config.max_concurrent,
            paused: st.config.paused,
            next,
            data_dir: self.paths.data.to_string_lossy().into_owned(),
            logs_dir: self.paths.logs.to_string_lossy().into_owned(),
        }
    }

    pub fn list_jobs(&self) -> ListJobsResult {
        let st = self.lock();
        ListJobsResult { jobs: st.jobs.values().map(|s| self.view(&st, s)).collect() }
    }

    pub fn get_job(&self, id: &str) -> ApiResult<JobView> {
        let st = self.lock();
        st.jobs.get(id).map(|s| self.view(&st, s)).ok_or_else(|| not_found_job(id))
    }

    pub fn set_job(&self, params: SetJobParams) -> ApiResult<SetJobResult> {
        let mut job = params.job;
        let local_now = Local::now();
        job.schedule = schedule::resolve(&job.schedule, &local_now).map_err(|e| invalid(e.0))?;
        let schedule = job.validate().map_err(invalid)?;
        if !Path::new(&job.dir).is_dir() {
            return Err(invalid(format!("dir {} is not a folder", job.dir)));
        }
        let next_due = schedule.next_after(&local_now);
        if schedule.is_once() && next_due.is_none() && job.enabled {
            return Err(invalid(format!("{} is in the past", job.schedule)));
        }
        job.updated_at = Some(now());
        let mut st = self.lock();
        let created = !st.jobs.contains_key(&job.id);
        if !created && !params.replace {
            return Err(ApiError::new(
                ErrorCode::Exists,
                format!("job {:?} exists; give replace: true to change it, or choose another id", job.id),
            ));
        }
        let same_schedule = st.jobs.get(&job.id).is_some_and(|s| s.job.schedule == job.schedule);
        let next_due = if same_schedule { next_free(&st.runs, &job.id, &schedule, local_now) } else { next_due };
        let id = job.id.clone();
        let old = st.jobs.insert(id.clone(), Slot { job, schedule, next_due });
        if let Err(e) = self.save_jobs(&st) {
            match old {
                Some(old) => st.jobs.insert(id, old),
                None => st.jobs.remove(&id),
            };
            return Err(e);
        }
        log!("job {id}: {}", if created { "added" } else { "changed" });
        let view = self.view(&st, &st.jobs[&id]);
        let missing_secrets = view
            .job
            .secret_env
            .iter()
            .filter(|(_, name)| !st.secrets.contains_key(*name))
            .map(|(var, name)| MissingSecret { name: name.clone(), env: var.clone(), set_command: secret::set_command(&self.instance, name) })
            .collect();
        drop(st);
        self.notify();
        Ok(SetJobResult { job: view, created, missing_secrets })
    }

    pub fn remove_job(&self, id: &str) -> ApiResult<RemoveJobResult> {
        let mut st = self.lock();
        let Some(old) = st.jobs.remove(id) else { return Ok(RemoveJobResult { removed: false }) };
        if let Err(e) = self.save_jobs(&st) {
            st.jobs.insert(id.to_string(), old);
            return Err(e);
        }
        let queued: Vec<String> =
            st.runs.iter().filter(|r| r.job_id == id && r.status == RunStatus::Queued).map(|r| r.id.clone()).collect();
        for run_id in queued {
            Self::cancel_locked(&mut st, &run_id, "the job was removed", false);
        }
        let running: Vec<String> = st.running.keys().filter(|r| run_job_id(r) == id).cloned().collect();
        for run_id in running {
            Self::cancel_locked(&mut st, &run_id, "the job was removed", false);
        }
        self.forget_job_runs(&mut st, id);
        self.save_runs(&st);
        if st.grants.remove(id).is_some() {
            let _ = self.save_secrets(&st);
        }
        log!("job {id}: removed");
        drop(st);
        self.notify();
        Ok(RemoveJobResult { removed: true })
    }

    pub fn set_job_enabled(&self, id: &str, enabled: bool) -> ApiResult<JobView> {
        let mut st = self.lock();
        let State { jobs, runs, .. } = &mut *st;
        let slot = jobs.get_mut(id).ok_or_else(|| not_found_job(id))?;
        let before = (slot.job.enabled, slot.job.updated_at, slot.next_due);
        if slot.job.enabled != enabled {
            let next_due = next_free(runs, id, &slot.schedule, Local::now());
            slot.job.enabled = enabled;
            slot.job.updated_at = Some(now());
            slot.next_due = next_due;
            if let Err(e) = self.save_jobs(&st) {
                let slot = st.jobs.get_mut(id).expect("the job was just read");
                (slot.job.enabled, slot.job.updated_at, slot.next_due) = before;
                return Err(e);
            }
            log!("job {id}: {}", if enabled { "on" } else { "off" });
        }
        let view = self.view(&st, &st.jobs[id]);
        drop(st);
        self.notify();
        Ok(view)
    }

    /// A run more; with `early`, the next scheduled time runs now and does
    /// not run again at its time.
    pub fn run_job(&self, params: RunJobParams) -> ApiResult<Run> {
        let id = params.id.as_str();
        let mut st = self.lock();
        let slot = st.jobs.get(id).ok_or_else(|| not_found_job(id))?;
        if !params.early {
            let run = self.enqueue(&mut st, id, Trigger::Manual, None);
            drop(st);
            self.notify();
            return Ok(run);
        }
        let Some(due) = slot.job.enabled.then_some(slot.next_due).flatten() else {
            return Err(invalid(format!("job {id:?} has no next run to run early: it is off, or its one time has passed")));
        };
        let run = self.enqueue(&mut st, id, Trigger::Early, Some(due.fixed_offset()));
        if run.status == RunStatus::Queued {
            let slot = st.jobs.get_mut(id).expect("the job was just read");
            slot.next_due = slot.schedule.next_after(&due);
            if slot.schedule.is_once() {
                slot.job.enabled = false;
                let _ = self.save_jobs(&st);
            }
            log!("job {id}: {due} runs early; next {:?}", st.jobs[id].next_due);
        }
        drop(st);
        self.notify();
        Ok(run)
    }

    /// A queued run is removed from the queue; a running one gets SIGTERM
    /// from the scheduler, then SIGKILL. With `force` the scheduler sends
    /// SIGKILL at once, also to a run that is already stopping.
    fn cancel_locked(st: &mut State, run_id: &str, why: &str, force: bool) -> bool {
        if let Some(active) = st.running.get_mut(run_id) {
            let changed = match active.stop {
                None if force => {
                    active.stop = Some((RunStatus::Canceled, Some(grace_over())));
                    true
                }
                None => {
                    active.stop = Some((RunStatus::Canceled, None));
                    true
                }
                // A timed-out run stays timed out; it is only killed sooner.
                Some((status, _)) if force && !active.killed => {
                    active.stop = Some((status, Some(grace_over())));
                    true
                }
                Some(_) => false,
            };
            if changed && let Some(run) = st.runs.iter_mut().find(|r| r.id == run_id) {
                run.message = why.into();
            }
            return changed;
        }
        if let Some(pos) = st.queue.iter().position(|r| r == run_id) {
            st.queue.remove(pos);
            if let Some(run) = st.runs.iter_mut().find(|r| r.id == run_id) {
                run.status = RunStatus::Canceled;
                run.ended_at = Some(now());
                run.message = why.into();
            }
            return true;
        }
        false
    }

    pub fn cancel_run(&self, run_id: &str, force: bool) -> ApiResult<CancelRunResult> {
        let mut st = self.lock();
        if !st.runs.iter().any(|r| r.id == run_id) {
            return Err(ApiError::new(ErrorCode::NotFound, format!("no run {run_id:?}")));
        }
        let canceled = Self::cancel_locked(&mut st, run_id, if force { "killed" } else { "canceled" }, force);
        if canceled {
            log!("run {run_id}: {}", if force { "kill" } else { "cancel" });
            self.save_runs(&st);
        }
        let run = st.runs.iter().find(|r| r.id == run_id).cloned().expect("checked above");
        drop(st);
        self.notify();
        Ok(CancelRunResult { canceled, run })
    }

    pub fn list_runs(&self, params: ListRunsParams) -> ListRunsResult {
        let st = self.lock();
        let limit = params.limit.unwrap_or(50);
        let runs = st
            .runs
            .iter()
            .rev()
            .filter(|r| params.job_id.as_deref().is_none_or(|id| r.job_id == id))
            .take(limit)
            .cloned()
            .collect();
        ListRunsResult { runs }
    }

    pub fn get_run_log(&self, params: GetRunLogParams) -> ApiResult<GetRunLogResult> {
        let run = {
            let st = self.lock();
            st.runs.iter().find(|r| r.id == params.run_id).cloned()
        }
        .ok_or_else(|| ApiError::new(ErrorCode::NotFound, format!("no run {:?}", params.run_id)))?;
        let Some(path) = run.log.clone() else {
            return Ok(GetRunLogResult { run, text: String::new(), truncated: false, size: 0 });
        };
        let max = params.max_bytes.unwrap_or(DEFAULT_LOG_BYTES).clamp(1, MAX_LOG_BYTES);
        let (text, size) = read_tail(Path::new(&path), max).map_err(|e| internal(format!("cannot read {path}: {e}")))?;
        // The file is cleaned when the run ends; this covers a run in progress.
        let text = self.hide_secrets(&run.job_id, text);
        Ok(GetRunLogResult { truncated: size > text.len() as u64, run, text, size })
    }

    pub fn preview_schedule(&self, params: PreviewScheduleParams) -> ApiResult<PreviewScheduleResult> {
        let mut from = Local::now();
        let text = schedule::resolve(&params.schedule, &from).map_err(|e| invalid(e.0))?;
        let schedule = Schedule::parse(&text).map_err(|e| invalid(e.0))?;
        let mut next = Vec::new();
        for _ in 0..params.count.unwrap_or(5).clamp(1, 20) {
            let Some(t) = schedule.next_after(&from) else { break };
            next.push(t.fixed_offset());
            from = t;
        }
        Ok(PreviewScheduleResult { description: schedule.describe(), next })
    }

    pub fn get_config(&self) -> Config {
        self.lock().config.clone()
    }

    pub fn set_config(&self, params: SetConfigParams) -> ApiResult<Config> {
        let mut st = self.lock();
        let mut config = st.config.clone();
        if let Some(n) = params.max_concurrent {
            config.max_concurrent = n;
        }
        if let Some(n) = params.keep_runs {
            config.keep_runs = n;
        }
        let was_paused = st.config.paused;
        if let Some(paused) = params.paused {
            config.paused = paused;
            if was_paused && !paused {
                config.resumed_at = Some(now());
            }
        }
        config.validate().map_err(invalid)?;
        store::save(&self.paths.config(), &config).map_err(|e| internal(format!("cannot save the config: {e}")))?;
        st.config = config.clone();
        match (was_paused, config.paused) {
            (false, true) => {
                let queued: Vec<String> = st
                    .runs
                    .iter()
                    .filter(|r| r.status == RunStatus::Queued && !matches!(r.trigger, Trigger::Manual | Trigger::Early))
                    .map(|r| r.id.clone())
                    .collect();
                for run_id in &queued {
                    Self::cancel_locked(&mut st, run_id, "LocalCron was paused", false);
                }
                self.save_runs(&st);
                log!("paused; {} queued runs canceled", queued.len());
            }
            (true, false) => {
                // Times that passed while paused are not caught up.
                let local_now = Local::now();
                let State { jobs, runs, .. } = &mut *st;
                for slot in jobs.values_mut() {
                    slot.next_due = next_free(runs, &slot.job.id, &slot.schedule, local_now);
                }
                log!("resumed");
            }
            _ => {}
        }
        drop(st);
        self.notify();
        Ok(config)
    }

    // MARK: Secrets

    fn save_secrets(&self, st: &State) -> ApiResult<()> {
        let file = SecretsFile { version: 1, secrets: st.secrets.values().cloned().collect(), grants: st.grants.values().cloned().collect() };
        store::save(&self.paths.secrets(), &file).map_err(|e| {
            log!("cannot save {}: {e}", self.paths.secrets().display());
            internal(format!("cannot save {}: {e}", self.paths.secrets().display()))
        })
    }

    fn used_by(st: &State, name: &str) -> Vec<String> {
        st.jobs.values().filter(|s| s.job.secret_env.values().any(|n| n == name)).map(|s| s.job.id.clone()).collect()
    }

    /// `state` from the Keychain; call it without the state lock.
    fn secret_info(&self, entry: &SecretEntry, used_by: Vec<String>) -> SecretInfo {
        let (state, message) = match self.keychain.get(&entry.name) {
            Ok(_) => (SecretState::Ok, String::new()),
            Err(ReadError::Missing) => (SecretState::Missing, "no value in the Keychain".to_string()),
            Err(ReadError::Unreadable(why)) => (SecretState::Unreadable, why),
        };
        SecretInfo {
            name: entry.name.clone(),
            description: entry.description.clone(),
            updated_at: entry.updated_at,
            state,
            message,
            used_by,
            set_command: secret::set_command(&self.instance, &entry.name),
        }
    }

    pub fn list_secrets(&self) -> ListSecretsResult {
        let entries: Vec<(SecretEntry, Vec<String>)> = {
            let st = self.lock();
            st.secrets.values().map(|e| (e.clone(), Self::used_by(&st, &e.name))).collect()
        };
        ListSecretsResult { secrets: entries.into_iter().map(|(e, used)| self.secret_info(&e, used)).collect() }
    }

    /// The value goes to the Keychain first: when that fails nothing changes.
    /// The value is never logged.
    pub fn set_secret(&self, params: SetSecretParams) -> ApiResult<SetSecretResult> {
        let name = params.name;
        secret::check_name(&name).map_err(invalid)?;
        if let Some(d) = &params.description {
            secret::check_description(d).map_err(invalid)?;
        }
        if let Some(value) = &params.value {
            secret::check_value(value).map_err(invalid)?;
        } else if !self.lock().secrets.contains_key(&name) {
            return Err(ApiError::new(ErrorCode::NotFound, format!("no secret {name:?}; give a value to make it")));
        }
        if let Some(value) = &params.value {
            self.keychain.set(&name, value.as_bytes()).map_err(|e| internal(format!("cannot store {name} in the Keychain: {e}")))?;
        }
        let mut st = self.lock();
        let old = st.secrets.get(&name).cloned();
        let created = old.is_none();
        let entry = SecretEntry {
            name: name.clone(),
            description: params.description.or_else(|| old.as_ref().map(|o| o.description.clone())).unwrap_or_default(),
            updated_at: if params.value.is_some() { now() } else { old.as_ref().map_or_else(now, |o| o.updated_at) },
        };
        st.secrets.insert(name.clone(), entry.clone());
        if let Err(e) = self.save_secrets(&st) {
            match old {
                Some(old) => st.secrets.insert(name, old),
                None => st.secrets.remove(&name),
            };
            return Err(e);
        }
        let used_by = Self::used_by(&st, &name);
        drop(st);
        log!("secret {name}: {}", if created { "added" } else if params.value.is_some() { "new value" } else { "new description" });
        Ok(SetSecretResult { secret: self.secret_info(&entry, used_by), created })
    }

    /// Only the menu bar app, after the user confirmed the job it sends.
    pub fn allow_job_secrets(&self, params: AllowJobSecretsParams, trust: &Trust) -> ApiResult<JobView> {
        if !trust.app {
            return Err(ApiError::new(
                ErrorCode::NotAllowed,
                format!("only the {} menu bar app can allow a job to read secrets, after the user confirms there", self.instance),
            ));
        }
        let id = params.job.id.clone();
        let seen = params.job.secret_scope();
        let mut st = self.lock();
        let slot = st.jobs.get(&id).ok_or_else(|| not_found_job(&id))?;
        // Compared by content, not by time: a change in the same second
        // must not pass.
        if slot.job.secret_scope() != seen {
            return Err(invalid(format!("job {id} changed after it was shown; look at it again")));
        }
        if slot.job.secret_env.is_empty() {
            return Err(invalid(format!("job {id} has no secret_env")));
        }
        let grant = Grant { job_id: id.clone(), scope: seen, allowed_at: now() };
        let old = st.grants.insert(id.clone(), grant);
        if let Err(e) = self.save_secrets(&st) {
            match old {
                Some(old) => st.grants.insert(id.clone(), old),
                None => st.grants.remove(&id),
            };
            return Err(e);
        }
        log!("job {id}: allowed to read its secrets");
        Ok(self.view(&st, &st.jobs[&id]))
    }

    /// Each value of the job's secrets in `text` becomes `<secret NAME>`.
    fn hide_secrets(&self, job_id: &str, text: String) -> String {
        let names: Vec<String> = self.lock().jobs.get(job_id).map(|s| s.job.secret_env.values().cloned().collect()).unwrap_or_default();
        let values: Vec<(String, Vec<u8>)> = names.into_iter().filter_map(|n| self.keychain.get(&n).ok().map(|v| (n, v))).collect();
        let pairs: Vec<(&str, &[u8])> = values.iter().map(|(n, v)| (n.as_str(), v.as_slice())).collect();
        String::from_utf8(hide(text.as_bytes(), &pairs)).unwrap_or(text)
    }

    pub fn remove_secret(&self, name: &str) -> ApiResult<RemoveSecretResult> {
        let mut st = self.lock();
        let old = st.secrets.remove(name);
        if old.is_some()
            && let Err(e) = self.save_secrets(&st)
        {
            st.secrets.insert(name.to_string(), old.expect("checked above"));
            return Err(e);
        }
        let used_by = Self::used_by(&st, name);
        drop(st);
        let had_value = self.keychain.delete(name).map_err(|e| internal(format!("cannot remove {name} from the Keychain: {e}")))?;
        let removed = old.is_some() || had_value;
        if removed {
            log!("secret {name}: removed");
        }
        Ok(RemoveSecretResult { removed, used_by })
    }
}

/// The first due time after a start: the first time after the last run (or
/// the last change), so a time missed while the daemon was stopped is caught
/// up. Without catch_up, the first time from now.
fn first_due(job: &Job, schedule: &Schedule, last_due: Option<DateTime<FixedOffset>>, now: DateTime<Local>) -> Option<DateTime<Local>> {
    let base = [last_due, job.updated_at].into_iter().flatten().max().map(|t| t.with_timezone(&Local)).unwrap_or(now);
    let next = match schedule.next_after(&base.min(now)) {
        Some(t) if t <= now && !job.catch_up => schedule.next_after(&now),
        other => other,
    };
    // An early run took a time that may still be ahead.
    match last_due.map(|d| d.with_timezone(&Local)) {
        Some(taken) if next.is_some_and(|t| t <= taken) => schedule.next_after(&taken),
        _ => next,
    }
}

/// The next time after `now` that no early run took already.
fn next_free(runs: &[Run], job_id: &str, schedule: &Schedule, now: DateTime<Local>) -> Option<DateTime<Local>> {
    let taken = runs.iter().filter(|r| r.job_id == job_id && r.trigger == Trigger::Early).filter_map(|r| r.due_at).max();
    let after = taken.map(|t| t.with_timezone(&Local)).filter(|t| *t > now).unwrap_or(now);
    schedule.next_after(&after)
}

/// A SIGTERM time so old that the scheduler sends SIGKILL at its next look.
fn grace_over() -> Instant {
    let now = Instant::now();
    now.checked_sub(KILL_GRACE).unwrap_or(now)
}

/// `weekly-review.12` belongs to `weekly-review`.
fn run_job_id(run_id: &str) -> &str {
    run_id.rsplit_once('.').map_or(run_id, |(job, _)| job)
}

fn signal_group(pid: u32, signal: i32) {
    // SAFETY: kill has no memory effects; a negative pid is the process group.
    unsafe {
        libc::kill(-(pid as i32), signal);
    }
}

fn open_log(path: &Path) -> std::io::Result<File> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    OpenOptions::new().create(true).append(true).open(path)
}

/// Values shorter than this are left alone: hiding "a" would change every
/// word. A token is much longer.
const MIN_HIDDEN: usize = 4;

/// Each value becomes `<secret NAME>`.
fn hide(text: &[u8], secrets: &[(&str, &[u8])]) -> Vec<u8> {
    let mut out = text.to_vec();
    for (name, value) in secrets.iter().filter(|(_, v)| v.len() >= MIN_HIDDEN) {
        let mark = format!("<secret {name}>").into_bytes();
        let mut next = Vec::with_capacity(out.len());
        let mut i = 0;
        while i < out.len() {
            if out[i..].starts_with(value) {
                next.extend_from_slice(&mark);
                i += value.len();
            } else {
                next.push(out[i]);
                i += 1;
            }
        }
        out = next;
    }
    out
}

/// A log longer than this is left as it is when the run ends.
const MAX_SCRUB: u64 = 64 * 1024 * 1024;

/// Hide the values in a finished run's log file.
fn scrub_file(path: &Path, secrets: &[(&str, &[u8])]) -> std::io::Result<()> {
    if secrets.is_empty() || fs::metadata(path)?.len() > MAX_SCRUB {
        return Ok(());
    }
    let text = fs::read(path)?;
    let clean = hide(&text, secrets);
    if clean != text {
        fs::write(path, clean)?;
    }
    Ok(())
}

/// The last `max` bytes of a file, as text, and the file's size.
fn read_tail(path: &Path, max: u64) -> std::io::Result<(String, u64)> {
    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((String::new(), 0)),
        Err(e) => return Err(e),
    };
    let size = file.metadata()?.len();
    file.seek(SeekFrom::Start(size.saturating_sub(max)))?;
    let mut bytes = Vec::new();
    file.take(max).read_to_end(&mut bytes)?;
    Ok((String::from_utf8_lossy(&bytes).into_owned(), size))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn job(schedule: &str, catch_up: bool, updated: &str) -> (Job, Schedule) {
        let job: Job = serde_json::from_value(serde_json::json!({
            "id": "a", "schedule": schedule, "kind": "shell", "command": "true", "dir": "/tmp",
            "catch_up": catch_up, "updated_at": updated,
        }))
        .unwrap();
        let s = job.validate().unwrap();
        (job, s)
    }

    fn local(s: &str) -> DateTime<Local> {
        Local.from_local_datetime(&chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M").unwrap()).unwrap()
    }

    #[test]
    fn missed_time_is_caught_up_once_after_a_restart() {
        // Saved Monday; Wednesday 09:00 passed while the Mac was off; it is Thursday now.
        let (j, s) = job("0 9 * * wed", true, &local("2026-10-26 10:00").fixed_offset().to_rfc3339());
        let due = first_due(&j, &s, None, local("2026-10-29 12:00")).unwrap();
        assert_eq!(due, local("2026-10-28 09:00"));
    }

    #[test]
    fn without_catch_up_the_next_time_is_after_now() {
        let (j, s) = job("0 9 * * wed", false, &local("2026-10-26 10:00").fixed_offset().to_rfc3339());
        let due = first_due(&j, &s, None, local("2026-10-29 12:00")).unwrap();
        assert_eq!(due, local("2026-11-04 09:00"));
    }

    #[test]
    fn a_time_already_run_is_not_run_again() {
        let (j, s) = job("0 9 * * wed", true, &local("2026-10-01 10:00").fixed_offset().to_rfc3339());
        let last = Some(local("2026-10-28 09:00").fixed_offset());
        let due = first_due(&j, &s, last, local("2026-10-29 12:00")).unwrap();
        assert_eq!(due, local("2026-11-04 09:00"));
    }

    #[test]
    fn a_time_an_early_run_took_is_not_run_after_a_restart() {
        let (j, s) = job("0 12 * * fri", true, &local("2026-10-01 10:00").fixed_offset().to_rfc3339());
        // Friday 12:00 ran early at 10:00; the daemon starts again at 11:00.
        let last = Some(local("2026-10-30 12:00").fixed_offset());
        let due = first_due(&j, &s, last, local("2026-10-30 11:00")).unwrap();
        assert_eq!(due, local("2026-11-06 12:00"));
    }

    #[test]
    fn a_time_missed_while_paused_is_not_caught_up() {
        let (j, s) = job("0 9 * * wed", true, &local("2026-10-26 10:00").fixed_offset().to_rfc3339());
        // Paused over Wednesday 09:00, resumed Thursday 08:00.
        let resumed = Some(local("2026-10-29 08:00").fixed_offset());
        let due = first_due(&j, &s, resumed, local("2026-10-29 12:00")).unwrap();
        assert_eq!(due, local("2026-11-04 09:00"));
    }

    #[test]
    fn values_are_hidden_and_short_ones_are_not() {
        let text = b"token=ghp_abc123 again ghp_abc123, a=x";
        let out = hide(text, &[("github-token", b"ghp_abc123"), ("short", b"x")]);
        assert_eq!(String::from_utf8(out).unwrap(), "token=<secret github-token> again <secret github-token>, a=x");
    }

    #[test]
    fn run_ids_name_their_job() {
        assert_eq!(run_job_id("weekly-review.12"), "weekly-review");
    }
}
