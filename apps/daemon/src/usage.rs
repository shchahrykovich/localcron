//! Finds the session file of a claude or codex run, for the tokens it used
//! (`localcron_core::usage` reads the files).
//!
//! ```text
//! claude run ── --session-id <uuid> ──► ~/.claude/projects/<folder>/<uuid>.jsonl
//!                                                          <uuid>/subagents/*.jsonl
//! codex run ── (no id) ──► ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, found by its folder and start time
//! ```
//!
//! A claude run from before LocalCron named the sessions is found by its
//! folder, its start time and its first prompt.

use std::collections::HashSet;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, FixedOffset, Local};
use localcron_core::job::Job;
use localcron_core::usage::{self, Usage};

/// A random UUID (version 4), as Claude Code takes for `--session-id`.
pub fn new_session_id() -> String {
    let mut b = [0u8; 16];
    // SAFETY: arc4random_buf fills exactly the 16 bytes it is given.
    unsafe { libc::arc4random_buf(b.as_mut_ptr().cast(), b.len()) };
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let hex: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

/// The agent's folder: the job's variable, the daemon's, or `~/<default>`.
fn agent_home(job: &Job, var: &str, default: &str) -> PathBuf {
    if let Some(dir) = job.env.get(var).filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    if let Some(dir) = std::env::var_os(var).filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(default)
}

pub fn claude_home(job: &Job) -> PathBuf {
    agent_home(job, "CLAUDE_CONFIG_DIR", ".claude")
}

pub fn codex_home(job: &Job) -> PathBuf {
    agent_home(job, "CODEX_HOME", ".codex")
}

fn jsonl_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(dir) else { return Vec::new() };
    entries.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "jsonl")).collect()
}

/// The tokens of a Claude Code session and its subagents. None when its
/// file is not there.
pub fn claude_session(home: &Path, dir: &str, session: &str) -> Option<Usage> {
    let projects = home.join("projects");
    let name = format!("{session}.jsonl");
    let file = Some(projects.join(usage::claude_project_folder(dir)).join(&name)).filter(|p| p.is_file()).or_else(|| {
        // Claude Code may name the folder in another way: look in all.
        fs::read_dir(&projects).ok()?.flatten().map(|e| e.path().join(&name)).find(|p| p.is_file())
    })?;
    let mut files = vec![file.clone()];
    if let Some(parent) = file.parent() {
        files.extend(jsonl_files(&parent.join(session).join("subagents")));
    }
    let texts: Vec<String> = files.iter().filter_map(|f| fs::read_to_string(f).ok()).collect();
    Some(usage::claude(texts.iter().flat_map(|t| t.lines())))
}

/// How much later than the run an agent may note its start, and earlier.
const SLACK_SECS: i64 = 60;

fn modified_since(path: &Path, since: DateTime<FixedOffset>) -> bool {
    fs::metadata(path).and_then(|m| m.modified()).is_ok_and(|t| DateTime::<chrono::Utc>::from(t) >= since)
}

/// The session of a claude run that had no session id: a transcript in the
/// job's folder that began during the run with the job's prompt, and that
/// no other run has.
pub fn find_claude_session(
    home: &Path,
    job: &Job,
    started: DateTime<FixedOffset>,
    ended: DateTime<FixedOffset>,
    taken: &HashSet<String>,
) -> Option<String> {
    let prompt = job.prompt.as_deref()?.trim();
    let folder = home.join("projects").join(usage::claude_project_folder(&job.dir));
    let mut found: Vec<(DateTime<FixedOffset>, String)> = Vec::new();
    for file in jsonl_files(&folder) {
        let Some(id) = file.file_stem().and_then(|s| s.to_str()).map(str::to_string) else { continue };
        if taken.contains(&id) || !modified_since(&file, started) {
            continue;
        }
        let Ok(f) = fs::File::open(&file) else { continue };
        let lines: Vec<String> = BufReader::new(f).lines().take(200).map_while(Result::ok).collect();
        let Some((at, cwd, text)) = usage::claude_first_prompt(lines.iter().map(String::as_str)) else { continue };
        let in_time = at >= started - Duration::seconds(SLACK_SECS) && at <= ended;
        if in_time && text.trim() == prompt && (cwd.is_empty() || same_dir(&cwd, &job.dir)) {
            found.push((at, id));
        }
    }
    found.into_iter().min().map(|(_, id)| id)
}

fn same_dir(a: &str, b: &str) -> bool {
    let norm = |p: &str| fs::canonicalize(p).unwrap_or_else(|_| PathBuf::from(p.trim_end_matches('/')));
    a.trim_end_matches('/') == b.trim_end_matches('/') || norm(a) == norm(b)
}

/// The Codex rollout of a run: Codex has no option for its id, so it is the
/// first rollout in the job's folder that began during the run and that no
/// other run has. Its id and tokens.
pub fn codex_run(
    home: &Path,
    dir: &str,
    started: DateTime<FixedOffset>,
    ended: DateTime<FixedOffset>,
    taken: &HashSet<String>,
) -> Option<(String, Usage)> {
    let sessions = home.join("sessions");
    // The folders are named after the local day the session began.
    let first = (started - Duration::days(1)).with_timezone(&Local).date_naive();
    let last = ended.with_timezone(&Local).date_naive();
    let mut found: Vec<(DateTime<FixedOffset>, String, PathBuf)> = Vec::new();
    for day in first.iter_days().take_while(|d| *d <= last) {
        for file in jsonl_files(&sessions.join(day.format("%Y/%m/%d").to_string())) {
            if !modified_since(&file, started) {
                continue;
            }
            let Ok(f) = fs::File::open(&file) else { continue };
            let Some(Ok(line)) = BufReader::new(f).lines().next() else { continue };
            let Some(s) = usage::codex_session(&line) else { continue };
            let in_time = s.started_at >= started - Duration::seconds(SLACK_SECS) && s.started_at <= ended;
            if in_time && !taken.contains(&s.id) && same_dir(&s.cwd, dir) {
                found.push((s.started_at, s.id, file));
            }
        }
    }
    let (_, id, file) = found.into_iter().min()?;
    let text = fs::read_to_string(file).ok()?;
    Some((id, usage::codex(text.lines())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use localcron_core::job::JobKind;

    fn job(dir: &str, kind: JobKind) -> Job {
        serde_json::from_value(serde_json::json!({"id": "review", "schedule": "@daily", "kind": kind, "prompt": "Review PRs", "dir": dir}))
            .unwrap()
    }

    fn at(s: &str) -> DateTime<FixedOffset> {
        DateTime::parse_from_rfc3339(s).unwrap()
    }

    fn answer(id: &str, output: u64) -> String {
        format!(r#"{{"type":"assistant","requestId":"r-{id}","message":{{"id":"{id}","model":"claude-opus-5-5","usage":{{"input_tokens":2,"cache_read_input_tokens":100,"output_tokens":{output}}}}}}}"#)
    }

    #[test]
    fn session_ids_are_random_version_4_uuids() {
        let (a, b) = (new_session_id(), new_session_id());
        assert_ne!(a, b);
        assert_eq!(a.len(), 36);
        assert_eq!(a.split('-').map(str::len).collect::<Vec<_>>(), [8, 4, 4, 4, 12]);
        assert_eq!(&a[14..15], "4");
        assert!("89ab".contains(&a[19..20]), "{a}");
    }

    #[test]
    fn a_claude_session_counts_its_subagents_too() {
        let home = tempfile::tempdir().unwrap();
        let folder = home.path().join("projects").join("-p-shop");
        fs::create_dir_all(folder.join("s1/subagents")).unwrap();
        fs::write(folder.join("s1.jsonl"), [answer("m1", 10), answer("m1", 12), answer("m2", 5)].join("\n")).unwrap();
        fs::write(folder.join("s1/subagents/agent-a.jsonl"), answer("m3", 7)).unwrap();
        let usage = claude_session(home.path(), "/p/shop", "s1").unwrap();
        assert_eq!((usage.requests, usage.output_tokens, usage.cache_read_tokens), (3, 24, 300));
        // Another folder name: found too.
        assert_eq!(claude_session(home.path(), "/elsewhere", "s1").map(|u| u.requests), Some(3));
        assert_eq!(claude_session(home.path(), "/p/shop", "s2"), None);
    }

    #[test]
    fn an_old_claude_run_is_found_by_its_time_and_prompt() {
        let home = tempfile::tempdir().unwrap();
        let folder = home.path().join("projects").join("-p-shop");
        fs::create_dir_all(&folder).unwrap();
        let first = |at: &str, text: &str| format!(r#"{{"type":"user","cwd":"/p/shop","message":{{"content":"{text}"}},"timestamp":"{at}"}}"#);
        fs::write(folder.join("mine.jsonl"), first("2026-10-30T21:00:03Z", "Something else")).unwrap();
        fs::write(folder.join("early.jsonl"), first("2026-10-29T21:00:03Z", "Review PRs")).unwrap();
        fs::write(folder.join("run.jsonl"), first("2026-10-30T21:00:03Z", "Review PRs")).unwrap();
        let job = job("/p/shop", JobKind::Claude);
        // The files were written now: a run window around now finds them.
        let now = chrono::Utc::now().fixed_offset();
        let window = |a: &str, b: &str| (at(a), at(b).max(now));
        let (started, ended) = window("2026-10-30T21:00:00Z", "2026-10-30T21:08:41Z");
        assert_eq!(find_claude_session(home.path(), &job, started, ended, &HashSet::new()).as_deref(), Some("run"));
        assert_eq!(find_claude_session(home.path(), &job, started, ended, &HashSet::from(["run".to_string()])), None);
    }

    #[test]
    fn a_codex_run_is_its_rollout_in_the_folder_during_the_run() {
        let home = tempfile::tempdir().unwrap();
        let now = Local::now().fixed_offset();
        let day = home.path().join("sessions").join(now.format("%Y/%m/%d").to_string());
        fs::create_dir_all(&day).unwrap();
        let rollout = |id: &str, cwd: &str, start: DateTime<FixedOffset>, output: u64| {
            let meta = serde_json::json!({"type": "session_meta", "payload": {"id": id, "cwd": cwd, "timestamp": start.to_rfc3339()}});
            let count = serde_json::json!({"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage":
                {"input_tokens": 100, "cached_input_tokens": 60, "output_tokens": output}}}});
            fs::write(day.join(format!("rollout-{id}.jsonl")), format!("{meta}\n{count}\n")).unwrap();
        };
        let started = now - Duration::seconds(30);
        rollout("other-dir", "/p/blog", now - Duration::seconds(20), 1);
        rollout("before", "/p/shop", now - Duration::hours(2), 2);
        rollout("ours", "/p/shop", now - Duration::seconds(25), 3);
        let (id, usage) = codex_run(home.path(), "/p/shop/", started, now, &HashSet::new()).unwrap();
        assert_eq!((id.as_str(), usage.input_tokens, usage.cache_read_tokens, usage.output_tokens), ("ours", 40, 60, 3));
        assert_eq!(codex_run(home.path(), "/p/shop", started, now, &HashSet::from(["ours".to_string()])), None);
    }
}
