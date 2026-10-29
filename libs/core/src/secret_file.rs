//! One value from a file of settings, for
//! `localcron secret set NAME --key PATH [--file FILE] [--format F]`.
//!
//! The format comes from `--format`, else from the file's name:
//! - `.json`: JSON. The path is dotted, with array indexes
//!   (`services.github.token`, `keys.0`), or a JSON Pointer (`/a/b.c`) when a
//!   name has a dot.
//! - `.ini`, `.cfg`, `.conf`, and the names `credentials` (AWS) and `.npmrc`:
//!   INI. The path is `section.key` (`default.aws_secret_access_key`,
//!   `profile dev.region`), or a key before any section as written
//!   (`//registry.npmjs.org/:_authToken`).
//! - anything else, and stdin: `.env`, by variable name.
//!
//! Errors never contain a value: only names of keys and sections.

use std::path::Path;

use serde_json::Value;

use crate::dotenv;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Env,
    Json,
    Ini,
}

impl Format {
    pub fn parse(text: &str) -> Result<Self, String> {
        match text {
            "env" => Ok(Format::Env),
            "json" => Ok(Format::Json),
            "ini" => Ok(Format::Ini),
            other => Err(format!("unknown format {other:?}: use env, json or ini")),
        }
    }

    /// From the file's name; `.env` when nothing else fits.
    pub fn of_path(path: &Path) -> Format {
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_ascii_lowercase();
        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or_default().to_ascii_lowercase();
        match ext.as_str() {
            "json" => Format::Json,
            "ini" | "cfg" | "conf" => Format::Ini,
            _ if name == "credentials" || name == ".npmrc" => Format::Ini,
            _ => Format::Env,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Format::Env => "the .env",
            Format::Json => "the JSON",
            Format::Ini => "the INI file",
        }
    }
}

/// The value at `path` in `text`.
pub fn lookup(format: Format, text: &str, path: &str) -> Result<String, String> {
    let value = match format {
        Format::Env => dotenv::lookup(text, path)?,
        Format::Json => json(text, path)?,
        Format::Ini => ini(text, path)?,
    };
    if value.is_empty() {
        return Err(format!("{path} is empty in {}", format.name()));
    }
    Ok(value)
}

fn json(text: &str, path: &str) -> Result<String, String> {
    // The parser's message can quote the text: say only where.
    let root: Value =
        serde_json::from_str(text).map_err(|e| format!("the JSON is not valid at line {} column {}", e.line(), e.column()))?;
    let segments: Vec<String> = match path.strip_prefix('/') {
        // JSON Pointer: `~1` is '/', `~0` is '~'.
        Some(pointer) => pointer.split('/').map(|s| s.replace("~1", "/").replace("~0", "~")).collect(),
        None => path.split('.').map(str::to_string).collect(),
    };
    let mut at = &root;
    let mut walked: Vec<&str> = Vec::new();
    for segment in &segments {
        let next = match at {
            Value::Object(map) => map.get(segment),
            Value::Array(items) => segment.parse::<usize>().ok().and_then(|i| items.get(i)),
            _ => None,
        };
        let Some(next) = next else {
            let here = if walked.is_empty() { "the top".to_string() } else { walked.join(".") };
            return Err(format!("{path} is not in the JSON; {here} has {}", children(at)));
        };
        walked.push(segment);
        at = next;
    }
    match at {
        Value::String(s) => Ok(s.clone()),
        Value::Number(n) => Ok(n.to_string()),
        Value::Bool(b) => Ok(b.to_string()),
        Value::Null => Err(format!("{path} is null in the JSON")),
        Value::Object(_) | Value::Array(_) => Err(format!("{path} is not a single value in the JSON; it has {}", children(at))),
    }
}

/// The names under a JSON value, never values.
fn children(value: &Value) -> String {
    match value {
        Value::Object(map) if !map.is_empty() => map.keys().cloned().collect::<Vec<_>>().join(", "),
        Value::Array(items) if !items.is_empty() => format!("indexes 0 to {}", items.len() - 1),
        Value::Object(_) | Value::Array(_) => "nothing".into(),
        _ => "no names: it is a value".into(),
    }
}

/// `(section, key, value)` in order; keys before any section have section "".
fn ini_entries(text: &str) -> Result<Vec<(String, String, String)>, String> {
    let mut out = Vec::new();
    let mut section = String::new();
    for (i, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with(';') || line.starts_with('#') {
            continue;
        }
        if let Some(name) = line.strip_prefix('[') {
            let name = name.strip_suffix(']').ok_or_else(|| format!("line {} of the INI file: a section has no ']'", i + 1))?;
            section = name.trim().to_string();
            continue;
        }
        let split = line.find('=').or_else(|| line.find(':')).ok_or_else(|| format!("line {} of the INI file has no '='", i + 1))?;
        let key = line[..split].trim().to_string();
        let raw = line[split + 1..].trim();
        let value = match raw.chars().next() {
            Some(q @ ('"' | '\'')) if raw.len() >= 2 && raw.ends_with(q) => raw[1..raw.len() - 1].to_string(),
            _ => {
                let cut = [" ;", " #"].iter().filter_map(|c| raw.find(c)).min().unwrap_or(raw.len());
                raw[..cut].trim_end().to_string()
            }
        };
        out.push((section.clone(), key, value));
    }
    Ok(out)
}

fn ini(text: &str, path: &str) -> Result<String, String> {
    let entries = ini_entries(text)?;
    let find = |section: &str, key: &str| entries.iter().rev().find(|(s, k, _)| s == section && k == key).map(|(_, _, v)| v.clone());
    // A key before any section, as written: it may have dots.
    if let Some(v) = find("", path) {
        return Ok(v);
    }
    // `section.key`: the section may have dots or spaces, so try each dot.
    for (i, _) in path.match_indices('.').collect::<Vec<_>>().into_iter().rev() {
        if let Some(v) = find(&path[..i], &path[i + 1..]) {
            return Ok(v);
        }
    }
    let mut sections: Vec<&str> = entries.iter().map(|(s, _, _)| s.as_str()).filter(|s| !s.is_empty()).collect();
    sections.dedup();
    let mut top: Vec<&str> = entries.iter().filter(|(s, _, _)| s.is_empty()).map(|(_, k, _)| k.as_str()).collect();
    top.dedup();
    let mut parts = Vec::new();
    if !sections.is_empty() {
        parts.push(format!("sections {}", sections.join(", ")));
    }
    if !top.is_empty() {
        parts.push(format!("keys {}", top.join(", ")));
    }
    let has = if parts.is_empty() { "nothing".into() } else { parts.join("; ") };
    // Name the keys of the section the path starts with, when there is one.
    let keys = path
        .match_indices('.')
        .map(|(i, _)| &path[..i])
        .find(|s| sections.contains(s))
        .map(|s| {
            let keys: Vec<&str> = entries.iter().filter(|(sec, _, _)| sec == s).map(|(_, k, _)| k.as_str()).collect();
            format!("; [{s}] has {}", keys.join(", "))
        })
        .unwrap_or_default();
    Err(format!("{path} is not in the INI file; it has {has}{keys}. Write the path as section.key"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_format_comes_from_the_name() {
        for (name, format) in [
            ("config.json", Format::Json),
            ("Settings.JSON", Format::Json),
            ("app.ini", Format::Ini),
            ("setup.cfg", Format::Ini),
            ("svc.conf", Format::Ini),
            ("/Users/me/.aws/credentials", Format::Ini),
            ("/Users/me/.npmrc", Format::Ini),
            (".env", Format::Env),
            (".env.local", Format::Env),
            ("prod.env", Format::Env),
            ("secrets", Format::Env),
        ] {
            assert_eq!(Format::of_path(Path::new(name)), format, "{name}");
        }
        assert_eq!(Format::parse("json").unwrap(), Format::Json);
        assert!(Format::parse("yaml").unwrap_err().contains("env, json or ini"));
    }

    const JSON: &str = r#"{"services": {"github": {"token": "ghp_json", "port": 443, "on": true, "none": null}},
        "keys": [{"value": "k0"}, {"value": "k1"}], "a.b": {"c": "dotted"}, "empty": ""}"#;

    #[test]
    fn json_paths() {
        assert_eq!(lookup(Format::Json, JSON, "services.github.token").unwrap(), "ghp_json");
        assert_eq!(lookup(Format::Json, JSON, "services.github.port").unwrap(), "443");
        assert_eq!(lookup(Format::Json, JSON, "services.github.on").unwrap(), "true");
        assert_eq!(lookup(Format::Json, JSON, "keys.1.value").unwrap(), "k1");
        assert_eq!(lookup(Format::Json, JSON, "/a.b/c").unwrap(), "dotted");
    }

    #[test]
    fn json_errors_name_keys_never_values() {
        let e = lookup(Format::Json, JSON, "services.gitlab.token").unwrap_err();
        assert_eq!(e, "services.gitlab.token is not in the JSON; services has github");
        let e = lookup(Format::Json, JSON, "services.github").unwrap_err();
        assert!(e.contains("not a single value") && e.contains("none, on, port, token") && !e.contains("ghp_"), "{e}");
        assert!(lookup(Format::Json, JSON, "keys.5").unwrap_err().contains("indexes 0 to 1"));
        assert!(lookup(Format::Json, JSON, "services.github.none").unwrap_err().contains("null"));
        assert!(lookup(Format::Json, JSON, "empty").unwrap_err().contains("empty"));
        let e = lookup(Format::Json, r#"{"token": "ghp_x", }"#, "token").unwrap_err();
        assert!(e.starts_with("the JSON is not valid at line 1") && !e.contains("ghp_"), "{e}");
    }

    const INI: &str = "; ~/.aws/credentials and friends\n\
        //registry.npmjs.org/:_authToken=npm_top\n\
        [default]\n\
        aws_access_key_id = AKIA1\n\
        aws_secret_access_key = secret1 ; old comment\n\
        [profile dev]\n\
        region: eu-west-1\n\
        [db.prod]\n\
        password = \"p@ss ; word\"\n";

    #[test]
    fn ini_paths() {
        assert_eq!(lookup(Format::Ini, INI, "default.aws_secret_access_key").unwrap(), "secret1");
        assert_eq!(lookup(Format::Ini, INI, "profile dev.region").unwrap(), "eu-west-1");
        assert_eq!(lookup(Format::Ini, INI, "db.prod.password").unwrap(), "p@ss ; word");
        assert_eq!(lookup(Format::Ini, INI, "//registry.npmjs.org/:_authToken").unwrap(), "npm_top");
    }

    #[test]
    fn ini_errors_name_sections_and_keys_never_values() {
        let e = lookup(Format::Ini, INI, "default.token").unwrap_err();
        assert!(e.contains("sections default, profile dev, db.prod"), "{e}");
        assert!(e.contains("[default] has aws_access_key_id, aws_secret_access_key"), "{e}");
        assert!(!e.contains("AKIA1") && !e.contains("secret1"), "{e}");
        assert!(lookup(Format::Ini, "[open\n", "a.b").unwrap_err().contains("no ']'"));
    }

    #[test]
    fn env_is_the_default() {
        assert_eq!(lookup(Format::Env, "A=1\n", "A").unwrap(), "1");
    }
}
