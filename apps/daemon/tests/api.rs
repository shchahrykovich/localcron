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
        let child = Command::new(env!("CARGO_BIN_EXE_localcrond"))
            .env("LOCALCRON_HOME", home.path())
            // No ~/.local/bin with a real claude in it.
            .env("HOME", home.path())
            .env("LOCALCRON_PATH", "/usr/bin:/bin")
            .env("SHELL", "/bin/sh")
            .spawn()
            .unwrap();
        let d = Daemon { child, home };
        wait_for(|| d.socket().exists(), "the socket");
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
