//! The socket API: one thread per connection, one JSON line per request.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::Arc;

use localcron_core::api::{
    self, ApiError, ErrorCode, GetRunLogParams, HelloParams, HelloResult, IdParams, JobResult, ListRunsParams,
    PreviewScheduleParams, Request, Response, RunIdParams, RunResult, SetConfigParams, SetJobEnabledParams, SetJobParams,
};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::engine::{DAEMON_VERSION, Engine};
use crate::log;

/// A request line longer than this is refused: a job is small.
const MAX_LINE: usize = 1024 * 1024;

pub fn bind(engine: &Engine) -> std::io::Result<UnixListener> {
    let path = engine.paths.socket();
    // A file left by a daemon that crashed; the lock says no daemon runs.
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

pub fn serve(engine: Arc<Engine>, listener: UnixListener) {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let engine = Arc::clone(&engine);
                let _ = std::thread::Builder::new().name("client".into()).spawn(move || connection(&engine, stream));
            }
            Err(e) => log!("socket accept failed: {e}"),
        }
    }
}

fn connection(engine: &Engine, stream: UnixStream) {
    let Ok(mut writer) = stream.try_clone() else { return };
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.by_ref().take(MAX_LINE as u64 + 1).read_line(&mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let response = if line.len() > MAX_LINE {
            Response { id: 0, result: None, error: Some(ApiError::new(ErrorCode::BadRequest, "request too long")) }
        } else {
            match serde_json::from_str::<Request>(&line) {
                Ok(request) => {
                    let id = request.id;
                    match dispatch(engine, request) {
                        Ok(result) => Response { id, result: Some(result), error: None },
                        Err(error) => Response { id, result: None, error: Some(error) },
                    }
                }
                Err(e) => Response { id: 0, result: None, error: Some(ApiError::new(ErrorCode::BadRequest, e.to_string())) },
            }
        };
        let mut out = serde_json::to_string(&response).unwrap_or_default();
        out.push('\n');
        if writer.write_all(out.as_bytes()).is_err() {
            return;
        }
    }
}

fn params<T: DeserializeOwned>(value: Value) -> Result<T, ApiError> {
    let value = if value.is_null() { Value::Object(Default::default()) } else { value };
    serde_json::from_value(value).map_err(|e| ApiError::new(ErrorCode::BadRequest, format!("bad params: {e}")))
}

fn to_value(value: impl Serialize) -> Result<Value, ApiError> {
    serde_json::to_value(value).map_err(|e| ApiError::new(ErrorCode::Internal, e.to_string()))
}

pub fn dispatch(engine: &Engine, request: Request) -> Result<Value, ApiError> {
    let p = request.params;
    match request.method.as_str() {
        "hello" => {
            let hello: HelloParams = params(p)?;
            if api::api_major(&hello.api_version) != api::api_major(api::API_VERSION) {
                return Err(ApiError::new(
                    ErrorCode::VersionMismatch,
                    format!("this daemon speaks API {}, {} speaks {}", api::API_VERSION, hello.client, hello.api_version),
                ));
            }
            to_value(HelloResult { daemon_version: DAEMON_VERSION.into(), api_version: api::API_VERSION.into() })
        }
        "status" => to_value(engine.status()),
        "list_jobs" => to_value(engine.list_jobs()),
        "get_job" => to_value(JobResult { job: engine.get_job(&params::<IdParams>(p)?.id)? }),
        "set_job" => to_value(engine.set_job(params::<SetJobParams>(p)?)?),
        "remove_job" => to_value(engine.remove_job(&params::<IdParams>(p)?.id)?),
        "set_job_enabled" => {
            let p: SetJobEnabledParams = params(p)?;
            to_value(JobResult { job: engine.set_job_enabled(&p.id, p.enabled)? })
        }
        "run_job" => to_value(RunResult { run: engine.run_job(&params::<IdParams>(p)?.id)? }),
        "cancel_run" => to_value(engine.cancel_run(&params::<RunIdParams>(p)?.run_id)?),
        "list_runs" => to_value(engine.list_runs(params::<ListRunsParams>(p)?)),
        "get_run_log" => to_value(engine.get_run_log(params::<GetRunLogParams>(p)?)?),
        "preview_schedule" => to_value(engine.preview_schedule(params::<PreviewScheduleParams>(p)?)?),
        "get_config" => to_value(engine.get_config()),
        "set_config" => to_value(engine.set_config(params::<SetConfigParams>(p)?)?),
        other => Err(ApiError::new(ErrorCode::UnknownMethod, format!("unknown method {other:?}"))),
    }
}
