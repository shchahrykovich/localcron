//! Socket client for the daemon. Holds no state: one connection per command
//! or MCP tool call, so a daemon restart needs no recovery.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use localcron_core::api::{self, API_VERSION, ApiError, ErrorCode, HelloParams, HelloResult, Request, Response};
use localcron_core::instance::Instance;
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

/// "LocalCron-dev is not running. Open LocalCron-dev.app or run localcrond-dev."
fn not_running() -> String {
    let i = Instance::of_this_program().unwrap_or_else(|_| Instance::release());
    format!("{i} is not running. Open {i}.app or run {}.", i.daemon_program())
}

#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("{}", not_running())]
    NotRunning,
    #[error("{0}")]
    Api(ApiError),
    #[error("the daemon speaks API {daemon} but this program speaks {API_VERSION}; update the older one")]
    VersionMismatch { daemon: String },
    #[error("connection to the daemon failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("unexpected reply from the daemon: {0}")]
    Protocol(String),
}

pub struct Client {
    read: BufReader<UnixStream>,
    write: UnixStream,
    next: u64,
}

impl Client {
    /// Connect and say hello. Fails when the major API versions differ.
    pub fn connect(socket: &Path, client: &str) -> Result<Self, ClientError> {
        let stream = UnixStream::connect(socket).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused => ClientError::NotRunning,
            _ => ClientError::Io(e),
        })?;
        stream.set_read_timeout(Some(Duration::from_secs(30)))?;
        let write = stream.try_clone()?;
        let mut c = Self { read: BufReader::new(stream), write, next: 1 };
        let hello: HelloResult =
            c.call("hello", HelloParams { client: client.into(), api_version: API_VERSION.into() }).map_err(|e| match e {
                ClientError::Api(e) if e.code == ErrorCode::VersionMismatch => ClientError::VersionMismatch { daemon: "another version".into() },
                other => other,
            })?;
        if api::api_major(&hello.api_version) != api::api_major(API_VERSION) {
            return Err(ClientError::VersionMismatch { daemon: hello.api_version });
        }
        Ok(c)
    }

    pub fn call<T: DeserializeOwned>(&mut self, method: &str, params: impl Serialize) -> Result<T, ClientError> {
        let value = self.call_value(method, params)?;
        serde_json::from_value(value).map_err(|e| ClientError::Protocol(e.to_string()))
    }

    pub fn call_value(&mut self, method: &str, params: impl Serialize) -> Result<Value, ClientError> {
        let id = self.next;
        self.next += 1;
        let params = serde_json::to_value(params).map_err(|e| ClientError::Protocol(e.to_string()))?;
        let mut line = serde_json::to_string(&Request { id, method: method.into(), params })
            .map_err(|e| ClientError::Protocol(e.to_string()))?;
        line.push('\n');
        self.write.write_all(line.as_bytes())?;
        let mut reply = String::new();
        if self.read.read_line(&mut reply)? == 0 {
            return Err(ClientError::Io(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "the daemon closed the connection")));
        }
        let reply: Response = serde_json::from_str(&reply).map_err(|e| ClientError::Protocol(e.to_string()))?;
        if let Some(e) = reply.error {
            return Err(ClientError::Api(e));
        }
        Ok(reply.result.unwrap_or(Value::Null))
    }
}

/// Connect, call one method, disconnect.
pub fn call_value(socket: &Path, client: &str, method: &str, params: impl Serialize) -> Result<Value, ClientError> {
    Client::connect(socket, client)?.call_value(method, params)
}

pub fn call<T: DeserializeOwned>(socket: &Path, method: &str, params: impl Serialize) -> Result<T, ClientError> {
    Client::connect(socket, "cli")?.call(method, params)
}
