//! The help page's text, for people and agents. The app bundle has it as
//! `help.html` (the CLI's hidden `help-page` command renders it at build
//! time); the page's Copy as Markdown copies this text. Its last part is the
//! agent note, so one paste gives an agent everything.

use crate::instance::Instance;
use crate::note;

const HELP: &str = include_str!("help.md");
/// The workspace version: the app, daemon and CLI share it.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn render(instance: &Instance) -> String {
    HELP.replace("{{APP}}", &instance.app_name())
        .replace("{{CLI}}", &instance.cli())
        .replace("{{VERSION}}", VERSION)
        .replace("{{NOTE}}", demote(&note::render(instance)).trim_end())
        + "\n"
}

/// The note without its title, every heading one level lower, so it fits
/// under "Instructions for agents". Lines in code blocks stay as they are.
fn demote(note: &str) -> String {
    let mut out = String::new();
    let mut in_code = false;
    for (i, line) in note.lines().enumerate() {
        if i == 0 && line.starts_with("# ") {
            continue;
        }
        if line.trim_start().starts_with("```") {
            in_code = !in_code;
        }
        if !in_code && line.starts_with('#') {
            out.push('#');
        }
        out.push_str(line);
        out.push('\n');
    }
    out.trim_start().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filled_in_with_the_note_one_level_down() {
        let text = render(&Instance::new("-dev").unwrap());
        assert!(text.starts_with("# LocalCron-dev help\n"), "{}", &text[..40]);
        assert!(!text.contains("{{"), "a placeholder is left");
        assert!(text.contains("`localcron-dev secret set NAME`"));
        assert!(text.contains(&format!("This page is for version {VERSION}.")));
        assert!(text.contains("<https://github.com/shchahrykovich/localcron/releases/latest>"));
        // The note's sections are under "## Instructions for agents".
        let agents = text.find("## Instructions for agents").unwrap();
        let tools = text.find("### Tools").unwrap();
        let secrets = text.find("### Secrets").unwrap();
        assert!(agents < tools && tools < secrets);
        assert!(!text.contains("\n# LocalCron-dev\n"), "the note's title is left");
    }

    #[test]
    fn code_blocks_are_not_demoted() {
        assert_eq!(demote("# T\n## A\n```\n# comment\n```\n"), "### A\n```\n# comment\n```\n");
    }
}
