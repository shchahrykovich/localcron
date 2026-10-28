//! `localcron mcp` with a real MCP client over stdio.

mod common;

use std::borrow::Cow;

use common::Daemon;
use rmcp::ServiceExt;
use rmcp::model::{CallToolRequestParams, CallToolResult};
use rmcp::service::RunningService;
use rmcp::transport::TokioChildProcess;
use serde_json::{Value, json};
use tokio::process::Command;

async fn mcp_client(home: &std::path::Path, cwd: &std::path::Path) -> RunningService<rmcp::RoleClient, ()> {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_localcron"));
    cmd.arg("mcp").env("LOCALCRON_HOME", home).current_dir(cwd);
    ().serve(TokioChildProcess::new(cmd).unwrap()).await.unwrap()
}

async fn call(client: &RunningService<rmcp::RoleClient, ()>, name: &'static str, args: Value) -> CallToolResult {
    let params = CallToolRequestParams::new(Cow::Borrowed(name)).with_arguments(args.as_object().unwrap().clone());
    client.call_tool(params).await.unwrap()
}

fn json_of(result: &CallToolResult) -> Value {
    let text = serde_json::to_value(&result.content).unwrap()[0]["text"].as_str().unwrap_or_default().to_string();
    serde_json::from_str(&text).unwrap_or(Value::String(text))
}

#[tokio::test]
async fn the_tools_are_listed_with_instructions() {
    let d = Daemon::start();
    let client = mcp_client(d.home(), d.home()).await;
    let mut names: Vec<String> = client.list_all_tools().await.unwrap().iter().map(|t| t.name.to_string()).collect();
    names.sort();
    assert_eq!(
        names,
        ["add_job", "cancel_run", "enable_job", "get_job", "get_run_log", "list_jobs", "list_runs", "preview_schedule", "remove_job", "run_job", "status"]
    );
    let info = client.peer_info().unwrap();
    assert!(info.instructions.as_deref().unwrap().contains("How to add a job"));
    client.cancel().await.unwrap();
}

#[tokio::test]
async fn an_agent_schedules_a_job_in_its_project_and_runs_it() {
    let d = Daemon::start();
    let project = d.home().join("shop");
    std::fs::create_dir(&project).unwrap();
    let client = mcp_client(d.home(), &project).await;

    let r = call(&client, "preview_schedule", json!({"schedule": "0 9 * * wed", "count": 2})).await;
    assert_eq!(json_of(&r)["description"], "At 09:00 on Wednesday");

    let r = call(&client, "add_job", json!({"id": "deps", "schedule": "0 9 * * wed", "kind": "shell", "command": "pwd"})).await;
    assert_ne!(r.is_error, Some(true), "{r:?}");
    let job = json_of(&r)["job"].clone();
    assert!(job["dir"].as_str().unwrap().ends_with("/shop"), "{job}");
    assert!(job["next_run"].is_string());

    let r = call(&client, "add_job", json!({"id": "deps", "schedule": "@daily", "kind": "shell", "command": "pwd"})).await;
    assert_eq!(r.is_error, Some(true));

    let run = json_of(&call(&client, "run_job", json!({"id": "deps"})).await)["run"]["id"].as_str().unwrap().to_string();
    let mut status = Value::Null;
    for _ in 0..100 {
        let runs = json_of(&call(&client, "list_runs", json!({"job_id": "deps"})).await);
        status = runs["runs"][0]["status"].clone();
        if status == "succeeded" {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert_eq!(status, "succeeded");
    let log = json_of(&call(&client, "get_run_log", json!({"run_id": run})).await);
    assert!(log["text"].as_str().unwrap().contains("/shop\n"), "{log}");

    let r = call(&client, "enable_job", json!({"id": "deps", "enabled": false})).await;
    assert_eq!(json_of(&r)["job"]["enabled"], false);
    let r = call(&client, "remove_job", json!({"id": "deps"})).await;
    assert_eq!(json_of(&r)["removed"], true);
    let r = call(&client, "add_job", json!({"id": "x", "schedule": "@daily", "kind": "shell", "cmd": "ls"})).await;
    assert_eq!(r.is_error, Some(true));
    client.cancel().await.unwrap();
}
