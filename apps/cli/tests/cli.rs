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
fn pause_resume_and_kill() {
    let d = Daemon::start();
    let (ok, out, err, _) = d.cli(&["pause"]);
    assert!(ok && out.contains("Paused"), "{out}{err}");
    let (_, out, _, _) = d.cli(&["status"]);
    assert!(out.contains("paused: scheduled runs do not start"), "{out}");
    let (_, out, _, _) = d.cli(&["config"]);
    assert!(out.contains("paused: true"), "{out}");

    // A run someone asks for still starts while paused.
    d.cli(&["add", "stuck", "--schedule", "@daily", "--command", "trap '' TERM; sleep 30"]);
    let (_, out, _, _) = d.cli(&["run", "stuck"]);
    let run_id = out.split_whitespace().next().unwrap().to_string();
    let start = std::time::Instant::now();
    while !d.cli(&["runs", "stuck"]).1.contains("running") {
        assert!(start.elapsed().as_secs() < 10, "the run did not start");
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    std::thread::sleep(std::time::Duration::from_millis(300));
    let (ok, out, _, _) = d.cli(&["cancel", &run_id, "--kill"]);
    assert!(ok && out.contains(&format!("Killing {run_id}")), "{out}");
    while !d.cli(&["runs", "stuck"]).1.contains("killed") {
        assert!(start.elapsed().as_secs() < 8, "the run was not killed at once");
        std::thread::sleep(std::time::Duration::from_millis(100));
    }

    let (ok, out, _, _) = d.cli(&["resume"]);
    assert!(ok && out.contains("Resumed"), "{out}");
    let (_, out, _, _) = d.cli(&["status"]);
    assert!(!out.contains("paused"), "{out}");
}

#[test]
fn the_note_names_this_instance() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_localcron")).arg("note").output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.starts_with("# LocalCron\n") && text.contains("add_job"), "{text}");
}

#[test]
fn secrets_from_stdin_never_as_an_argument() {
    let d = Daemon::start();
    let (ok, out, err, _) = d.cli(&["add", "deploy", "--schedule", "@daily", "--command", "true", "--secret-env", "GH_TOKEN=github-token"]);
    assert!(ok, "{err}");
    assert!(out.contains("secret:    GH_TOKEN from github-token") && out.contains("localcron secret set github-token"), "{out}");
    assert!(out.contains("not allowed yet: allow this job in the menu bar app"), "{out}");

    let (ok, out, err, _) = d.cli_with_stdin(&["secret", "set", "github-token"], "ghp_from_stdin\n");
    assert!(ok, "{err}");
    assert!(out.contains("Stored github-token") && out.contains("secret describe github-token") && out.contains("Used by: deploy"), "{out}");
    let (ok, out, err, _) = d.cli(&["secret", "describe", "github-token", "Expires 2027-01-31, github.com/settings/tokens"]);
    assert!(ok && out.contains("Expires 2027-01-31"), "{err}");
    let (_, out, _, _) = d.cli(&["secret", "list"]);
    assert!(out.starts_with("github-token") && out.contains(" ok ") && out.contains("used by deploy"), "{out}");
    assert!(!out.contains("ghp_from_stdin"), "{out}");
    // Nobody allowed the job in the menu bar app.
    let (ok, out, _, _) = d.cli(&["run", "deploy", "--wait"]);
    assert!(!ok && out.contains("may not read its secrets yet"), "{out}");

    // A value as an argument is refused by the parser.
    let (ok, _, _, _) = d.cli(&["secret", "set", "github-token", "ghp_in_history"]);
    assert!(!ok);
    let (ok, _, err, _) = d.cli_with_stdin(&["secret", "set", "other"], "");
    assert!(!ok && err.contains("stdin was empty"), "{err}");

    let (ok, out, _, _) = d.cli(&["secret", "remove", "github-token"]);
    assert!(ok && out.contains("Still named by deploy"), "{out}");
    let (ok, _, err, _) = d.cli(&["secret", "remove", "github-token"]);
    assert!(!ok && err.contains("no secret"), "{err}");
}

/// Runs the CLI with a deadline: a second open of a named pipe would block.
fn cli_within(d: &Daemon, args: &[&str], seconds: u64) -> (bool, String, String) {
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_localcron"))
        .args(args)
        .env("LOCALCRON_HOME", d.home())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(seconds);
    while child.try_wait().unwrap().is_none() {
        if std::time::Instant::now() > deadline {
            let _ = child.kill();
            panic!("{args:?} did not end: it may have opened the pipe twice");
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    let out = child.wait_with_output().unwrap();
    (out.status.success(), String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
}

#[test]
fn a_secret_from_a_key_of_a_env_file_a_named_pipe_or_stdin() {
    let d = Daemon::start();
    let env = d.home().join("app.env");
    std::fs::write(&env, "# app\nexport GH_TOKEN=ghp_from_file\nOTHER=x\n").unwrap();
    let file = env.to_str().unwrap();
    let (ok, out, err) = cli_within(&d, &["secret", "set", "github-token", "--key", "GH_TOKEN", "--env-file", file], 10);
    assert!(ok && out.contains("Stored github-token"), "{out}{err}");

    // A named pipe, as 1Password Environments mounts a .env: one writer, one read.
    let pipe = d.home().join("op.env");
    let path = std::ffi::CString::new(pipe.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let writer_path = pipe.clone();
    let writer = std::thread::spawn(move || {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new().write(true).open(writer_path).unwrap();
        f.write_all(b"OPENAI_API_KEY=\"sk-from-pipe\"\n").unwrap();
    });
    let (ok, out, err) = cli_within(&d, &["secret", "set", "openai", "--key", "OPENAI_API_KEY", "--env-file", pipe.to_str().unwrap()], 10);
    assert!(ok && out.contains("Stored openai"), "{out}{err}");
    writer.join().unwrap();

    let (ok, out, err, _) = d.cli_with_stdin(&["secret", "set", "other", "--key", "OTHER"], "OTHER=from-stdin-1\n");
    assert!(ok && out.contains("Stored other"), "{out}{err}");

    // Errors name keys, never values.
    let (ok, _, err) = cli_within(&d, &["secret", "set", "x", "--key", "NOPE", "--env-file", file], 10);
    assert!(!ok && err.contains("NOPE is not in the .env; it has GH_TOKEN, OTHER") && !err.contains("ghp_"), "{err}");
    let (ok, _, err) = cli_within(&d, &["secret", "set", "x", "--env-file", file], 10);
    assert!(!ok && err.contains("--key"), "{err}");

    let (_, list, _, _) = d.cli(&["secret", "list"]);
    for name in ["github-token", "openai", "other"] {
        assert!(list.contains(name), "{list}");
    }
    assert!(!list.contains("ghp_from_file") && !list.contains("sk-from-pipe"), "{list}");
}
