//! Messages from runs to the user. A job sends one only when the user must
//! know or do something; a run that just works sends none. The menu bar app
//! shows them in the Messages tab and marks its icon while one is unread.

use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize};

/// The most characters in one message.
pub const MAX_TEXT_CHARS: usize = 2000;
/// The most characters in the note of `set_run_status`.
pub const MAX_NOTE_CHARS: usize = 500;
/// The most messages one run may send. Messages are for what matters; a
/// run with more to say puts it in one message.
pub const MAX_PER_RUN: usize = 3;
/// The most messages kept. Over it, the oldest read ones go first.
pub const MAX_KEPT: usize = 500;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Message {
    pub id: u64,
    pub job_id: String,
    pub run_id: String,
    pub at: DateTime<FixedOffset>,
    pub text: String,
    /// The user has seen it in the app.
    #[serde(default)]
    pub read: bool,
}

/// The text without blanks at the ends; an error when it is empty or long.
pub fn check_text(text: &str) -> Result<String, String> {
    let text = text.trim();
    if text.is_empty() {
        return Err("the message is empty".into());
    }
    let chars = text.chars().count();
    if chars > MAX_TEXT_CHARS {
        return Err(format!("the message has {chars} characters, at most {MAX_TEXT_CHARS}: put the details in the run's output"));
    }
    Ok(text.to_string())
}

pub fn check_note(note: &str) -> Result<String, String> {
    let note = note.trim();
    let chars = note.chars().count();
    if chars > MAX_NOTE_CHARS {
        return Err(format!("the note has {chars} characters, at most {MAX_NOTE_CHARS}"));
    }
    Ok(note.to_string())
}

/// Keep at most `max`: drop the oldest read messages first, then the oldest.
/// `messages` is oldest first.
pub fn prune(messages: &mut Vec<Message>, max: usize) {
    while messages.len() > max {
        let i = messages.iter().position(|m| m.read).unwrap_or(0);
        messages.remove(i);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message(id: u64, read: bool) -> Message {
        Message {
            id,
            job_id: "a".into(),
            run_id: format!("a.{id}"),
            at: DateTime::parse_from_rfc3339("2026-11-12T09:00:00Z").unwrap(),
            text: "x".into(),
            read,
        }
    }

    #[test]
    fn text_is_trimmed_and_must_not_be_empty_or_long() {
        assert_eq!(check_text("  disk is full \n").unwrap(), "disk is full");
        assert!(check_text(" \n ").unwrap_err().contains("empty"));
        assert!(check_text(&"a".repeat(MAX_TEXT_CHARS)).is_ok());
        assert!(check_text(&"a".repeat(MAX_TEXT_CHARS + 1)).unwrap_err().contains("at most"));
        // Characters, not bytes.
        assert!(check_text(&"é".repeat(MAX_TEXT_CHARS)).is_ok());
        assert_eq!(check_note("").unwrap(), "");
        assert!(check_note(&"a".repeat(MAX_NOTE_CHARS + 1)).is_err());
    }

    #[test]
    fn prune_drops_read_messages_before_unread_ones() {
        let mut list = vec![message(1, false), message(2, true), message(3, false), message(4, true)];
        prune(&mut list, 2);
        assert_eq!(list.iter().map(|m| m.id).collect::<Vec<_>>(), [1, 3]);
        // All unread: the oldest go.
        prune(&mut list, 1);
        assert_eq!(list.iter().map(|m| m.id).collect::<Vec<_>>(), [3]);
    }
}
