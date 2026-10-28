//! The CLI against a real daemon.

mod common;

use common::Daemon;

#[test]
fn add_list_run_and_read_the_log() {
    let d = Daemon::start();
    let (ok, out, err, _) = d.cli(&["add", "greet", "--schedule", "0 9 * * wed", "--command", "echo hi from cron; exit 4"]);
    assert!(ok, "{err}");
    assert!(out.contains("Added greet") && out.contains("At 09:00 on Wednesday"), "{out}");
    // The folder defaults to the current one.
    let canonical = d.home().canonicalize().unwrap();
    assert!(out.contains(&canonical.to_string_lossy().to_string()) || out.contains(&d.home().to_string_lossy().to_string()), "{out}");

    let (_, out, _, _) = d.cli(&["list"]);
    assert!(out.starts_with("greet") && out.contains("next "), "{out}");

    // --wait prints the output and exits with the run's code.
    let (ok, out, _, code) = d.cli(&["run", "greet", "--wait"]);
    assert!(!ok);
    assert_eq!(code, Some(4));
    assert!(out.contains("hi from cron"), "{out}");

    let (_, out, _, _) = d.cli(&["runs", "greet"]);
    assert!(out.contains("greet.") && out.contains("failed") && out.contains("exit 4"), "{out}");

    let (ok, _, err, _) = d.cli(&["add", "greet", "--schedule", "@daily", "--command", "true"]);
    assert!(!ok && err.contains("replace"), "{err}");
    let (ok, out, _, _) = d.cli(&["add", "greet", "--schedule", "@daily", "--command", "true", "--replace"]);
    assert!(ok && out.contains("Changed greet"), "{out}");
    let (ok, _, _, code) = d.cli(&["run", "greet", "--wait"]);
    assert!(ok && code == Some(0));

    let (_, out, _, _) = d.cli(&["disable", "greet"]);
    assert!(out.contains("(off"), "{out}");
    let (ok, out, _, _) = d.cli(&["remove", "greet"]);
    assert!(ok && out.contains("Removed greet"));
    let (ok, _, err, _) = d.cli(&["remove", "greet"]);
    assert!(!ok && err.contains("no job"));
}

#[test]
fn agent_jobs_take_their_options() {
    let d = Daemon::start();
    let (ok, out, err, _) = d.cli(&[
        "add", "review", "--schedule", "30 8 * * mon-fri", "--claude", "Sum up new issues", "--model", "sonnet",
        "--permission-mode", "acceptEdits", "--arg", "--max-turns", "--arg", "10", "--env", "A=1", "--timeout", "20m", "--json",
    ]);
    assert!(ok, "{err}");
    let v: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(v["job"]["kind"], "claude");
    assert_eq!(v["job"]["args"], serde_json::json!(["--max-turns", "10"]));
    assert_eq!(v["job"]["timeout_secs"], 1200);
    assert_eq!(v["job"]["env"]["A"], "1");
    assert_eq!(v["job"]["schedule_text"], "At 08:30 on weekdays");

    let (ok, _, err, _) = d.cli(&["add", "both", "--schedule", "@daily", "--command", "ls", "--claude", "x"]);
    assert!(!ok && err.contains("cannot be used with"), "{err}");
}

#[test]
fn next_status_config_and_not_running() {
    let d = Daemon::start();
    let (_, out, _, _) = d.cli(&["next", "0 9 * * wed", "--count", "2"]);
    assert!(out.starts_with("At 09:00 on Wednesday\n") && out.matches("  Wed ").count() == 2, "{out}");
    let (ok, _, err, _) = d.cli(&["next", "0 9 * *"]);
    assert!(!ok && err.contains("5 fields"));
    let (_, out, _, _) = d.cli(&["config", "--max-concurrent", "4"]);
    assert!(out.contains("max_concurrent: 4"));
    let (_, out, _, _) = d.cli(&["status"]);
    assert!(out.contains("jobs: 0") && out.contains("max at once: 4"), "{out}");

    let empty = tempfile::tempdir().unwrap();
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_localcron")).arg("list").env("LOCALCRON_HOME", empty.path()).output().unwrap();
    assert!(String::from_utf8_lossy(&out.stderr).contains("LocalCron is not running"));
}

#[test]
fn the_note_names_this_instance() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_localcron")).arg("note").output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.starts_with("# LocalCron\n") && text.contains("add_job"), "{text}");
}
