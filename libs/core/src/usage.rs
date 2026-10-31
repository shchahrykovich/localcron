//! The tokens a coding agent used in a run. The agents write them in their
//! own session files; the daemon finds the file of a run and this module
//! reads it. No I/O here: the functions take the lines of the files.
//!
//! - Claude Code: `~/.claude/projects/<folder>/<session id>.jsonl`, and the
//!   subagents in `<session id>/subagents/*.jsonl`. Each answer of the model
//!   has `message.usage`; one answer is often written in several lines with
//!   the same `message.id`, so each id counts once.
//! - Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Its `token_count`
//!   events hold the sum of the session so far (`total_token_usage`).

use std::collections::HashMap;

use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    /// Input tokens the model read new, not from the cache.
    pub input_tokens: u64,
    /// Input tokens written to the cache.
    #[serde(default)]
    pub cache_write_tokens: u64,
    /// Input tokens read from the cache: much cheaper than new input.
    #[serde(default)]
    pub cache_read_tokens: u64,
    pub output_tokens: u64,
    /// Calls to the model.
    #[serde(default)]
    pub requests: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub models: Vec<String>,
}

impl Usage {
    pub fn total(&self) -> u64 {
        self.input_tokens + self.cache_write_tokens + self.cache_read_tokens + self.output_tokens
    }
}

fn number(v: &Value, key: &str) -> u64 {
    v.get(key).and_then(Value::as_u64).unwrap_or(0)
}

/// The sum of the answers in Claude Code transcripts: the session file and
/// its subagents' files, in any order.
pub fn claude<'a>(lines: impl IntoIterator<Item = &'a str>) -> Usage {
    // The last line of each answer wins: its usage is the final one.
    let mut answers: HashMap<String, (String, [u64; 4])> = HashMap::new();
    let mut order = Vec::new();
    for line in lines {
        // Most lines are not answers: skip them before parsing.
        if !line.contains("\"usage\"") {
            continue;
        }
        let Ok(record) = serde_json::from_str::<Value>(line) else { continue };
        if record.get("type").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        let message = &record["message"];
        let Some(usage) = message.get("usage") else { continue };
        let model = message.get("model").and_then(Value::as_str).unwrap_or_default();
        // An answer Claude Code makes itself, such as an error, costs nothing.
        if model == "<synthetic>" {
            continue;
        }
        let id = message.get("id").and_then(Value::as_str).unwrap_or_default();
        let request = record.get("requestId").and_then(Value::as_str).unwrap_or_default();
        let key = if id.is_empty() && request.is_empty() { format!("line-{}", order.len()) } else { format!("{id} {request}") };
        let counts = [
            number(usage, "input_tokens"),
            number(usage, "cache_creation_input_tokens"),
            number(usage, "cache_read_input_tokens"),
            number(usage, "output_tokens"),
        ];
        if answers.insert(key.clone(), (model.to_string(), counts)).is_none() {
            order.push(key);
        }
    }
    let mut out = Usage::default();
    for key in &order {
        let (model, [input, write, read, output]) = &answers[key];
        out.input_tokens += input;
        out.cache_write_tokens += write;
        out.cache_read_tokens += read;
        out.output_tokens += output;
        out.requests += 1;
        if !model.is_empty() && !out.models.contains(model) {
            out.models.push(model.clone());
        }
    }
    out
}

/// The first prompt of a Claude Code transcript and when it came: a run
/// from before LocalCron named its sessions is found by it.
pub fn claude_first_prompt<'a>(lines: impl IntoIterator<Item = &'a str>) -> Option<(DateTime<FixedOffset>, String, String)> {
    for line in lines {
        if !line.contains("\"user\"") {
            continue;
        }
        let Ok(record) = serde_json::from_str::<Value>(line) else { continue };
        if record.get("type").and_then(Value::as_str) != Some("user") || record.get("isMeta").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let text = match &record["message"]["content"] {
            Value::String(s) => s.clone(),
            Value::Array(parts) => parts.iter().filter_map(|p| p.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n"),
            _ => continue,
        };
        let at = record.get("timestamp").and_then(Value::as_str).and_then(|t| DateTime::parse_from_rfc3339(t).ok())?;
        let cwd = record.get("cwd").and_then(Value::as_str).unwrap_or_default().to_string();
        return Some((at, cwd, text));
    }
    None
}

/// What the first line of a Codex rollout says: its id, folder and start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexSession {
    pub id: String,
    pub cwd: String,
    pub started_at: DateTime<FixedOffset>,
}

pub fn codex_session(first_line: &str) -> Option<CodexSession> {
    let record: Value = serde_json::from_str(first_line).ok()?;
    if record.get("type").and_then(Value::as_str) != Some("session_meta") {
        return None;
    }
    let p = &record["payload"];
    let started = p.get("timestamp").or(record.get("timestamp")).and_then(Value::as_str)?;
    Some(CodexSession {
        id: p.get("id").and_then(Value::as_str)?.to_string(),
        cwd: p.get("cwd").and_then(Value::as_str)?.to_string(),
        started_at: DateTime::parse_from_rfc3339(started).ok()?,
    })
}

/// The tokens of a Codex rollout. Codex counts the cached input inside
/// `input_tokens`; here it is apart, as for Claude.
pub fn codex<'a>(lines: impl IntoIterator<Item = &'a str>) -> Usage {
    let mut out = Usage::default();
    let mut last: Option<Value> = None;
    for line in lines {
        if !line.contains("token_count") && !line.contains("turn_context") {
            continue;
        }
        let Ok(record) = serde_json::from_str::<Value>(line) else { continue };
        let p = &record["payload"];
        if record.get("type").and_then(Value::as_str) == Some("turn_context") {
            if let Some(model) = p.get("model").and_then(Value::as_str)
                && !out.models.iter().any(|m| m == model)
            {
                out.models.push(model.to_string());
            }
            continue;
        }
        if p.get("type").and_then(Value::as_str) != Some("token_count") {
            continue;
        }
        let Some(total) = p.get("info").and_then(|i| i.get("total_token_usage")).cloned() else { continue };
        // The same sum again is the same call.
        if last.as_ref() != Some(&total) {
            out.requests += 1;
            last = Some(total);
        }
    }
    if let Some(t) = last {
        let read = number(&t, "cached_input_tokens");
        let write = number(&t, "cache_write_input_tokens");
        out.input_tokens = number(&t, "input_tokens").saturating_sub(read + write);
        out.cache_read_tokens = read;
        out.cache_write_tokens = write;
        out.output_tokens = number(&t, "output_tokens");
    }
    out
}

/// A token count in a few characters: `812`, `46K`, `9.3M`.
pub fn short(n: u64) -> String {
    match n {
        0..1_000 => n.to_string(),
        1_000..999_500 => format!("{}K", (n as f64 / 1e3).round()),
        _ if n < 10_000_000 => format!("{:.1}M", n as f64 / 1e6),
        _ => format!("{}M", (n as f64 / 1e6).round()),
    }
}

/// The folder of Claude Code's transcripts for a project folder: each
/// character that is not a letter or a digit becomes `-`.
pub fn claude_project_folder(dir: &str) -> String {
    dir.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn answer(id: &str, request: &str, model: &str, input: u64, write: u64, read: u64, output: u64) -> String {
        serde_json::json!({"type": "assistant", "requestId": request, "message": {"id": id, "model": model, "usage": {
            "input_tokens": input, "cache_creation_input_tokens": write, "cache_read_input_tokens": read, "output_tokens": output,
            "cache_creation": {"ephemeral_5m_input_tokens": write}}}})
        .to_string()
    }

    #[test]
    fn each_claude_answer_counts_once_also_when_it_has_several_lines() {
        let lines = [
            r#"{"type":"user","message":{"content":"hi"}}"#.to_string(),
            answer("m1", "r1", "claude-opus-5-5", 3, 100, 0, 10),
            // The same answer, its next content block: the last line wins.
            answer("m1", "r1", "claude-opus-5-5", 3, 100, 0, 12),
            answer("m2", "r2", "claude-opus-5-5", 1, 20, 100, 30),
            // A subagent with another model.
            answer("s1", "r3", "claude-haiku-5-5", 5, 0, 50, 7),
            answer("e1", "", "<synthetic>", 0, 0, 0, 0),
            "not json".to_string(),
        ];
        let usage = claude(lines.iter().map(String::as_str));
        assert_eq!(
            usage,
            Usage {
                input_tokens: 9,
                cache_write_tokens: 120,
                cache_read_tokens: 150,
                output_tokens: 49,
                requests: 3,
                models: vec!["claude-opus-5-5".into(), "claude-haiku-5-5".into()],
            }
        );
        assert_eq!(usage.total(), 328);
        assert_eq!(claude([]), Usage::default());
    }

    #[test]
    fn the_first_prompt_of_a_claude_transcript() {
        let lines = [
            r#"{"type":"last-prompt"}"#,
            r#"{"type":"user","isMeta":true,"message":{"content":"<command>"},"timestamp":"2026-10-30T21:00:01Z"}"#,
            r#"{"type":"user","cwd":"/p","message":{"content":[{"type":"text","text":"Review PRs"}]},"timestamp":"2026-10-30T21:00:03.170Z"}"#,
            r#"{"type":"user","message":{"content":"later"},"timestamp":"2026-10-30T21:05:00Z"}"#,
        ];
        let (at, cwd, text) = claude_first_prompt(lines).unwrap();
        assert_eq!(at.to_rfc3339(), "2026-10-30T21:00:03.170+00:00");
        assert_eq!((cwd.as_str(), text.as_str()), ("/p", "Review PRs"));
        assert_eq!(claude_first_prompt([r#"{"type":"mode"}"#]), None);
    }

    #[test]
    fn a_codex_rollout_gives_its_last_sum_with_the_cache_apart() {
        let meta = r#"{"timestamp":"2026-10-20T16:23:58Z","type":"session_meta","payload":{"id":"01a1","timestamp":"2026-10-20T16:23:33.383Z","cwd":"/p","originator":"codex_exec"}}"#;
        let count = |input: u64, cached: u64, output: u64| {
            serde_json::json!({"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {
                "input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": 0, "output_tokens": output}}}})
            .to_string()
        };
        let lines = [
            meta.to_string(),
            r#"{"type":"turn_context","payload":{"model":"gpt-6.1-sol","cwd":"/p"}}"#.to_string(),
            r#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#.to_string(),
            count(1000, 800, 50),
            count(1000, 800, 50),
            count(2500, 2000, 90),
        ];
        let usage = codex(lines.iter().map(String::as_str));
        assert_eq!(
            usage,
            Usage {
                input_tokens: 500,
                cache_write_tokens: 0,
                cache_read_tokens: 2000,
                output_tokens: 90,
                requests: 2,
                models: vec!["gpt-6.1-sol".into()],
            }
        );
        let session = codex_session(meta).unwrap();
        assert_eq!((session.id.as_str(), session.cwd.as_str()), ("01a1", "/p"));
        assert_eq!(session.started_at.to_rfc3339(), "2026-10-20T16:23:33.383+00:00");
        assert_eq!(codex_session(r#"{"type":"turn_context"}"#), None);
    }

    #[test]
    fn short_counts() {
        assert_eq!([812, 46_355, 999_499, 999_600, 9_311_043, 46_000_000].map(short), ["812", "46K", "999K", "1.0M", "9.3M", "46M"]);
    }

    #[test]
    fn claude_names_its_project_folders_with_dashes() {
        assert_eq!(claude_project_folder("/Users/me/Projects/ah-app/.wt/cron_lock"), "-Users-me-Projects-ah-app--wt-cron-lock");
    }
}
