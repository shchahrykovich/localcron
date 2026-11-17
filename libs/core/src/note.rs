//! The note for Claude Code and Codex, filled in for an instance. The app
//! bundle carries it as `Contents/Resources/LocalCron.md`; the MCP server
//! sends it as its instructions.

use crate::instance::Instance;

const NOTE: &str = include_str!("note.md");

pub fn render(instance: &Instance) -> String {
    NOTE.replace("{{APP}}", &instance.app_name()).replace("{{CLI}}", &instance.cli())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filled_in_for_the_instance() {
        let text = render(&Instance::new("-dev").unwrap());
        assert!(text.starts_with("# LocalCron-dev\n"));
        assert!(text.contains("`localcron-dev --help`"));
        assert!(!text.contains("{{"));
    }

    /// A job without a model follows the user's Claude Code setting, so
    /// all jobs moved to another model when the user changed it.
    #[test]
    fn tells_agents_to_give_a_model() {
        let text = render(&Instance::new("").unwrap());
        assert!(text.contains("job always gets a `model`"));
        assert!(text.contains("(command, prompt, model, permission_mode,"));
    }
}
