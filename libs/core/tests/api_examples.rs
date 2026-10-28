//! Every file in api/examples is a real exchange with the daemon. Each must
//! decode into the Rust types; the Swift app checks the same files.

use std::path::Path;

use localcron_core::api::*;
use serde::de::DeserializeOwned;
use serde_json::Value;

fn check<T: DeserializeOwned>(value: &Value, file: &str) {
    if let Err(e) = serde_json::from_value::<T>(value.clone()) {
        panic!("{file}: {e}\n{value}");
    }
}

/// `set_job_shell` is an example of `set_job`.
fn method_of(name: &str) -> &str {
    METHODS.iter().copied().filter(|m| name == *m || name.starts_with(&format!("{m}_"))).max_by_key(|m| m.len()).unwrap_or(name)
}

#[test]
fn every_example_decodes_and_every_method_has_one() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../api/examples");
    let mut seen = std::collections::BTreeSet::new();
    for entry in std::fs::read_dir(&dir).unwrap() {
        let path = entry.unwrap().path();
        let file = path.file_name().unwrap().to_string_lossy().into_owned();
        let v: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let (name, kind) = file.trim_end_matches(".json").rsplit_once('.').unwrap();
        if name == "error" {
            if kind == "reply" {
                check::<ApiError>(&v["error"], &file);
            }
            continue;
        }
        let method = method_of(name);
        assert!(METHODS.contains(&method), "{file}: no method {method}");
        seen.insert(method.to_string());
        if kind == "request" {
            check::<Request>(&v, &file);
            assert_eq!(v["method"], method, "{file}");
            let p = &v["params"];
            match method {
                "hello" => check::<HelloParams>(p, &file),
                "status" | "list_jobs" | "get_config" => check::<Empty>(p, &file),
                "get_job" | "remove_job" | "run_job" => check::<IdParams>(p, &file),
                "set_job" => check::<SetJobParams>(p, &file),
                "set_job_enabled" => check::<SetJobEnabledParams>(p, &file),
                "cancel_run" => check::<RunIdParams>(p, &file),
                "list_runs" => check::<ListRunsParams>(p, &file),
                "get_run_log" => check::<GetRunLogParams>(p, &file),
                "preview_schedule" => check::<PreviewScheduleParams>(p, &file),
                "set_config" => check::<SetConfigParams>(p, &file),
                other => panic!("{file}: no params type for {other}"),
            }
        } else {
            check::<Response>(&v, &file);
            let r = &v["result"];
            match method {
                "hello" => check::<HelloResult>(r, &file),
                "status" => check::<StatusResult>(r, &file),
                "list_jobs" => check::<ListJobsResult>(r, &file),
                "get_job" | "set_job_enabled" => check::<JobResult>(r, &file),
                "set_job" => check::<SetJobResult>(r, &file),
                "remove_job" => check::<RemoveJobResult>(r, &file),
                "run_job" => check::<RunResult>(r, &file),
                "cancel_run" => check::<CancelRunResult>(r, &file),
                "list_runs" => check::<ListRunsResult>(r, &file),
                "get_run_log" => check::<GetRunLogResult>(r, &file),
                "preview_schedule" => check::<PreviewScheduleResult>(r, &file),
                "get_config" | "set_config" => check::<Config>(r, &file),
                other => panic!("{file}: no result type for {other}"),
            }
        }
    }
    let missing: Vec<&str> = METHODS.iter().copied().filter(|m| !seen.contains(*m)).collect();
    assert!(missing.is_empty(), "methods with no example: {missing:?}");
}
